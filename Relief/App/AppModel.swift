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

    /// Set when the depth model could not be loaded, so the UI can say so
    /// rather than failing one conversion at a time.
    var modelBanner: String?

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

    func add(urls: [URL]) {
        for url in urls {
            guard !conversions.contains(where: { $0.sourceURL == url }) else { continue }
            let conversion = Conversion(sourceURL: url)
            conversions.append(conversion)
            if selectionID == nil { selectionID = conversion.id }
            probe(conversion)
        }
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

    private func convert(_ conversion: Conversion) async {
        guard let probe = conversion.probe else { return }

        let request = ConversionRequest(
            probe: probe,
            tuning: conversion.tuning,
            outputURL: outputURL(for: conversion)
        )
        let frozenTuning = conversion.tuning
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
            case .finished(let report):
                conversion.report = report
                conversion.exportedTuning = frozenTuning
                conversion.status = .done(outputURL: report.outputURL)
                print(report.text)
                writeReport(report, for: conversion)
            case .failed(let message):
                conversion.status = .failed(message)
            case .cancelled:
                // A cancelled row returns to Ready with its settings intact.
                conversion.status = .ready
            }
        }
    }

    func cancelConversion() {
        conversionTask?.cancel()
        conversionTask = nil
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
            modelBanner = "No golden set at \(folder.path). Create the folder and put the five clips in it."
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
            modelBanner = "The golden set folder is empty."
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
    func runSignConventionCheck() {
        Task {
            let line: String
            do {
                line = try SignConventionCheck.run().line
            } catch {
                line = "FAIL  Stereo sign convention: \(error.localizedDescription)"
            }
            print(line)
            modelBanner = line
        }
    }
}
