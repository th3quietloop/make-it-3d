import SwiftUI
import Observation
import AVFoundation
import UniformTypeIdentifiers

/// One file's journey through Relief.
@Observable
@MainActor
final class Conversion: Identifiable {
    enum Status: Equatable {
        case probing
        case ready
        case converting(fraction: Double, framesDone: Int)
        case done(outputURL: URL)
        case failed(String)

        var isConverting: Bool {
            if case .converting = self { return true }
            return false
        }

        var isDone: Bool {
            if case .done = self { return true }
            return false
        }

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    let id = UUID()
    let sourceURL: URL
    var status: Status = .probing
    var probe: SourceProbe?
    var thumbnail: CGImage?
    var report: VerificationReport?

    /// When this run started, so the queue can say how much longer it has.
    var startedAt: Date?

    /// Seconds remaining, from frames done against elapsed time. A percentage
    /// on a two hour film is anxiety; a time is information.
    var estimatedSecondsRemaining: Double? {
        guard case .converting(_, let framesDone) = status,
              let startedAt, let probe, framesDone > 8 else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0 else { return nil }
        let rate = Double(framesDone) / elapsed
        guard rate > 0 else { return nil }
        let remaining = Double(probe.estimatedFrameCount - framesDone)
        guard remaining > 0 else { return nil }
        return remaining / rate
    }

    /// The failure message, so a failed row can say what happened on the row
    /// itself rather than only in the inspector of whichever row is selected.
    var failureMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    /// Live settings for this conversion. Export freezes a snapshot onto
    /// `exportedTuning`, so re-exporting with new settings is a new pass rather
    /// than a mutation of the finished one.
    var tuning: EngineTuning = .default
    var exportedTuning: EngineTuning?

    /// A finished row whose settings have since changed offers a re-export.
    var settingsChangedSinceExport: Bool {
        guard let exportedTuning, status.isDone else { return false }
        return exportedTuning != tuning
    }

    var displayName: String { sourceURL.deletingPathExtension().lastPathComponent }

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }
}

/// The root of the app: the queue, the selection, and the settings.
@Observable
@MainActor
final class AppModel {

    var conversions: [Conversion] = []
    var selectionID: Conversion.ID?

    /// Set only when the depth model could not be loaded, which is a standing
    /// condition rather than an event. Everything that happens once goes
    /// through the toast center instead, so good news never renders as a
    /// permanent red alarm.
    var modelBanner: String?

    let toasts = ToastCenter()

    // MARK: Preview

    let preview = PreviewController()
    var previewMode: PreviewMode = .source {
        didSet { refreshPreview(frameChanged: false) }
    }
    /// Playhead position in seconds.
    var playhead: Double = 0

    var inspectorVisible = true
    var sidebarVisible = true

    var outputFolder: URL = FileManager.default.urls(
        for: .moviesDirectory, in: .userDomainMask
    ).first ?? FileManager.default.homeDirectoryForCurrentUser

    /// Filename pattern for exports. `{name}` is replaced with the source name.
    var filenamePattern: String = "{name}_spatial"

    private var conversionTask: Task<Void, Never>?

    var selection: Conversion? {
        guard let selectionID else { return nil }
        return conversions.first { $0.id == selectionID }
    }

    var isConverting: Bool {
        conversions.contains { $0.status.isConverting }
    }

    /// The row actually being converted right now, which is not necessarily the
    /// selected one. The Convert button reports this rather than the selection,
    /// otherwise selecting a finished row while the queue runs shows a progress
    /// sweep stuck at zero.
    var activeConversion: Conversion? {
        conversions.first { $0.status.isConverting }
    }

    /// Progress across everything in this run, so the button means the same
    /// thing whether one file is converting or five.
    var queueProgress: Double {
        guard case .converting(let fraction, _)? = activeConversion?.status else { return 0 }
        return fraction
    }

    static let supportedTypes: [UTType] = [.movie, .quickTimeMovie, .mpeg4Movie, .video]

