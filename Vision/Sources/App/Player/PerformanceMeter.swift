import Foundation
import Metal
import QuartzCore

/// Measures what the app is actually doing, so the answer to "does it hold 90"
/// is a number rather than a feeling.
///
/// Two things are measured and they are not the same thing.
///
/// The display rate is how often RealityKit asks for a frame. On a headset that
/// should be 90, and if it drops the compositor is the thing that noticed.
///
/// The warp cost is how long the GPU spends synthesizing one stereo pair,
/// taken from the command buffer's own start and end times rather than from a
/// wall clock around the commit, because the commit returns long before the GPU
/// is finished and timing it measures nothing.
///
/// The warp runs at video rate, not display rate. At 24 fps a pair has 41.7 ms
/// of budget, and the interesting question is what fraction of that it uses.
///
/// Lock protected and unchecked Sendable because Metal completion handlers run
/// on whatever thread finished the work, and the UI reads it on the main actor.
final class PerformanceMeter: @unchecked Sendable {

    struct Reading: Sendable, Equatable {
        var displayFramesPerSecond: Double = 0
        /// The longest gap between display frames in the window, in
        /// milliseconds. One long frame is what a hitch is, and an average
        /// hides it.
        var worstDisplayFrameMilliseconds: Double = 0
        var meanWarpMilliseconds: Double = 0
        var worstWarpMilliseconds: Double = 0
        var warpsMeasured: Int = 0
        /// How many stereo pairs were synthesized in the window.
        var warpsPerSecond: Double = 0

        var isEmpty: Bool { displayFramesPerSecond == 0 && warpsMeasured == 0 }
    }

    private let lock = NSLock()
    private let window: Double = 1.0

    private var lastDisplayTimestamp: CFTimeInterval?
    private var windowStart = CACurrentMediaTime()
    private var displayFrames = 0
    private var worstDisplayGap = 0.0

    private var warpCount = 0
    private var warpTotal = 0.0
    private var warpWorst = 0.0

    private var published = Reading()

    /// Called once per display frame, on the main actor.
    func recordDisplayFrame() {
        lock.lock()
        defer { lock.unlock() }

        let now = CACurrentMediaTime()
        if let last = lastDisplayTimestamp {
            worstDisplayGap = max(worstDisplayGap, (now - last) * 1000)
        }
        lastDisplayTimestamp = now
        displayFrames += 1

        let elapsed = now - windowStart
        guard elapsed >= window else { return }

        published = Reading(
            displayFramesPerSecond: Double(displayFrames) / elapsed,
            worstDisplayFrameMilliseconds: worstDisplayGap,
            meanWarpMilliseconds: warpCount > 0 ? warpTotal / Double(warpCount) : 0,
            worstWarpMilliseconds: warpWorst,
            warpsMeasured: warpCount,
            warpsPerSecond: Double(warpCount) / elapsed
        )

        windowStart = now
        displayFrames = 0
        worstDisplayGap = 0
        warpCount = 0
        warpTotal = 0
        warpWorst = 0
    }

    /// Attaches to a command buffer so the GPU reports its own timing.
    func measure(_ commandBuffer: MTLCommandBuffer) {
        commandBuffer.addCompletedHandler { [weak self] buffer in
            guard let self else { return }
            let milliseconds = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            guard milliseconds.isFinite, milliseconds >= 0 else { return }
            self.lock.lock()
            self.warpCount += 1
            self.warpTotal += milliseconds
            self.warpWorst = max(self.warpWorst, milliseconds)
            self.lock.unlock()
        }
    }

    var reading: Reading {
        lock.lock()
        defer { lock.unlock() }
        return published
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastDisplayTimestamp = nil
        windowStart = CACurrentMediaTime()
        displayFrames = 0
        worstDisplayGap = 0
        warpCount = 0
        warpTotal = 0
        warpWorst = 0
        published = Reading()
    }
}
