import SwiftUI
import Observation
import AVFoundation
import UniformTypeIdentifiers

/// One file's journey through Make It 3D.
@Observable
@MainActor
final class Conversion: Identifiable {
    enum FailureKind: Equatable {
        case intake
        case conversion
    }

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

        /// A row that can move ahead without interrupting finished or in-flight
        /// work. Files that are still being read cannot promise to be next yet.
        var canMoveInQueue: Bool {
            switch self {
            case .ready: true
            case .probing, .converting, .done, .failed: false
            }
        }
    }

    let id = UUID()
    let sourceURL: URL
    var status: Status = .probing
    var probe: SourceProbe?
    var thumbnail: CGImage?
    var report: VerificationReport?
    var failureKind: FailureKind?

    /// The film broken into shots, each with settings solved for it. nil until
    /// Auto has been run on this file.
    var shotPlan: ShotPlan?
    /// Progress of the analysis pass, 0 to 1. nil when not running.
    var planningProgress: Double?

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

    var canMoveInQueue: Bool {
        planningProgress == nil && (status.canMoveInQueue || settingsChangedSinceExport)
    }

    var displayName: String { sourceURL.deletingPathExtension().lastPathComponent }

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }
}

/// What this run is allowed to pick up. A selected run is a frozen promise;
/// an all-ready run also admits videos added while it is working.
enum QueueRunScope: Equatable {
    case selectedSnapshot
    case allReadyIncludingAdditions
    case retryGroup
}

/// Queue controls are explicit states so Pause, Stop After Current, and Stop
/// Now cannot collapse into one ambiguous Boolean.
enum QueuePhase: Equatable {
    case idle
    case running
    case pauseAfterCurrent
    case stopAfterCurrent
    case paused
    case stopping
}

struct QueueWorkSummary: Equatable {
    var totalCount = 0
    var completedCount = 0
    var waitingCount = 0
    var preparingCount = 0
    var activeCount = 0
    var failedCount = 0
    var skippedCount = 0
    var knownRemainingSeconds: Double = 0
    var unknownTimeCount = 0
    var knownOutputBytes: Int64 = 0
    var unknownSizeCount = 0
}

/// The root of the app: the queue, the selection, and the settings.
@Observable
@MainActor
final class AppModel {

    typealias ConversionRunner = @Sendable (
        ConversionRequest,
        @escaping @Sendable (ConversionEvent) -> Void
    ) async -> Void

    var conversions: [Conversion] = []

    /// The row driving the stage. One row, always, because there is one stage.
    var selectionID: Conversion.ID?

    /// Every row the user has selected. Removing thirteen files one at a time
    /// is not a workflow, so the queue selects like a Finder list: click,
    /// shift click for a run, command click to pick and choose.
    var selectedIDs: Set<Conversion.ID> = []

    /// Where a shift click measures from.
    private var selectionAnchorID: Conversion.ID?

    private(set) var queuePhase: QueuePhase = .idle

    var queueRunning: Bool { queuePhase != .idle }
    var queuePaused: Bool { queuePhase == .paused }
    var pauseRequested: Bool { queuePhase == .pauseAfterCurrent }
    var stopAfterCurrentRequested: Bool { queuePhase == .stopAfterCurrent }

    /// Persistent confirmation for the last priority change. Unlike a toast,
    /// this remains visible until dismissed or the prioritised work begins.
    var priorityNotice: QueuePriorityNoticeContent?
    private var priorityNoticeIDs: Set<Conversion.ID> = []

    // MARK: Queue sections

    /// Converted. These are done with the pipeline and waiting to go to the
    /// headset, so they are not "queue" in any sense the word carries.
    var finished: [Conversion] {
        conversions.filter { $0.status.isDone && !$0.settingsChangedSinceExport }
    }

    /// Everything still to do, including failures, which belong with the work
    /// rather than with the results. The active conversion stays at the top of
    /// this section; prioritising another row means "next", never "interrupt".
    var upNext: [Conversion] {
        let unfinished = conversions.filter { !$0.status.isDone || $0.settingsChangedSinceExport }
        guard let active = unfinished.first(where: { $0.status.isConverting }) else {
            return unfinished
        }
        return [active] + unfinished.filter { $0.id != active.id }
    }

    /// Rows the queue would pick up on its own.
    var readyToConvert: [Conversion] {
        conversions.filter {
            $0.planningProgress == nil
                && ($0.status.isReady || $0.settingsChangedSinceExport)
        }
    }

    /// Ready rows in their true execution order. This is the source for queue
    /// positions, priority groups, and internal drag-and-drop reordering.
    var queuedWaiting: [Conversion] {
        conversions.filter(\.canMoveInQueue)
    }

    /// The same order the sidebar presents. Shift-selection follows this list,
    /// so pinning the active row cannot make the selected range disagree with
    /// what is visibly between the two clicks.
    var displayedConversions: [Conversion] { finished + upNext }

    /// What the user has actually picked out.
    var selectedConversions: [Conversion] {
        conversions.filter { selectedIDs.contains($0.id) }
    }

    /// The selection, minus anything already converted or mid flight. This is
    /// what Convert acts on, because a button that says one thing and does
    /// another is worse than a button that does nothing.
    var selectedReady: [Conversion] {
        selectedConversions.filter {
            $0.planningProgress == nil
                && ($0.status.isReady || $0.settingsChangedSinceExport)
        }
    }

    var failedConversions: [Conversion] {
        conversions.filter { conversion in
            if case .failed = conversion.status { return true }
            return false
        }
    }

    /// True when there is more work in the list than the user has selected, so
    /// the "do the lot" action is worth showing.
    var hasUnselectedWork: Bool {
        readyToConvert.count > selectedReady.count
    }

    /// Set only when the depth model could not be loaded, which is a standing
    /// condition rather than an event. Everything that happens once goes
    /// through the toast center instead, so good news never renders as a
    /// permanent red alarm.
    var modelBanner: String?

    let toasts = ToastCenter()
    let onboarding = Onboarding()

    // MARK: Preview

    let preview = PreviewController()
    var previewMode: PreviewMode = .source {
        didSet {
            refreshPreview(frameChanged: false)
            onboarding.previewModeUsed(previewMode, toasts: toasts)
        }
    }
    /// Playhead position in seconds.
    var playhead: Double = 0

