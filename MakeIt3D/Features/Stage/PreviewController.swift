import SwiftUI
import AppKit
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

    /// True on the very first run, when Core ML still has to load the model
    /// onto the Neural Engine. That takes seconds, and a stage that just says
    /// "Reading depth" with no movement for that long reads as a hang.
    private(set) var isWarmingUp = false

    /// How much depth the visible frame has. Published from here rather than
    /// queried by the inspector, so the verdict on screen always belongs to the
    /// image next to it.
    private(set) var reading: DepthReading?

    /// Wiggle starts paused, always.
    ///
    /// Entering the mode used to begin a 6Hz hard cut flash unprompted, which
    /// is squarely in vestibular trigger territory. The first alternation is
    /// now a choice, and under Reduce Motion the mode stays a still comparison
    /// the user steps through by hand.
    var isWigglePlaying = false {
        didSet { restartWiggle() }
    }

    var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Which eye the stage is parked on while the wiggle is paused.
    private(set) var showingLeft = true

    private let engine = PreviewEngine()
    private var pair: PreviewImage?

    private var renderTask: Task<Void, Never>?
    private var wiggleTask: Task<Void, Never>?

    private var currentMode: PreviewMode = .source
    private var hasLoadedModelOnce = false

    /// Smoothing for the depth verdict. The raw value moves frame to frame
    /// because normalization is per frame, and a verdict that flickers between
    /// two words as you scrub reads as a broken instrument.
    private var smoothedLoadForward: Float = 0
    private var smoothedLoadBehind: Float = 0
    private var hasSmoothingHistory = false
    private let smoothingAlpha: Float = 0.35

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
        let modeChanged = currentMode != mode
        currentMode = mode

        // A new frame invalidates the smoothing history; a parameter change
        // does not, because it is the same picture with a different number.
        if frameChanged { hasSmoothingHistory = false }
        if modeChanged { isWigglePlaying = false }

        renderTask = Task { [weak self] in
            guard let self else { return }
            if frameChanged {
                self.isReadingDepth = true
                if !self.hasLoadedModelOnce { self.isWarmingUp = true }
            }
            defer {
                self.isReadingDepth = false
                self.isWarmingUp = false
            }

            do {
                // Two passes while the playhead is moving. The first lands on
                // the nearest sync sample, which is what keeps a drag feeling
                // attached to the pointer on a long GOP file. The second is the
                // exact frame, and only ever runs once the user stops moving,
                // because the next update cancels this task before it gets
                // there.
                if frameChanged {
                    try await self.render(url: url, time: time, mode: mode, tuning: tuning, precise: false)
                    guard !Task.isCancelled else { return }
                    try await Task.sleep(for: .seconds(Tokens.Motion.scrubSettle))
                    guard !Task.isCancelled else { return }
                }

                try await self.render(url: url, time: time, mode: mode, tuning: tuning, precise: true)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.displayed = nil
                self.reading = nil
            }
        }
    }

    /// One pass: decode, run the model if the frame moved, render, publish.
    private func render(
        url: URL,
        time: CMTime,
        mode: PreviewMode,
        tuning: EngineTuning,
        precise: Bool
    ) async throws {
        try await engine.prepare(url: url, time: time, tuning: tuning, precise: precise)
        guard !Task.isCancelled else { return }
        hasLoadedModelOnce = true

        let image = try await engine.render(mode: mode, tuning: tuning)
        guard !Task.isCancelled else { return }

        pair = image
        showingLeft = true
        displayed = image.left
        errorMessage = nil

        if let range = await engine.disparityRange(tuning: tuning),
           let width = await engine.frameWidth {
            updateReading(forward: range.near, behind: range.far, frameWidth: width)
        }
        restartWiggle()
    }

    private func updateReading(forward: Float, behind: Float, frameWidth: Int) {
        if hasSmoothingHistory {
            smoothedLoadForward += (forward - smoothedLoadForward) * smoothingAlpha
            smoothedLoadBehind += (behind - smoothedLoadBehind) * smoothingAlpha
        } else {
            smoothedLoadForward = forward
            smoothedLoadBehind = behind
            hasSmoothingHistory = true
        }
        reading = DepthReading(
            forward: smoothedLoadForward,
            behind: smoothedLoadBehind,
            frameWidth: frameWidth
        )
    }

    func clear() {
        renderTask?.cancel()
        wiggleTask?.cancel()
        renderTask = nil
        wiggleTask = nil
        displayed = nil
        pair = nil
        errorMessage = nil
        reading = nil
        hasSmoothingHistory = false
        Task { await engine.invalidate() }
    }

    // MARK: Wiggle

    /// Shows the other eye. Under Reduce Motion this is how the mode is used:
    /// a still comparison the user steps through, rather than a flash.
    func flipEye() {
        guard let pair, let right = pair.right else { return }
        showingLeft.toggle()
        displayed = showingLeft ? pair.left : right
    }

    /// Hard cut alternation between the two synthesized eyes. No crossfade:
    /// a crossfade averages the two views and kills the effect the mode exists
    /// for.
    private func restartWiggle() {
        wiggleTask?.cancel()
        wiggleTask = nil

        guard currentMode == .wiggle, let pair, pair.isPair, isWigglePlaying, !reduceMotion else {
            if let pair, currentMode == .wiggle {
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
