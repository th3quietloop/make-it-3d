import SwiftUI
import AppKit
import CoreMedia
import CoreGraphics
import Observation

enum PreviewComparison: String, CaseIterable, Identifiable {
    case draft, automatic, original
    var id: String { rawValue }
    var label: String {
        switch self {
        case .draft: "Your settings"
        case .automatic: "Automatic"
        case .original: "Original"
        }
    }
}

/// A single inspection request owns the image, its settings and its measurement.
@Observable
@MainActor
final class PreviewController {
    private(set) var displayed: CGImage?
    private(set) var errorMessage: String?
    private(set) var isReadingDepth = false
    private(set) var isWarmingUp = false
    private(set) var isRendering = false
    private(set) var displayedSeconds: Double?
    private(set) var isExactPreview = false
    private(set) var reading: DepthReading?
    private(set) var showingLeft = true
    private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var comparison: PreviewComparison = .draft {
        didSet { if comparison != oldValue { rerender() } }
    }
    /// Native-size inspection requests the source's actual pixel dimensions.
    /// Scaling a 720p preview up is not a 100% inspection of a 4K export.
    var inspectionAtNativeSize = false {
        didSet { if inspectionAtNativeSize != oldValue { rerender() } }
    }
    var showReconstructionRisk = false {
        didSet { if showReconstructionRisk != oldValue { rerender() } }
    }
    var isWigglePlaying = false {
        didSet {
            if isWigglePlaying && reduceMotion { isWigglePlaying = false }
            restartWiggle()
        }
    }

    private struct Request {
        let url: URL
        let time: CMTime
        let mode: PreviewMode
        let tuning: EngineTuning
        let automaticTuning: EngineTuning?
    }
    private var engine = PreviewEngine()
    private var pair: PreviewImage?
    private var lastRequest: Request?
    private var renderTask: Task<Void, Never>?
    private var wiggleTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var hasLoadedModelOnce = false
    @ObservationIgnored private var accessibilityObserver: PreviewNotificationObservation?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                if self.reduceMotion { self.isWigglePlaying = false }
            }
        }
        accessibilityObserver = PreviewNotificationObservation(center: center, token: token)
    }

    func update(
        url: URL, time: CMTime, mode: PreviewMode, tuning: EngineTuning,
        frameChanged: Bool, automaticTuning: EngineTuning? = nil
    ) {
        let sourceChanged = lastRequest?.url != url
        let modeChanged = lastRequest?.mode != mode
        if sourceChanged || modeChanged {
            isWigglePlaying = false
            showingLeft = true
        }
        if sourceChanged {
            displayed = nil
            displayedSeconds = nil
            reading = nil
            pair = nil
        }
        let request = Request(url: url, time: time, mode: mode, tuning: tuning, automaticTuning: automaticTuning)
        lastRequest = request
        start(request, frameChanged: frameChanged)
    }

    private func rerender() {
        guard let lastRequest else { return }
        start(lastRequest, frameChanged: false)
    }

    private func start(_ request: Request, frameChanged: Bool) {
        renderTask?.cancel()
        generation &+= 1
        let thisGeneration = generation
        let mode: PreviewMode = comparison == .original ? .source : request.mode
        let tuning = comparison == .automatic ? (request.automaticTuning ?? request.tuning) : request.tuning
        let fullResolution = inspectionAtNativeSize
        let risk = showReconstructionRisk && comparison != .original
        let needsDepth = mode != .source || risk
        let engine = self.engine
        isRendering = true
        isExactPreview = false
        isReadingDepth = needsDepth
        isWarmingUp = needsDepth && !hasLoadedModelOnce
        errorMessage = nil
        renderTask = Task { [weak self] in
            guard let self else { return }
            defer {
                // A cancelled older seek must not hide the new seek's spinner.
                if self.generation == thisGeneration {
                    self.isRendering = false
                    self.isReadingDepth = false
                    self.isWarmingUp = false
                }
            }
            do {
                if frameChanged && !fullResolution {
                    let first = try await engine.makePreview(
                        url: request.url, time: request.time, mode: mode, tuning: tuning,
                        precise: false, fullResolution: false, reconstructionRisk: risk
                    )
                    try Task.checkCancellation()
                    guard self.generation == thisGeneration else { return }
                    self.publish(first, needsDepth: needsDepth)
                    try await Task.sleep(for: .seconds(Tokens.Motion.scrubSettle))
                }
                let final = try await engine.makePreview(
                    url: request.url, time: request.time, mode: mode, tuning: tuning,
                    precise: true, fullResolution: fullResolution, reconstructionRisk: risk
                )
                try Task.checkCancellation()
                guard self.generation == thisGeneration else { return }
                self.publish(final, needsDepth: needsDepth)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.generation == thisGeneration else { return }
                self.errorMessage = error.localizedDescription
                self.reading = nil
                // Keep a previous image visible with an explicit error, rather
                // than replacing a useful picture with an empty black stage.
                self.isExactPreview = false
            }
        }
    }

    private func publish(_ result: PreviewRender, needsDepth: Bool) {
        pair = result.image
        displayed = showingLeft ? result.image.left : (result.image.right ?? result.image.left)
        displayedSeconds = result.actualSeconds
        isExactPreview = result.isPrecise
        errorMessage = nil
        if needsDepth { hasLoadedModelOnce = true }
        if let disparity = result.disparity {
            reading = DepthReading(
                forward: disparity.near, behind: disparity.far,
                frameWidth: result.frameWidth, content: result.content
            )
        } else {
            reading = nil
        }
        restartWiggle()
    }

    func clear() {
        generation &+= 1
        renderTask?.cancel()
        wiggleTask?.cancel()
        renderTask = nil
        wiggleTask = nil
        lastRequest = nil
        displayed = nil
        displayedSeconds = nil
        pair = nil
        errorMessage = nil
        reading = nil
        isReadingDepth = false
        isWarmingUp = false
        isRendering = false
        isExactPreview = false
        isWigglePlaying = false
        let retiredEngine = engine
        engine = PreviewEngine()
        hasLoadedModelOnce = false
        Task { await retiredEngine.invalidate() }
    }

    func flipEye() {
        guard let pair, let right = pair.right else { return }
        showingLeft.toggle()
        displayed = showingLeft ? pair.left : right
    }

    func showEye(left: Bool) {
        guard showingLeft != left else { return }
        flipEye()
    }

    private func restartWiggle() {
        wiggleTask?.cancel()
        wiggleTask = nil
        guard lastRequest?.mode == .wiggle, comparison != .original,
              let pair, pair.isPair, isWigglePlaying, !reduceMotion else { return }
        wiggleTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(Tokens.Motion.wiggleInterval)) }
                catch { return }
                guard let self, !Task.isCancelled else { return }
                guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                    self.reduceMotion = true
                    self.isWigglePlaying = false
                    return
                }
                self.flipEye()
            }
        }
    }
}