    var inspectorVisible = true
    var sidebarVisible = true

    /// Where exports land.
    ///
    /// Downloads, not the Movies folder. Downloads is the one people already
    /// know how to find, it is in every Finder sidebar, and it is where a file
    /// you are about to send somewhere else belongs. Movies is where a library
    /// lives,
    /// and this app does not make libraries, it makes files you hand to a
    /// headset. The destination is also shown next to Convert, because a
    /// setting nobody can find is a setting that does not exist.
    var outputFolder: URL = FileManager.default.urls(
        for: .downloadsDirectory, in: .userDomainMask
    ).first ?? FileManager.default.homeDirectoryForCurrentUser

    /// Filename pattern for exports. `{name}` is replaced with the source name.
    var filenamePattern: String = "{name}_spatial"

    private struct QueueRunContext {
        let scope: QueueRunScope
        var admittedIDs: Set<Conversion.ID>
        var completedIDs: Set<Conversion.ID> = []
        var failedIDs: Set<Conversion.ID> = []
        var skippedIDs: Set<Conversion.ID> = []
    }

    private enum ActiveCancellation {
        case stop(attempt: UUID)
        case skip(attempt: UUID)

        var attempt: UUID {
            switch self {
            case .stop(let attempt), .skip(let attempt): attempt
            }
        }
    }

    private var runContext: QueueRunContext?
    private var queueDriverTask: Task<Void, Never>?
    private var activePipelineTask: Task<Void, Never>?
    private var activeAttemptID: UUID?
    private var activeCancellation: ActiveCancellation?
    private let conversionRunner: ConversionRunner
    private let systemFeedbackEnabled: Bool

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
        guard let context = runContext, !context.admittedIDs.isEmpty else {
            guard case .converting(let fraction, _)? = activeConversion?.status else { return 0 }
            return fraction
        }

