import Foundation
import Accelerate

/// Turns the model's raw per frame output into a nearness signal that holds
/// still across a shot.
///
/// Three jobs, in order:
/// 1. Normalize each frame to 0...1 against its own 2nd and 98th percentiles,
///    so a frame with one very bright outlier does not crush the useful range.
/// 2. Smooth across frames with an exponential moving average, which is what
///    stops the depth from pumping and breathing.
/// 3. Notice scene cuts and reset rather than smear depth across the cut.
final class Stabilizer {

    private let tuning: EngineTuning
    private var previous: [Float]?

    /// Set when the last frame processed was judged a scene cut. The debug
    /// report reads this to show cut handling is working.
    private(set) var lastFrameWasSceneCut = false
    private(set) var sceneCutCount = 0

    /// What the raw model output looked like for the most recent frame, before
    /// normalization flattened every shot into the same 0...1 range. Read by
    /// the gauge and by the auto tuner, both of which are worthless without it.
    private(set) var lastContent: DepthContent = .unknown

    init(tuning: EngineTuning) {
        self.tuning = tuning
    }

    /// Clears history. Called when the pipeline seeks or restarts, so the first
    /// frame after a jump is never blended with a frame from somewhere else.
    func reset() {
        previous = nil
        lastFrameWasSceneCut = false
    }

    /// Percentile clamp and rescale to 0...1, with no temporal component.
    ///
    /// Exposed separately because the preview needs exactly this and nothing
    /// more. The model emits inverse depth on an arbitrary scale, so comparing
    /// it against the convergence point before normalizing is meaningless: the
    /// whole frame lands on one side of the screen plane and the depth map
    /// reads as flat. The preview skips the smoothing, not the normalization.
    func normalize(_ map: NearnessMap) -> NearnessMap {
        NearnessMap(values: normalized(map.values), width: map.width, height: map.height)
    }

    func stabilize(_ map: NearnessMap) -> NearnessMap {
        var values = normalized(map.values)

        if let previous, previous.count == values.count {
            let delta = meanAbsoluteDifference(values, previous)
            if delta > Float(tuning.sceneCutThreshold) {
                // A cut. Take the new frame whole rather than blending it with
                // a shot that no longer exists.
                lastFrameWasSceneCut = true
                sceneCutCount += 1
            } else {
                lastFrameWasSceneCut = false
                let alpha = Float(tuning.temporalAlpha)
                // values = alpha * current + (1 - alpha) * previous
                var a = alpha
                var b = 1 - alpha
                var blended = [Float](repeating: 0, count: values.count)
                vDSP_vsmsma(values, 1, &a, previous, 1, &b, &blended, 1, vDSP_Length(values.count))
                values = blended
            }
        } else {
            lastFrameWasSceneCut = false
        }

        previous = values
        return NearnessMap(values: values, width: map.width, height: map.height)
    }

    // MARK: Normalization

    /// Clamps to the configured percentiles, then scales to 0...1.
    ///
    /// The raw statistics are captured on the way through, because this is the
    /// only place they exist. Everything downstream sees a full range frame.
    private func normalized(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return input }

        let (low, high) = percentiles(input)
        let range = high - low
        lastContent = measure(input, low: low, high: high)

        guard range > 1e-6 else {
            // A flat frame. Everything sits on the screen plane rather than
            // amplifying noise into fake depth.
            return [Float](repeating: 0.5, count: input.count)
        }

        var output = [Float](repeating: 0, count: input.count)
        var negativeLow = -low
        vDSP_vsadd(input, 1, &negativeLow, &output, 1, vDSP_Length(input.count))
        var scale = 1 / range
        vDSP_vsmul(output, 1, &scale, &output, 1, vDSP_Length(output.count))

        var minimum: Float = 0
        var maximum: Float = 1
        vDSP_vclip(output, 1, &minimum, &maximum, &output, 1, vDSP_Length(output.count))

        return output
    }

    /// The raw distribution, described.
    ///
    /// Median by histogram for the same reason the percentiles are: this runs
    /// on every frame of every conversion and a sort of two million floats is
    /// not free.
    private func measure(_ input: [Float], low: Float, high: Float) -> DepthContent {
        var minimum: Float = 0
        var maximum: Float = 0
        vDSP_minv(input, 1, &minimum, vDSP_Length(input.count))
        vDSP_maxv(input, 1, &maximum, vDSP_Length(input.count))
        guard maximum > minimum else {
            return DepthContent(low: low, high: high, median: minimum, nearMass: 0)
        }

        let binCount = 1024
        var histogram = [Int](repeating: 0, count: binCount)
        let scale = Float(binCount - 1) / (maximum - minimum)
        for value in input {
            histogram[min(max(Int((value - minimum) * scale), 0), binCount - 1)] += 1
        }

        let half = input.count / 2
        // Everything above the midpoint of the clamped range counts as near.
        let midpoint = (low + high) / 2
        let midBin = min(max(Int((midpoint - minimum) * scale), 0), binCount - 1)

        var running = 0
        var medianBin = 0
        var foundMedian = false
        var nearCount = 0
        for bin in 0..<binCount {
            running += histogram[bin]
            if !foundMedian, running >= half {
                medianBin = bin
                foundMedian = true
            }
            if bin > midBin { nearCount += histogram[bin] }
        }

        let binWidth = (maximum - minimum) / Float(binCount - 1)
        return DepthContent(
            low: low,
            high: high,
            median: minimum + Float(medianBin) * binWidth,
            nearMass: Double(nearCount) / Double(input.count)
        )
    }

    /// Percentiles by histogram rather than a full sort. At 1080p that is the
    /// difference between microseconds and milliseconds per frame, and the
    /// pipeline runs this on every frame.
    private func percentiles(_ input: [Float]) -> (low: Float, high: Float) {
        var minimum: Float = 0
        var maximum: Float = 0
        vDSP_minv(input, 1, &minimum, vDSP_Length(input.count))
        vDSP_maxv(input, 1, &maximum, vDSP_Length(input.count))

        guard maximum > minimum else { return (minimum, maximum) }

        let binCount = 1024
        var histogram = [Int](repeating: 0, count: binCount)
        let scale = Float(binCount - 1) / (maximum - minimum)

        for value in input {
            let bin = Int((value - minimum) * scale)
            histogram[min(max(bin, 0), binCount - 1)] += 1
        }

        let total = input.count
        let lowTarget = Int(Double(total) * tuning.lowPercentile)
        let highTarget = Int(Double(total) * tuning.highPercentile)

        var running = 0
        var lowBin = 0
        var highBin = binCount - 1
        var foundLow = false

        for bin in 0..<binCount {
            running += histogram[bin]
            if !foundLow, running >= lowTarget {
                lowBin = bin
                foundLow = true
            }
            if running >= highTarget {
                highBin = bin
                break
            }
        }

        let binWidth = (maximum - minimum) / Float(binCount - 1)
        return (minimum + Float(lowBin) * binWidth, minimum + Float(highBin) * binWidth)
    }

    private func meanAbsoluteDifference(_ a: [Float], _ b: [Float]) -> Float {
        var difference = [Float](repeating: 0, count: a.count)
        vDSP_vsub(b, 1, a, 1, &difference, 1, vDSP_Length(a.count))
        var mean: Float = 0
        vDSP_meamgv(difference, 1, &mean, vDSP_Length(difference.count))
        return mean
    }
}