    init() {
        checkModelAvailability()
        addLaunchArgumentFiles()
    }

    /// Any movie paths passed on the command line land in the queue at launch.
    /// Handy for driving the app straight to a given file without clicking.
    private func addLaunchArgumentFiles() {
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let urls = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        add(urls: urls)
    }

    private func checkModelAvailability() {
        if CoreMLDepthEstimator.bundledModelURL() == nil {
            modelBanner = "The depth model is missing. Relief can't read depth without it."
        }
    }

    // MARK: Queue

    /// Adds files, and says out loud what it did with each one.
    ///
    /// Silently skipping a duplicate or an unreadable file taught the user that
    /// the app eats things. Every rejected intake now gets a sentence.
    func add(urls: [URL]) {
        var added = 0
        var duplicates: [String] = []
        var unsupported: [String] = []

        for url in urls {
            guard !conversions.contains(where: { $0.sourceURL == url }) else {
                duplicates.append(url.lastPathComponent)
                continue
            }
            guard Self.isSupported(url) else {
                unsupported.append(url.lastPathComponent)
                continue
            }
            let conversion = Conversion(sourceURL: url)
            conversions.append(conversion)
            if selectionID == nil { selectionID = conversion.id }
            probe(conversion)
            added += 1
        }

        if !duplicates.isEmpty {
            toasts.info(
                duplicates.count == 1
                    ? "\(duplicates[0]) is already in the queue"
                    : "\(duplicates.count) files were already in the queue"
            )
        }
        if !unsupported.isEmpty {
            toasts.failure(
                unsupported.count == 1
                    ? "Couldn't add \(unsupported[0])"
                    : "Couldn't add \(unsupported.count) files",
                detail: "Relief speaks H.264, HEVC, and ProRes."
            )
        }
        if added > 1 {
            toasts.info("Added \(added) movies")
        }
    }

    /// A dropped file can be anything, so the type is checked before it becomes
    /// a queue row that is guaranteed to fail later.
    static func isSupported(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return supportedTypes.contains { type.conforms(to: $0) }
    }

    func remove(_ conversion: Conversion) {
        guard !conversion.status.isConverting else { return }
        conversions.removeAll { $0.id == conversion.id }
        if selectionID == conversion.id {
            selectionID = conversions.first?.id
            playhead = 0
            if selection == nil { preview.clear() } else { refreshPreview(frameChanged: true) }
        }
    }

    func removeSelected() {
        guard let selection else { return }
        remove(selection)
    }

    /// Generates the test clip and queues it, so someone with no video to hand
    /// can still see what the preview modes do.
    func addSampleClip() {
        guard !isGeneratingSample else { return }
        isGeneratingSample = true
        toasts.info("Making a sample clip", detail: "This takes a few seconds.")

        Task {
            defer { isGeneratingSample = false }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ReliefSample.mov")
            do {
                let clip = try await SyntheticClip.generate(at: url)
                add(urls: [clip])
            } catch {
                toasts.failure("Couldn't make the sample clip", detail: error.localizedDescription)
            }
        }
    }

    private var isGeneratingSample = false

    /// Selection drives the stage.
    func select(_ conversion: Conversion) {
        guard selectionID != conversion.id else { return }
        selectionID = conversion.id
        playhead = 0
        refreshPreview(frameChanged: true)
    }

    // MARK: Preview

    /// Moves the playhead. Scrubbing re-runs the model, because the frame
    /// genuinely changed.
    func scrub(to seconds: Double) {
        playhead = max(0, seconds)
        refreshPreview(frameChanged: true)
    }

    /// Steps by whole frames, or by a second with shift held.
    func step(frames: Int) {
        guard let probe = selection?.probe else { return }
        let delta = Double(frames) / probe.nominalFrameRate
        scrub(to: min(max(playhead + delta, 0), probe.duration.seconds))
    }