        let resolved = context.completedIDs
            .union(context.failedIDs)
            .union(context.skippedIDs)
            .count
        let activeFraction: Double
        if case .converting(let fraction, _)? = activeConversion?.status {
            activeFraction = fraction
        } else {
            activeFraction = 0
        }
        return min(Double(resolved) + activeFraction, Double(context.admittedIDs.count))
            / Double(context.admittedIDs.count)
    }

    var currentRunScope: QueueRunScope? { runContext?.scope }

    var nextWaitingConversion: Conversion? {
        queuedWaiting.first { conversion in
            guard let context = runContext else { return true }
            return context.admittedIDs.contains(conversion.id)
                && !context.skippedIDs.contains(conversion.id)
        }
    }

    func isInCurrentRun(_ conversion: Conversion) -> Bool {
        runContext?.admittedIDs.contains(conversion.id) == true
    }

    func isSkippedInCurrentRun(_ conversion: Conversion) -> Bool {
        runContext?.skippedIDs.contains(conversion.id) == true
    }

    func queuePosition(for conversion: Conversion) -> QueuePosition? {
        let ordered: [Conversion]
        if let context = runContext {
            ordered = queuedWaiting.filter {
                context.admittedIDs.contains($0.id) && !context.skippedIDs.contains($0.id)
            }
        } else {
            ordered = queuedWaiting
        }
        guard let index = ordered.firstIndex(where: { $0.id == conversion.id }) else { return nil }
        return index == 0 ? .next : .numbered(index + 1)
    }

    var queueWorkSummary: QueueWorkSummary {
        let ids = runContext?.admittedIDs ?? Set(upNext.map(\.id))
        var summary = QueueWorkSummary()
        summary.totalCount = ids.count

        for conversion in conversions where ids.contains(conversion.id) {
            if runContext?.skippedIDs.contains(conversion.id) == true {
                summary.skippedCount += 1
                continue
            }
            if runContext?.failedIDs.contains(conversion.id) == true {
                summary.failedCount += 1
                continue
            }
            if runContext?.completedIDs.contains(conversion.id) == true {
                summary.completedCount += 1
                continue
            }

            let isChangedExport = conversion.settingsChangedSinceExport
            let isExplicitRedo = runContext?.scope == .retryGroup && conversion.status.isDone
            if isChangedExport || isExplicitRedo {
                summary.waitingCount += 1
            } else {
                switch conversion.status {
                case .probing:
                    summary.preparingCount += 1
                case .ready:
                    if conversion.planningProgress == nil {
                        summary.waitingCount += 1
                    } else {
                        summary.preparingCount += 1
                    }
                case .converting:
                    summary.activeCount += 1
                case .done:
                    if runContext == nil { summary.completedCount += 1 }
                case .failed:
                    summary.failedCount += 1
                }
            }

            guard (isChangedExport || isExplicitRedo || !conversion.status.isDone),
                  conversion.failureMessage == nil
            else { continue }
            if let probe = conversion.probe {
                summary.knownOutputBytes = Self.addingWithoutOverflow(
                    summary.knownOutputBytes,
                    estimatedOutputBytes(for: probe)
                )
                if let measured = conversion.estimatedSecondsRemaining {
                    summary.knownRemainingSeconds += measured
                } else {
                    summary.knownRemainingSeconds += Double(probe.estimatedFrameCount)
                        / conversion.tuning.depthModel.measuredFramesPerSecond
                }
            } else {
                summary.unknownSizeCount += 1
                summary.unknownTimeCount += 1
            }
        }
        return summary
    }

    var queueSummaryText: String {
        let summary = queueWorkSummary
        guard summary.totalCount > 0 else { return "No videos waiting" }

        let countText: String
        if runContext != nil {
            let resolved = summary.completedCount + summary.failedCount + summary.skippedCount
            let current = resolved + (summary.activeCount > 0 ? 1 : 0)
            countText = "\(min(current, summary.totalCount)) of \(summary.totalCount)"
        } else {
            countText = summary.totalCount == 1 ? "1 video" : "\(summary.totalCount) videos"
        }

        guard summary.knownRemainingSeconds > 0 else { return countText }
        let suffix = summary.unknownTimeCount > 0 ? "+" : ""
        return "\(countText) • about \(Self.humanDuration(summary.knownRemainingSeconds))\(suffix)"
    }

    var queueOutputEstimateText: String? {
        let summary = queueWorkSummary
        guard summary.knownOutputBytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let size = formatter.string(fromByteCount: summary.knownOutputBytes)
        let suffix = summary.unknownSizeCount > 0 ? "+" : ""
        return "About \(size)\(suffix) output"
    }

    static let supportedTypes: [UTType] = [.movie, .quickTimeMovie, .mpeg4Movie, .video]

    init(
        conversionRunner: @escaping ConversionRunner = ConversionController.run,
        systemFeedbackEnabled: Bool = true
    ) {
        self.conversionRunner = conversionRunner
        self.systemFeedbackEnabled = systemFeedbackEnabled
        checkModelAvailability()
        addLaunchArgumentFiles()
    }

    /// Any video paths passed on the command line land in the queue at launch.
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
            modelBanner = "The depth model is missing. Make It 3D can't read depth without it."
        }
    }

    // MARK: Queue

    /// Adds files, and says out loud what it did with each one.
    ///
    /// Silently skipping a duplicate or an unreadable file taught the user that
    /// the app eats things. Every rejected intake now gets a sentence.
    func add(urls: [URL]) {
        var added: [Conversion] = []
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
            admitAddedConversionIfNeeded(conversion)
            probe(conversion)
            added.append(conversion)
        }

        if !duplicates.isEmpty {
            toasts.info(
                duplicates.count == 1
                    ? "\(duplicates[0]) is already here"
                    : "\(duplicates.count) files were already here"
            )
        }
        if !unsupported.isEmpty {
            toasts.failure(
                unsupported.count == 1
                    ? "Couldn't add \(unsupported[0])"
                    : "Couldn't add \(unsupported.count) files",
                detail: "Make It 3D reads H.264, HEVC, and ProRes."
            )
        }

        guard let first = added.first else { return }

        // Dropping a file used to do two things silently: it set selectionID
        // directly, which skipped the preview refresh that select() performs,
        // so the stage stayed empty and the file looked like it had not
        // arrived. And a single added file got no toast at all, because the
        // announcement was behind `added > 1`. Both are fixed here: the drop
        // lands you on the file, and it says so.
        select(first)

        if added.count == 1 {
            toasts.success("Added \(first.displayName)", detail: "Working out the depth now.")
        } else {
            toasts.success("Added \(added.count) videos", detail: "Working out the depth for each one.")
        }

        // Auto runs on arrival rather than waiting to be asked.
        //
        // This is the fix for a question the UI could not answer: with a Set
        // the depth button at the top and a Convert button at the bottom, both
        // filled in the same accent, there was no way to know which came first.
        // Rather than label the sequence, remove it. By the time anyone has
        // looked at the picture the depth is already set, and there is exactly
        // one button left to press.
        for conversion in added {
            autoTune(conversion, announce: false)
        }
    }

    // MARK: Auto

    /// Reads the whole file, finds the cuts, and solves the depth settings for
    /// each shot.
    ///
    /// This is the answer to "why should I have to know what Soft and Deep
    /// mean". The strength and balance dials stay, because sometimes you want
    /// something other than comfortable, but nobody should have to touch them
    /// to get a good result.
    /// - Parameter announce: false when this runs by itself on arrival, so the
    ///   automatic pass does not narrate itself. The panel already shows
    ///   progress, and a toast for something nobody asked for is noise.
    func autoTune(_ conversion: Conversion, announce: Bool = true) {
        guard conversion.planningProgress == nil, !conversion.status.isConverting else { return }
        // Planning begins now, not once probing catches up. Keeping this marker
        // set prevents a just-probed row from starting with pre-plan settings.
        conversion.planningProgress = 0
        guard conversion.probe != nil else {
            // Probing is async and a dropped file gets here first. Wait for it
            // rather than telling the user to try again, which is asking them
            // to do the app's waiting for it.
            Task { [weak self] in
                for _ in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self else { return }
                    if conversion.probe != nil {
                        self.runAutoTune(conversion, announce: announce)
                        return
                    }
                }
                guard let self else { return }
                conversion.planningProgress = nil
                self.scheduleQueueDriverIfNeeded()
            }
            return
        }
        runAutoTune(conversion, announce: announce)
    }

    private func runAutoTune(_ conversion: Conversion, announce: Bool) {
        guard let probe = conversion.probe else {
            conversion.planningProgress = nil
            scheduleQueueDriverIfNeeded()
            return
        }
        if announce {
            toasts.info("Looking at every shot", detail: "Sampling the film to work out its depth.")
        }

        Task { [weak self] in
            defer {
                conversion.planningProgress = nil
                self?.scheduleQueueDriverIfNeeded()
            }
            do {
                let estimator = try CoreMLDepthEstimator()
                let tuning = conversion.tuning
                let plan = try await ShotPlanner.plan(
                    for: probe,
                    estimator: estimator,
                    tuning: tuning
                ) { fraction in
                    Task { @MainActor in conversion.planningProgress = fraction }
                }
                guard let self else { return }
                self.applied(plan, to: conversion)
            } catch {
                self?.toasts.failure(
                    "Couldn't analyse \(conversion.displayName)",
                    detail: error.localizedDescription
                )
            }
        }
    }

    private func applied(_ plan: ShotPlan, to conversion: Conversion) {
        conversion.shotPlan = plan
        guard let first = plan.shots.first else {
            toasts.failure("Couldn't find any shots", detail: "The file may be too short to sample.")
            return
        }

        // The live dials follow whichever shot the playhead is in, so the
        // inspector keeps telling the truth about what you are looking at.
        let atPlayhead = plan.shot(at: CMTime(seconds: playhead, preferredTimescale: 600)) ?? first
        conversion.tuning = AutoTune.apply(atPlayhead.settings, to: conversion.tuning)
        refreshPreview(frameChanged: false)

        toasts.success(
            plan.shots.count == 1 ? "Tuned this shot" : "Tuned \(plan.shots.count) shots",
            detail: plan.summary
        )
    }

    /// True when the dials no longer say what Auto set them to.
    ///
    /// This is the only condition under which re-running the analysis means
    /// anything. Auto is deterministic: same file, same sampling interval, same
    /// model, same thresholds, byte identical result. A button offering to run
    /// it again could not change the outcome, and offering to redo something
    /// implies the first answer was provisional when it was not.
    func hasDriftedFromAuto(_ conversion: Conversion) -> Bool {
        guard let plan = conversion.shotPlan else { return false }
        let time = CMTime(seconds: playhead, preferredTimescale: 600)
        guard let shot = plan.shot(at: time) else { return false }
        return AutoTune.apply(shot.settings, to: conversion.tuning) != conversion.tuning
    }

    /// Puts the automatic answer back.
    func returnToAutomatic(_ conversion: Conversion) {
        guard !conversion.status.isConverting else { return }
        guard let plan = conversion.shotPlan else { return }
        let time = CMTime(seconds: playhead, preferredTimescale: 600)
        guard let shot = plan.shot(at: time) else { return }
        conversion.tuning = AutoTune.apply(shot.settings, to: conversion.tuning)
        refreshPreview(frameChanged: false)
        toasts.info("Back to the automatic settings")
    }

    /// Follows the playhead into a new shot and adopts its settings.
    func adoptShotSettings(at seconds: Double, for conversion: Conversion) {
        guard !conversion.status.isConverting else { return }
        guard let plan = conversion.shotPlan else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let shot = plan.shot(at: time) else { return }
        let updated = AutoTune.apply(shot.settings, to: conversion.tuning)
        guard updated != conversion.tuning else { return }
        conversion.tuning = updated
    }

    /// Picks where exports land. Reachable from the inspector as well as from
    /// Settings, because the moment someone wants to change it is the moment
    /// they are looking at the Convert button.
    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputFolder
        panel.prompt = "Save here"
        panel.message = "Where should converted videos be saved?"
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
            toasts.info("Saving to \(url.lastPathComponent)")
        }
    }

    /// Empties the Finished list. The exported files stay on disk: this clears
    /// the record of them, not the work.
    func clearFinished() {
        let ids = Set(finished.map(\.id))
        guard !ids.isEmpty else { return }
        conversions.removeAll { ids.contains($0.id) }
        selectedIDs.subtract(ids)
        if var context = runContext {
            context.admittedIDs.subtract(ids)
            context.completedIDs.subtract(ids)
            context.failedIDs.subtract(ids)
            context.skippedIDs.subtract(ids)
            runContext = context
        }
        if let current = selectionID, ids.contains(current) {
            if let next = conversions.first {
                selectionID = next.id
                selectedIDs = [next.id]
                refreshPreview(frameChanged: true)
            } else {
                selectionID = nil
                selectedIDs = []
                preview.clear()
            }
        }
        toasts.info(
            ids.count == 1 ? "Cleared 1 finished video" : "Cleared \(ids.count) finished videos",
            detail: "The exported files are still in \(outputFolder.lastPathComponent)."
        )
    }

    /// The open panel, on the model so every "add videos" affordance opens the
    /// same one rather than each surface growing its own.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.supportedTypes
        panel.prompt = "Add"
        panel.message = "Pick the videos to convert to spatial video."
        if panel.runModal() == .OK {
            add(urls: panel.urls)
        }
    }

    /// A dropped file can be anything, so the type is checked before it becomes
    /// a queue row that is guaranteed to fail later.
    static func isSupported(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return supportedTypes.contains { type.conforms(to: $0) }
    }

    func remove(_ conversion: Conversion) {
        remove(ids: [conversion.id])
    }

    /// A right click inside a multi-selection acts on the movable part of that
    /// selection. A right click outside it acts only on the clicked row.
    func priorityCandidates(for clicked: Conversion) -> [Conversion] {
        if selectedIDs.count > 1, selectedIDs.contains(clicked.id) {
            return conversions.filter {
                selectedIDs.contains($0.id) && $0.canMoveInQueue
            }
        }
        return clicked.canMoveInQueue ? [clicked] : []
    }

    var selectedPriorityCandidates: [Conversion] {
        conversions.filter { selectedIDs.contains($0.id) && $0.canMoveInQueue }
    }

    func canPrioritize(_ candidates: [Conversion]) -> Bool {
        guard queuePhase != .stopAfterCurrent, queuePhase != .stopping else {
            return false
        }
        let ordered = candidatesInQueueOrder(candidates.map(\.id))
        guard !ordered.isEmpty else { return false }
        let orderedIDs = ordered.map(\.id)
        let prefixIDs = Array(queuedWaiting.prefix(ordered.count)).map(\.id)
        let needsAdmission = runContext.map { context in
            orderedIDs.contains { !context.admittedIDs.contains($0) }
        } ?? false
        return orderedIDs != prefixIDs || needsAdmission
    }

    func canMoveToTopOfQueue(_ conversion: Conversion) -> Bool {
        canPrioritize([conversion])
    }

    func prioritizeSelection() {
        prioritize(selectedPriorityCandidates)
    }

    /// Moves a group to the first runnable positions without interrupting the
    /// active conversion. Their relative order, focus, and selection survive.
    func prioritize(_ candidates: [Conversion]) {
        let ordered = candidatesInQueueOrder(candidates.map(\.id))
        guard canPrioritize(ordered) else { return }

        let movingIDs = ordered.map(\.id)
        let firstOther = queuedWaiting.first { !movingIDs.contains($0.id) }
        reorderQueued(ids: movingIDs, before: firstOther?.id, announce: false)
        admitToCurrentRun(movingIDs)

        let content = QueuePriorityCopy.confirmation(
            names: ordered.map(\.displayName),
            queueRunning: queueRunning
        )
        priorityNotice = content
        priorityNoticeIDs = Set(movingIDs)
        toasts.info(content.title, detail: content.detail)
        scheduleQueueDriverIfNeeded()
    }

    func moveToTopOfQueue(_ conversion: Conversion) {
        prioritize([conversion])
    }

    /// Reorders only ready slots, leaving active, preparing, failed, and
    /// converted rows exactly where they are. Passing nil appends the group.
    func reorderQueued(
        ids: [Conversion.ID],
        before destinationID: Conversion.ID?,
        announce: Bool = true
    ) {
        let moving = candidatesInQueueOrder(ids)
        guard !moving.isEmpty else { return }
        let movingIDs = Set(moving.map(\.id))
        if let destinationID, movingIDs.contains(destinationID) { return }
        let originalOrder = queuedWaiting.map(\.id)
        var remaining = queuedWaiting.filter { !movingIDs.contains($0.id) }

        let insertionIndex: Int
        if let destinationID,
           let target = remaining.firstIndex(where: { $0.id == destinationID }) {
            insertionIndex = target
        } else {
            insertionIndex = remaining.endIndex
        }
        remaining.insert(contentsOf: moving, at: insertionIndex)
        guard remaining.map(\.id) != originalOrder else { return }

        // Build the reordered array off to the side, then publish it once.
        // Replacing slots directly exposed transient duplicate IDs to SwiftUI
        // (the moved reference appeared at its new index before disappearing
        // from the old one), which could leave stale position badges behind.
        var reordered = conversions
        var iterator = remaining.makeIterator()
        for index in reordered.indices where reordered[index].canMoveInQueue {
            if let replacement = iterator.next() { reordered[index] = replacement }
        }
        conversions = reordered

        if announce {
            priorityNotice = QueuePriorityNoticeContent(
                title: moving.count == 1 ? "Queue order updated" : "\(moving.count) videos reordered",
                detail: "The position labels show the new order."
            )
            priorityNoticeIDs = movingIDs
        }
        scheduleQueueDriverIfNeeded()
    }

    func dismissPriorityNotice() {
        priorityNotice = nil
        priorityNoticeIDs = []
    }

    private func candidatesInQueueOrder(_ ids: [Conversion.ID]) -> [Conversion] {
        let idSet = Set(ids)
        return conversions.filter { idSet.contains($0.id) && $0.canMoveInQueue }
    }

    /// Removes everything selected, in one go.
    ///
    /// A converting row is left alone rather than silently skipped without
    /// explanation, because pulling the file out from under a running pipeline
    /// is the one removal that can corrupt an export.
    func removeSelected() {
        guard !selectedIDs.isEmpty else { return }
        remove(ids: selectedIDs)
    }

    private func remove(ids: Set<Conversion.ID>) {
        let doomed = conversions.filter { ids.contains($0.id) }
        let running = doomed.filter(\.status.isConverting)
        let removable = doomed.filter { !$0.status.isConverting }
        guard !removable.isEmpty else {
            if !running.isEmpty {
                toasts.info("That one is converting", detail: "Stop it first, then remove it.")
            }
            return
        }

        let removableIDs = Set(removable.map(\.id))
        conversions.removeAll { removableIDs.contains($0.id) }
        selectedIDs.subtract(removableIDs)
        if var context = runContext {
            context.admittedIDs.subtract(removableIDs)
            context.completedIDs.subtract(removableIDs)
            context.failedIDs.subtract(removableIDs)
            context.skippedIDs.subtract(removableIDs)
            runContext = context
        }
        if !priorityNoticeIDs.isDisjoint(with: removableIDs) {
            dismissPriorityNotice()
        }
        if let anchor = selectionAnchorID, removableIDs.contains(anchor) {
            selectionAnchorID = nil
        }

        if let current = selectionID, removableIDs.contains(current) {
            if let next = conversions.first {
                selectionID = next.id
                selectedIDs = [next.id]
                playhead = 0
                refreshPreview(frameChanged: true)
            } else {
                selectionID = nil
                selectedIDs = []
                playhead = 0
                preview.clear()
            }
        }

        if removable.count == 1 {
            toasts.info("Removed \(removable[0].displayName)")
        } else {
            toasts.info("Removed \(removable.count) videos")
        }
        if !running.isEmpty {
            toasts.info("Kept the one that is converting", detail: "Stop it first if you want it gone.")
        }
    }

    // MARK: Selection

    /// Shift click: everything between the anchor and here.
    func extendSelection(to conversion: Conversion) {
        guard let anchor = selectionAnchorID ?? selectionID,
              let start = displayedConversions.firstIndex(where: { $0.id == anchor }),
              let end = displayedConversions.firstIndex(where: { $0.id == conversion.id })
        else {
            select(conversion)
            return
        }
        let range = start <= end ? start...end : end...start
        selectedIDs = Set(displayedConversions[range].map(\.id))
        focus(conversion)
    }

    /// Command click: add or drop one row without disturbing the rest.
    func toggleSelection(_ conversion: Conversion) {
        if selectedIDs.contains(conversion.id), selectedIDs.count > 1 {
            selectedIDs.remove(conversion.id)
            if selectionID == conversion.id,
               let next = conversions.first(where: { selectedIDs.contains($0.id) }) {
                focus(next)
            }
        } else {
            selectedIDs.insert(conversion.id)
            selectionAnchorID = conversion.id
            focus(conversion)
        }
    }

    func selectAll() {
        guard !conversions.isEmpty else { return }
        selectedIDs = Set(conversions.map(\.id))
        if selectionID == nil, let first = conversions.first { focus(first) }
    }

    /// Moves the stage to a row without changing what is selected.
    private func focus(_ conversion: Conversion) {
        guard selectionID != conversion.id else { return }
        selectionID = conversion.id
        playhead = 0
        refreshPreview(frameChanged: true)
    }

    // MARK: Running the queue

    private func startQueue(_ work: [Conversion], scope: QueueRunScope) {
        guard queuePhase == .idle, queueDriverTask == nil, activePipelineTask == nil else { return }
        guard !work.isEmpty else { return }

        runContext = QueueRunContext(scope: scope, admittedIDs: Set(work.map(\.id)))
        queuePhase = .running
        if work.count > 1 {
            toasts.info("Converting \(work.count) videos", detail: "They run one after another.")
        }
        scheduleQueueDriverIfNeeded()
    }

    private func admitAddedConversionIfNeeded(_ conversion: Conversion) {
        guard var context = runContext,
              context.scope == .allReadyIncludingAdditions,
              queuePhase != .stopAfterCurrent,
              queuePhase != .stopping
        else { return }
        context.admittedIDs.insert(conversion.id)
        runContext = context
    }

    private func admitToCurrentRun(_ ids: [Conversion.ID]) {
        guard var context = runContext,
              queuePhase != .stopAfterCurrent,
              queuePhase != .stopping
        else { return }
        context.admittedIDs.formUnion(ids)
        context.completedIDs.subtract(ids)
        context.skippedIDs.subtract(ids)
        context.failedIDs.subtract(ids)
        runContext = context
    }

    private func recordFailureInCurrentRun(_ id: Conversion.ID) {
        guard var context = runContext, context.admittedIDs.contains(id) else { return }
        context.failedIDs.insert(id)
        runContext = context
    }

    private func recordCompletionInCurrentRun(_ id: Conversion.ID) {
        guard var context = runContext, context.admittedIDs.contains(id) else { return }
        context.completedIDs.insert(id)
        context.failedIDs.remove(id)
        context.skippedIDs.remove(id)
        runContext = context
    }

    private func scheduleQueueDriverIfNeeded() {
        guard queuePhase == .running,
              queueDriverTask == nil,
              activePipelineTask == nil,
              runContext != nil
        else { return }

        queueDriverTask = Task { [weak self] in
            await self?.driveQueue()
        }
    }

    private func driveQueue() async {
        while queuePhase == .running {
            guard let next = nextInRun() else {
                queueDriverTask = nil
                if hasAdmittedPreparationInFlight { return }
                finishRun(announce: true)
                return
            }

            await convert(next)

            switch queuePhase {
            case .running:
                continue
            case .pauseAfterCurrent:
                queuePhase = .paused
                queueDriverTask = nil
                toasts.info("Queue paused", detail: "\(next.displayName) finished. Resume when you're ready.")
                return
            case .stopAfterCurrent:
                queueDriverTask = nil
                finishRun(announce: false)
                toasts.info("Queue stopped", detail: "\(next.displayName) finished first.")
                return
            case .stopping:
                queueDriverTask = nil
                finishRun(announce: false)
                toasts.info("Conversion stopped", detail: "The file is back in the queue, settings intact.")
                return
            case .paused, .idle:
                queueDriverTask = nil
                return
            }
        }
        queueDriverTask = nil
    }

    private func nextInRun() -> Conversion? {
        guard let context = runContext else { return nil }
        return conversions.first { conversion in
            guard context.admittedIDs.contains(conversion.id),
                  !context.completedIDs.contains(conversion.id),
                  !context.skippedIDs.contains(conversion.id),
                  !context.failedIDs.contains(conversion.id),
                  conversion.planningProgress == nil
            else { return false }

            if conversion.status.isReady || conversion.settingsChangedSinceExport {
                return true
            }
            // An explicit redo deliberately starts from the existing .done
            // state so cancellation or failure can restore its prior output.
            return context.scope == .retryGroup && conversion.status.isDone
        }
    }

    private var hasAdmittedPreparationInFlight: Bool {
        guard let context = runContext else { return false }
        return conversions.contains { conversion in
            guard context.admittedIDs.contains(conversion.id),
                  !context.skippedIDs.contains(conversion.id)
            else { return false }
            if case .probing = conversion.status { return true }
            return conversion.planningProgress != nil
        }
    }

    private func finishRun(announce: Bool) {
        let completed = runContext?.completedIDs.count ?? 0
        let failed = runContext?.failedIDs.count ?? 0
        let skipped = runContext?.skippedIDs.count ?? 0
        let total = runContext?.admittedIDs.count ?? 0

        runContext = nil
        queuePhase = .idle
        queueDriverTask = nil
        activePipelineTask = nil
        activeAttemptID = nil
        activeCancellation = nil

        guard announce, total > 1 else { return }
        var details = ["\(completed) ready to send"]
        if failed > 0 { details.append("\(failed) failed") }
        if skipped > 0 { details.append("\(skipped) skipped") }
        toasts.success("Queue finished", detail: details.joined(separator: " • "))
    }

    func pauseAfterCurrent() {
        guard queuePhase == .running else { return }
        guard isConverting else {
            queuePhase = .paused
            queueDriverTask?.cancel()
            queueDriverTask = nil
            toasts.info("Queue paused")
            return
        }
        queuePhase = .pauseAfterCurrent
        toasts.info("Pausing after this video", detail: "The current conversion will finish safely.")
    }

    func stopAfterCurrent() {
        guard queuePhase == .running || queuePhase == .pauseAfterCurrent else { return }
        guard isConverting else {
            finishRun(announce: false)
            toasts.info("Queue stopped")
            return
        }
        queuePhase = .stopAfterCurrent
        toasts.info("Stopping after this video", detail: "The current conversion will finish safely.")
    }

    func resumeQueue() {
        guard queuePhase == .paused
                || queuePhase == .pauseAfterCurrent
                || queuePhase == .stopAfterCurrent
        else { return }
        queuePhase = .running
        toasts.info("Queue resumed")
        scheduleQueueDriverIfNeeded()
    }

    func stopNow() {
        guard queuePhase != .idle else { return }
        queuePhase = .stopping

        if let attempt = activeAttemptID, activePipelineTask != nil {
            activeCancellation = .stop(attempt: attempt)
            activePipelineTask?.cancel()
            toasts.info(
                "Stopping now",
                detail: "The current depth pass may finish before partial output is cleaned up."
            )
        } else {
            queueDriverTask?.cancel()
            finishRun(announce: false)
            toasts.info("Queue stopped")
        }
    }

    func canSkip(_ conversion: Conversion) -> Bool {
        guard let context = runContext,
              context.admittedIDs.contains(conversion.id),
              !context.skippedIDs.contains(conversion.id)
        else { return false }
        return conversion.canMoveInQueue || conversion.status.isConverting
    }

    /// Skipping is scoped to this run. A waiting row stays ready for the next
    /// run; an active row cancels and cleans up before the driver advances.
    func skip(_ conversion: Conversion) {
        guard canSkip(conversion), var context = runContext else { return }
        context.skippedIDs.insert(conversion.id)
        runContext = context
        if priorityNoticeIDs.contains(conversion.id) { dismissPriorityNotice() }

        if conversion.status.isConverting,
           let attempt = activeAttemptID,
           activePipelineTask != nil {
            activeCancellation = .skip(attempt: attempt)
            activePipelineTask?.cancel()
            toasts.info("Skipping \(conversion.displayName)", detail: "Cleaning up its partial output.")
        } else {
            toasts.info("Skipped \(conversion.displayName)", detail: "It remains ready for the next run.")
            scheduleQueueDriverIfNeeded()
        }
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
                .appendingPathComponent("MakeIt3DSample.mov")
            do {
                let clip = try await SyntheticClip.generate(at: url)
                add(urls: [clip])
            } catch {
                toasts.failure("Couldn't make the sample clip", detail: error.localizedDescription)
            }
        }
    }

    private var isGeneratingSample = false

    /// Plain click: this row, and only this row.
    func select(_ conversion: Conversion) {
        selectedIDs = [conversion.id]
        selectionAnchorID = conversion.id
        focus(conversion)
    }

    // MARK: Preview

    /// Moves the playhead. Scrubbing re-runs the model, because the frame
    /// genuinely changed.
    func scrub(to seconds: Double) {
        playhead = max(0, seconds)
        // With a plan in hand the dials follow the playhead across cuts, so
        // the inspector is always describing the shot you are looking at
        // rather than the one you started on.
        if let selection { adoptShotSettings(at: playhead, for: selection) }
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
        guard !conversion.status.isConverting else { return }
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

    /// The first run nudge, once there is something on screen to look at.
    private func offerFirstLook() {
        onboarding.fileBecameReady(toasts: toasts) { [weak self] in
            guard let self else { return }
            self.previewMode = .wiggle
            // Under Reduce Motion the alternation stays off, so step to the
            // other eye instead. The comparison is the lesson either way.
            if self.preview.reduceMotion {
                self.preview.flipEye()
            } else {
                self.preview.isWigglePlaying = true
            }
        }
    }

    /// Generates the sample clip and walks the first run beats over it.
    func startGuidedTour() {
        onboarding.startTour()
        addSampleClip()
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
                conversion.failureKind = nil

                if conversion.id == self?.selectionID {
                    self?.refreshPreview(frameChanged: true)
                    self?.offerFirstLook()
                }

                if let image = try? await Ingest.image(
                    at: thumbnailTime, url: conversion.sourceURL, maxSize: 256
                ) {
                    conversion.thumbnail = image.value
                }
                self?.scheduleQueueDriverIfNeeded()
            } catch {
                conversion.status = .failed(error.localizedDescription)
                conversion.failureKind = .intake
                self?.recordFailureInCurrentRun(conversion.id)
                self?.scheduleQueueDriverIfNeeded()
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

    /// Converts everything that is ready, one at a time. Sequential on purpose:
    /// the model and the GPU are the bottleneck, so running two at once would
    /// make both slower and the progress meaningless.
    ///
    /// An all-ready run admits later additions explicitly. A selected run keeps
    /// its original scope unless the user deliberately prioritises another row.
    func convertAllReady() {
        startQueue(readyToConvert, scope: .allReadyIncludingAdditions)
    }

    /// The Convert button. Acts on the selection, and only the selection.
    ///
    /// It used to act on everything ready no matter what was highlighted, so
    /// selecting one video out of four produced a button reading "Convert 4
    /// videos". The label was honest about what the button did and the button
    /// was doing the wrong thing.
    func convertSelected() {
        guard !selectedReady.isEmpty else {
            toasts.info("Nothing selected is ready to convert")
            return
        }
        startQueue(selectedReady, scope: .selectedSnapshot)
    }

    /// Runs a finished row again, keeping the existing export. The user decides
    /// when they are done, not the button.
    func reconvert(_ conversion: Conversion) {
        guard queuePhase == .idle, conversion.status.isDone else { return }
        startQueue([conversion], scope: .retryGroup)
    }

    func canRetry(_ conversion: Conversion) -> Bool {
        guard case .failed = conversion.status else { return false }
        return queuePhase != .stopAfterCurrent && queuePhase != .stopping
    }

    func retry(_ conversion: Conversion) {
        guard canRetry(conversion) else { return }
        retry([conversion])
    }

    func retryAllFailed() {
        retry(failedConversions)
    }

    private func retry(_ failed: [Conversion]) {
        let ordered = conversions.filter { candidate in
            failed.contains(where: { $0.id == candidate.id }) && canRetry(candidate)
        }
        guard !ordered.isEmpty else { return }

        var needsProbe: [Conversion] = []
        for conversion in ordered {
            conversion.report = nil
            conversion.startedAt = nil
            let kind = conversion.failureKind ?? (conversion.probe == nil ? .intake : .conversion)
            conversion.failureKind = nil
            if kind == .intake || conversion.probe == nil {
                conversion.status = .probing
                needsProbe.append(conversion)
            } else {
                conversion.status = .ready
            }
        }

        if queuePhase == .idle {
            startQueue(ordered, scope: .retryGroup)
        } else {
            admitToCurrentRun(ordered.map(\.id))
            scheduleQueueDriverIfNeeded()
        }

        for conversion in needsProbe {
            probe(conversion)
            autoTune(conversion, announce: false)
        }

        toasts.info(
            ordered.count == 1 ? "Retrying \(ordered[0].displayName)" : "Retrying \(ordered.count) videos"
        )
    }

    /// Roughly what the export will occupy, from the encoder's own bitrate
    /// rule. Warning before an hour of work beats cleaning up after it.
    /// The output size, said before you commit rather than discovered after.
    static func estimatedSize(for probe: SourceProbe) -> String {
        let bitsPerPixel = 0.15
        let bitsPerSecond = Double(probe.width * probe.height) * probe.nominalFrameRate * bitsPerPixel
        let bytes = Int64(bitsPerSecond / 8 * probe.duration.seconds)
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func estimatedOutputBytes(for probe: SourceProbe) -> Int64 {
        let bitsPerPixel = 0.15
        let bitsPerSecond = Double(probe.width * probe.height) * probe.nominalFrameRate * bitsPerPixel
        return Int64(bitsPerSecond / 8 * probe.duration.seconds)
    }

    private static func addingWithoutOverflow(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
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
        let priorStatus = conversion.status
        let priorReport = conversion.report

        func restoreAfterUnsuccessfulAttempt(failed: Bool) {
            if case .done = priorStatus {
                conversion.status = priorStatus
                conversion.report = priorReport
            } else {
                conversion.status = failed
                    ? .failed("The conversion did not finish.")
                    : .ready
            }
        }

        guard let probe = conversion.probe else {
            if case .done = priorStatus {
                restoreAfterUnsuccessfulAttempt(failed: true)
            } else {
                conversion.status = .failed("The source file is not ready to convert.")
            }
            conversion.failureKind = .intake
            recordFailureInCurrentRun(conversion.id)
            return
        }
        guard hasRoom(for: probe) else {
            if case .done = priorStatus {
                restoreAfterUnsuccessfulAttempt(failed: true)
            } else {
                conversion.status = .failed("Not enough free space in \(outputFolder.lastPathComponent).")
            }
            conversion.failureKind = .conversion
            recordFailureInCurrentRun(conversion.id)
            return
        }
        guard confirmSlowModel(for: conversion, probe: probe) else { return }

        if systemFeedbackEnabled { SystemNotifier.prepare() }

        let request = ConversionRequest(
            probe: probe,
            tuning: conversion.tuning,
            outputURL: outputURL(for: conversion),
            shotPlan: conversion.shotPlan
        )
        let frozenTuning = conversion.tuning
        conversion.startedAt = Date()
        conversion.status = .converting(fraction: 0, framesDone: 0)
        conversion.report = nil
        conversion.failureKind = nil
        if priorityNoticeIDs.contains(conversion.id) { dismissPriorityNotice() }

        let attemptID = UUID()
        activeAttemptID = attemptID

        // The pipeline runs off the main actor. Events come back onto it, so
        // the UI only ever sees a consistent snapshot.
        let runner = conversionRunner
        let (stream, continuation) = AsyncStream<ConversionEvent>.makeStream()
        // This task is retained explicitly so Stop and Skip cancel the actual
        // engine work. The runner itself is nonisolated async work, so it leaves
        // the main actor while the UI continues consuming events here.
        let pipelineTask = Task {
            if Task.isCancelled {
                continuation.yield(.cancelled)
                continuation.finish()
                return
            }
            await runner(request) { event in
                continuation.yield(event)
            }
            continuation.finish()
        }
        activePipelineTask = pipelineTask

        var receivedTerminalEvent = false
        for await event in stream {
            guard activeAttemptID == attemptID else { continue }
            let cancellationRequested = activeCancellation?.attempt == attemptID

            switch event {
            case .started:
                if !cancellationRequested {
                    conversion.status = .converting(fraction: 0, framesDone: 0)
                }

            case .progress(let fraction, let framesDone):
                if !cancellationRequested {
                    conversion.status = .converting(fraction: fraction, framesDone: framesDone)
                    DockProgress.shared.fraction = queueProgress
                }

            case .finished(let report):
                receivedTerminalEvent = true
                if cancellationRequested {
                    try? FileManager.default.removeItem(at: report.outputURL)
                    restoreAfterUnsuccessfulAttempt(failed: false)
                    conversion.startedAt = nil
                    DockProgress.shared.fraction = nil
                    break
                }
                conversion.report = report
                conversion.exportedTuning = frozenTuning
                conversion.status = .done(outputURL: report.outputURL)
                conversion.startedAt = nil
                DockProgress.shared.fraction = nil
                recordCompletionInCurrentRun(conversion.id)
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
                if systemFeedbackEnabled {
                    SystemNotifier.post(
                        title: "\(conversion.displayName) is ready",
                        body: "Make It 3D finished converting it to spatial video."
                    )
                }

            case .failed(let message):
                receivedTerminalEvent = true
                if cancellationRequested {
                    restoreAfterUnsuccessfulAttempt(failed: false)
                } else if case .done = priorStatus {
                    restoreAfterUnsuccessfulAttempt(failed: true)
                } else {
                    conversion.status = .failed(message)
                }
                conversion.failureKind = cancellationRequested ? nil : .conversion
                conversion.startedAt = nil
                DockProgress.shared.fraction = nil
                if cancellationRequested { break }
                recordFailureInCurrentRun(conversion.id)
                toasts.failure("Couldn't convert \(conversion.displayName)", detail: message)
                if systemFeedbackEnabled {
                    SystemNotifier.post(
                        title: "Couldn't convert \(conversion.displayName)",
                        body: message
                    )
                    SystemNotifier.requestAttention()
                }

            case .cancelled:
                receivedTerminalEvent = true
                // New work returns to Ready. A re-export keeps its prior result.
                restoreAfterUnsuccessfulAttempt(failed: false)
                conversion.startedAt = nil
                DockProgress.shared.fraction = nil
            }
            if receivedTerminalEvent { break }
        }

        if let activePipelineTask { await activePipelineTask.value }
        if !receivedTerminalEvent, activeAttemptID == attemptID {
            if activeCancellation?.attempt == attemptID {
                restoreAfterUnsuccessfulAttempt(failed: false)
            } else {
                let message = "The conversion worker ended without finishing the file."
                if case .done = priorStatus {
                    restoreAfterUnsuccessfulAttempt(failed: true)
                } else {
                    conversion.status = .failed(message)
                }
                conversion.failureKind = .conversion
                recordFailureInCurrentRun(conversion.id)
                toasts.failure("Couldn't convert \(conversion.displayName)", detail: message)
            }
            conversion.startedAt = nil
            DockProgress.shared.fraction = nil
        }
        if activeAttemptID == attemptID {
            activePipelineTask = nil
            activeAttemptID = nil
            activeCancellation = nil
        }
    }

    func cancelConversion() {
        stopNow()
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
            .appendingPathComponent("MakeIt3DGoldenSet")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Movies/MakeIt3DGoldenSet")
    }

    /// Queues every clip in the golden set folder and converts the lot.
    func queueGoldenSet() {
        let folder = goldenSetFolder
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            toasts.info(
                "No golden set folder yet",
                detail: "Create MakeIt3DGoldenSet in your Movies folder and put the clips in it."
            )
            return
        }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []

        let videos = contents.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .video) || type.conforms(to: .video)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !videos.isEmpty else {
            toasts.info("The golden set folder is empty")
            return
        }

        writesGoldenSetReports = true
        add(urls: videos)
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
        alert.messageText = "Make It 3D is still converting \(active.displayName)."

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
