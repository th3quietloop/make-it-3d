import Foundation

/// What the depth model actually saw, measured before normalization throws it
/// away.
///
/// This exists because the depth gauge was measuring the wrong thing. The
/// pipeline normalizes every frame to a full 0...1 nearness range, so by the
/// time disparity is computed the nearest pixel is always 1 and the farthest is
/// always 0, on every frame of every film. Disparity is then a function of the
/// strength and convergence settings and nothing else, which meant the gauge
/// reported one of three fixed verdicts, one per preset, no matter what was on
/// screen. A shot of a face and a shot of a mountain range read identically.
///
/// The information normalization destroys is the raw spread, and that is
/// exactly the information needed to answer "does this shot have real depth in
/// it, or is the model amplifying noise on a flat wall".
struct DepthContent: Equatable, Sendable {

    /// The low and high percentile of the raw model output, before rescaling.
    let low: Float
    let high: Float
    /// The middle of the raw distribution.
    let median: Float
    /// Fraction of the frame sitting in the nearer half of the raw range. A
    /// close up has a large near mass; a landscape has almost none.
    let nearMass: Double

    /// How much real depth this frame contains, on a scale that does not care
    /// what units the model chose.
    ///
    /// The model emits relative inverse depth on an arbitrary per frame scale,
    /// so an absolute range is meaningless across shots. Dividing the spread by
    /// the median cancels the scale: a wall photographed from three metres and
    /// the same wall from thirty both give a spread near zero, while a face at
    /// one metre against a background at twenty gives a large one.
    var spread: Double {
        guard median > 1e-5 else { return 0 }
        return Double((high - low) / median)
    }

    /// How much of the depth in this frame is real rather than stretched noise,
    /// from 0 to 1.
    ///
    /// Normalization always produces a full range picture, so a genuinely flat
    /// shot comes out looking as three dimensional as a canyon and then reads
    /// as wobbling cardboard in the headset. This is the multiplier that stops
    /// the auto tuner pushing a flat shot as hard as a deep one.
    ///
    /// The thresholds are measured, not guessed. See DepthContentCheck.
    /// Calibrated against real footage with `MakeIt3D --analyse`, not guessed.
    ///
    /// The first version of this used a linear ramp from 0.15 to 1.10, chosen
    /// by intuition. Measured on actual clips the spread runs from about 0.8 on
    /// a flat handheld walk to 6.3 on a shot with a face close to the lens, so
    /// every real shot saturated at full confidence and the tuner handed out an
    /// identical strength to all of them. The analyser printed "the measurement
    /// is not discriminating" and it was right.
    ///
    /// Log scaled because this is a ratio of a spread to a median, and ratios
    /// spread over an order of magnitude do not belong on a linear ramp.
    var confidence: Double {
        guard spread > 0 else { return 0 }
        let floorSpread = 0.25
        let fullSpread = 4.0
        let t = (log(spread) - log(floorSpread)) / (log(fullSpread) - log(floorSpread))
        return min(max(t, 0), 1)
    }

    /// Nothing measured yet.
    static let unknown = DepthContent(low: 0, high: 0, median: 0, nearMass: 0)

    var isMeasured: Bool { high > low }

    /// Averages a run of frames into one reading for a shot. Depth in a single
    /// frame is noisy; a shot is the unit people actually tune.
    static func averaging(_ samples: [DepthContent]) -> DepthContent {
        let measured = samples.filter(\.isMeasured)
        guard !measured.isEmpty else { return .unknown }
        let count = Float(measured.count)
        return DepthContent(
            low: measured.reduce(0) { $0 + $1.low } / count,
            high: measured.reduce(0) { $0 + $1.high } / count,
            median: measured.reduce(0) { $0 + $1.median } / count,
            nearMass: measured.reduce(0) { $0 + $1.nearMass } / Double(measured.count)
        )
    }
}