    func step(seconds: Double) {
        guard let probe = selection?.probe else { return }
        scrub(to: min(max(playhead + seconds, 0), probe.duration.seconds))
    }

    /// Changing a parameter re-renders from the cached depth, so this is fast
    /// and deliberately does not tell the preview the frame changed.
    func updateTuning(_ tuning: EngineTuning, for conversion: Conversion) {
        conversion.tuning = tuning
        if conversion.id == selectionID { refreshPreview(frameChanged: false) }
    }

    func refreshPreview(frameChanged: Bool) {
        guard let selection, selection.probe != nil else {
            preview.clear()
            return
        }
        preview.update(
            url: selection.sourceURL,
            time: CMTime(seconds: playhead, preferredTimescale: 600),
            mode: previewMode,
            tuning: selection.tuning,
            frameChanged: frameChanged
        )
    }

    func toggleWiggle() {
        guard previewMode == .wiggle else { return }
        preview.isWigglePlaying.toggle()
    }

    private func probe(_ conversion: Conversion) {
        Task { [weak self] in
            do {
                let probe = try await Ingest.probe(url: conversion.sourceURL)
                let thumbnailTime = CMTime(seconds: probe.duration.seconds * 0.25, preferredTimescale: 600)
                conversion.probe = probe
                conversion.status = .ready

                if conversion.id == self?.selectionID {
                    self?.refreshPreview(frameChanged: true)
                }

                if let image = try? await Ingest.image(
                    at: thumbnailTime, url: conversion.sourceURL, maxSize: 256
                ) {
                    conversion.thumbnail = image.value
                }
            } catch {
                conversion.status = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Output naming

    func outputURL(for conversion: Conversion) -> URL {
        let name = filenamePattern.replacingOccurrences(of: "{name}", with: conversion.displayName)
        var candidate = outputFolder.appendingPathComponent(name).appendingPathExtension("mov")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = outputFolder
                .appendingPathComponent("\(name) \(suffix)")
                .appendingPathExtension("mov")
            suffix += 1
        }
        return candidate
    }

    // MARK: Conversion

    /// Converts everything that is Ready, one at a time. Sequential on purpose:
    /// the model and the GPU are the bottleneck, so running two at once would
    /// make both slower and the progress meaningless.
    func convertAllReady() {
        guard conversionTask == nil else { return }
        let queue = conversions.filter { $0.status.isReady || $0.settingsChangedSinceExport }
        guard !queue.isEmpty else { return }

        conversionTask = Task { [weak self] in
            for conversion in queue {
                guard let self, !Task.isCancelled else { break }
                await self.convert(conversion)
            }
            self?.conversionTask = nil
        }
    }

    func convertSelected() {
        guard let selection else { return }
        guard conversionTask == nil else { return }
        conversionTask = Task { [weak self] in
            await self?.convert(selection)
            self?.conversionTask = nil
        }
    }

    /// Runs a finished row again, keeping the existing export. The user decides
    /// when they are done, not the button.
    func reconvert(_ conversion: Conversion) {
        guard !isConverting, conversion.status.isDone else { return }
        conversion.status = .ready
        conversionTask = Task { [weak self] in
            await self?.convert(conversion)
            self?.conversionTask = nil
        }
    }

    /// Roughly what the export will occupy, from the encoder's own bitrate
    /// rule. Warning before an hour of work beats cleaning up after it.
    private func estimatedOutputBytes(for probe: SourceProbe) -> Int64 {
        let bitsPerPixel = 0.15
        let bitsPerSecond = Double(probe.width * probe.height) * probe.nominalFrameRate * bitsPerPixel
        return Int64(bitsPerSecond / 8 * probe.duration.seconds)
    }

    private func freeBytesAtOutput() -> Int64? {
        try? outputFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    /// True when there is room. Says so and refuses when there is not.
    private func hasRoom(for probe: SourceProbe) -> Bool {
        guard let free = freeBytesAtOutput() else { return true }
        let needed = estimatedOutputBytes(for: probe)
        // A little headroom, because the estimate is an estimate.
        guard free < Int64(Double(needed) * 1.2) else { return true }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        toasts.failure(
            "Not enough room to convert",
            detail: "This needs about \(formatter.string(fromByteCount: needed)) and there is \(formatter.string(fromByteCount: free)) free."
        )
        return false
    }

    /// Stops someone starting a conversion that would run for days.
    ///
    /// The video depth model is correct but roughly 300 times slower than the
    /// per frame one, so on anything longer than a short clip it is not a slow
    /// conversion, it is one that never finishes. Better to say so with a real
    /// number than to let a progress bar sit at 1% overnight.
    private func confirmSlowModel(for conversion: Conversion, probe: SourceProbe) -> Bool {
        let model = conversion.tuning.depthModel
        guard model.isExperimental else { return true }

        let seconds = Double(probe.estimatedFrameCount) / model.measuredFramesPerSecond
        // Under a few minutes is nobody's problem.
        guard seconds > 300 else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This would take about \(Self.humanDuration(seconds))."
        alert.informativeText = """
            Steady depth reads a run of frames at a time, which holds depth \
            perfectly still but runs far slower than Normal. On \
            \(probe.displayDuration) of video that is not practical yet.

            Normal converts the same clip in about \
            \(Self.humanDuration(Double(probe.estimatedFrameCount) / 30)).
            """
        alert.addButton(withTitle: "Use Normal Instead")
        alert.addButton(withTitle: "Go Ahead Anyway")

        if alert.runModal() == .alertFirstButtonReturn {
            var updated = conversion.tuning
            updated.depthModel = .perFrame
            conversion.tuning = updated
            toasts.info("Switched to Normal depth", detail: "Steady is only realistic on short clips.")
        }
        return true
    }

    private func convert(_ conversion: Conversion) async {
        guard let probe = conversion.probe else { return }
        guard hasRoom(for: probe) else { return }
        guard confirmSlowModel(for: conversion, probe: probe) else { return }

        SystemNotifier.prepare()

        let request = ConversionRequest(
            probe: probe,
            tuning: conversion.tuning,
            outputURL: outputURL(for: conversion)
        )
        let frozenTuning = conversion.tuning
        conversion.startedAt = Date()
        conversion.status = .converting(fraction: 0, framesDone: 0)
        conversion.report = nil

        // The pipeline runs off the main actor. Events come back onto it, so
        // the UI only ever sees a consistent snapshot.
        let stream = AsyncStream<ConversionEvent> { continuation in
            Task.detached {
                await ConversionController.run(request) { event in
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }

        for await event in stream {
            switch event {
            case .started:
                conversion.status = .converting(fraction: 0, framesDone: 0)

            case .progress(let fraction, let framesDone):
                conversion.status = .converting(fraction: fraction, framesDone: framesDone)
                DockProgress.shared.fraction = fraction

            case .finished(let report):
                conversion.report = report
                conversion.exportedTuning = frozenTuning
                conversion.status = .done(outputURL: report.outputURL)
                conversion.startedAt = nil
                DockProgress.shared.fraction = nil
                print(report.text)
                writeReport(report, for: conversion)

                let url = report.outputURL
                toasts.success(
                    "\(conversion.displayName) is ready",
                    detail: "Send it to the Vision Pro to watch it in 3D.",
                    actionLabel: "Send to Vision Pro"
                ) { [weak self] in
                    self?.share(url)
                }
                SystemNotifier.post(
                    title: "\(conversion.displayName) is ready",
                    body: "Relief finished converting it to spatial video."
                )

            case .failed(let message):
                conversion.status = .failed(message)
                conversion.startedAt = nil
                DockProgress.shared.fraction = nil
                toasts.failure("Couldn't convert \(conversion.displayName)", detail: message)
                SystemNotifier.post(
                    title: "Couldn't convert \(conversion.displayName)",
                    body: message
                )
                SystemNotifier.requestAttention()

            case .cancelled:
                // A cancelled row returns to Ready with its settings intact.
                conversion.status = .ready
                conversion.startedAt = nil
                DockProgress.shared.fraction = nil
            }
        }
    }

    func cancelConversion() {
        guard isConverting else { return }
        conversionTask?.cancel()
        conversionTask = nil
        DockProgress.shared.fraction = nil
        toasts.info("Conversion stopped", detail: "The file is back in the queue, settings intact.")
    }

    /// Opens the system share sheet, which is where AirDrop lives.
    func share(_ url: URL) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(
            relativeTo: .zero,
            of: window.contentView ?? NSView(),
            preferredEdge: .maxY
        )
    }

    // MARK: Reveal and share

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Golden set

    /// Where the golden set lives. Any change to the depth model, the
    /// smoothing, or the disparity mapping re-runs everything in here.
    var goldenSetFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ReliefGoldenSet")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Movies/ReliefGoldenSet")
    }

    /// Queues every clip in the golden set folder and converts the lot.
    func queueGoldenSet() {
        let folder = goldenSetFolder
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            toasts.info(
                "No golden set folder yet",
                detail: "Create ReliefGoldenSet in your Movies folder and put the clips in it."
            )
            return
        }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []

        let movies = contents.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .movie) || type.conforms(to: .video)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !movies.isEmpty else {
            toasts.info("The golden set folder is empty")
            return
        }

        writesGoldenSetReports = true
        add(urls: movies)
        convertAllReady()
    }

