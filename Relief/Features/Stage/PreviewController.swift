import SwiftUI
import CoreMedia
import CoreGraphics
import Observation

/// Drives the stage: owns the preview engine, holds the current rendering, and
/// runs the wiggle alternation.
@Observable
@MainActor
final class PreviewController {

    /// What the stage draws right now.
    private(set) var displayed: CGImage?
    private(set) var errorMessage: String?

    /// True only while the depth model is running on a new frame. Parameter
    /// changes do not set this, because they do not run the model.
    private(set) var isReadingDepth = false

    /// The disparity present in the visible frame, in pixels. Published from
    /// here rather than queried by the inspector, so the number on screen is
    /// always the one that produced the image next to it.
    private(set) var disparityNear: Float = 0
    private(set) var disparityFar: Float = 0

    var isWigglePlaying = true {
        didSet { restartWiggle() }
    }

    private let engine = PreviewEngine()
    private var pair: PreviewImage?
    private var showingLeft = true

    private var renderTask: Task<Void, Never>?
    private var wiggleTask: Task<Void, Never>?

    private var currentMode: PreviewMode = .source

    // MARK: Updating

    /// Refreshes the stage. `frameChanged` tells the controller whether the
    /// model has to run again, which is the difference between a scrub and a
    /// slider drag.
    func update(
        url: URL,
        time: CMTime,
        mode: PreviewMode,
        tuning: EngineTuning,
        frameChanged: Bool
    ) {
        renderTask?.cancel()
        currentMode = mode

        renderTask = Task { [weak self] in
            guard let self else { return }
            if frameChanged { self.isReadingDepth = true }
            defer { self.isReadingDepth = false }

            do {
                try await self.engine.prepare(url: url, time: time, tuning: tuning)
                guard !Task.isCancelled else { return }

                let image = try await self.engine.render(mode: mode, tuning: tuning)
                guard !Task.isCancelled else { return }

                self.pair = image
                self.showingLeft = true
                self.displayed = image.left
                self.errorMessage = nil

                if let range = await self.engine.disparityRange(tuning: tuning) {
                    self.disparityNear = range.near
                    self.disparityFar = range.far
                }
                self.restartWiggle()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.displayed = nil
            }
        }
    }

    func clear() {
        renderTask?.cancel()
        wiggleTask?.cancel()
        renderTask = nil
        wiggleTask = nil
        displayed = nil
        pair = nil
        errorMessage = nil
        Task { await engine.invalidate() }
    }

    /// The disparity present in the visible frame, for the inspector readout.
    func disparityRange(tuning: EngineTuning) async -> (near: Float, far: Float)? {
        await engine.disparityRange(tuning: tuning)
    }

    // MARK: Wiggle

    /// Hard cut alternation between the two synthesized eyes. No crossfade:
    /// a crossfade averages the two views and kills the effect the mode exists
    /// for.
    private func restartWiggle() {
        wiggleTask?.cancel()
        wiggleTask = nil

        guard currentMode == .wiggle, let pair, pair.isPair, isWigglePlaying else {
            if let pair, currentMode == .wiggle, !isWigglePlaying {
                displayed = showingLeft ? pair.left : (pair.right ?? pair.left)
            }
            return
        }

        let interval = UInt64(Tokens.Motion.wiggleInterval * 1_000_000_000)
        wiggleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard let self, !Task.isCancelled else { return }
                guard let pair = self.pair, let right = pair.right else { return }
                self.showingLeft.toggle()
                self.displayed = self.showingLeft ? pair.left : right
            }
        }
    }
}