    func revealGoldenSetFolder() {
        let folder = goldenSetFolder
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Writes a dated verification report next to each export while a golden
    /// set run is in flight.
    private var writesGoldenSetReports = false

    private func writeReport(_ report: VerificationReport, for conversion: Conversion) {
        guard writesGoldenSetReports else { return }
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withFullDate]
        let name = "\(conversion.displayName)_\(stamp.string(from: Date())).txt"
        let url = report.outputURL.deletingLastPathComponent().appendingPathComponent(name)
        try? report.text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Runs the deterministic stereo sign check and surfaces the result.
    ///
    /// A passing check reports as a success, not as a permanent red banner.
    func runSignConventionCheck() {
        Task {
            do {
                let result = try SignConventionCheck.run()
                print(result.line)
                if result.passed {
                    toasts.success("Stereo check passed", detail: result.detail)
                } else {
                    toasts.failure("Stereo check failed", detail: result.detail)
                }
            } catch {
                print("FAIL  Stereo sign convention: \(error.localizedDescription)")
                toasts.failure("Stereo check failed", detail: error.localizedDescription)
            }
        }
    }

    // MARK: Quitting

    /// Whether quitting right now would throw away work.
    ///
    /// Cmd Q at frame 40,000 of 180,000 used to just exit. This is the one
    /// place in the app a confirmation dialog is the right call: genuinely
    /// destructive, genuinely irreversible.
    func confirmQuitWhileConverting() -> Bool {
        guard let active = activeConversion else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Relief is still converting \(active.displayName)."

        if case .converting(let fraction, _) = active.status {
            let remaining = active.estimatedSecondsRemaining
                .map { " About \(Self.humanDuration($0)) left." } ?? ""
            alert.informativeText =
                "It is \(Int(fraction * 100))% done.\(remaining) Quitting now discards it."
        } else {
            alert.informativeText = "Quitting now discards it."
        }

        alert.addButton(withTitle: "Keep Converting")
        alert.addButton(withTitle: "Quit and Discard")
        alert.buttons.last?.hasDestructiveAction = true

        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Plain language duration, for progress and dialogs. "About 25 min left"
    /// is information; "40%" on a two hour film is just anxiety.
    static func humanDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "a moment" }
        if seconds < 60 { return "under a minute" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let leftover = minutes % 60
        return leftover == 0 ? "\(hours) hr" : "\(hours) hr \(leftover) min"
    }
}
