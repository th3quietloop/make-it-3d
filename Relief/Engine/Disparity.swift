import Foundation
import Accelerate

/// Maps nearness to horizontal disparity in pixels.
///
/// The equation is d = S * W * (nearness - C):
///   S is strength as a fraction of frame width (Soft 0.010, Standard 0.016,
///     Deep 0.024, or a custom percentage from the inspector)
///   W is frame width in pixels
///   C is convergence, the nearness value that lands exactly on the screen
///     plane and therefore gets zero disparity
///
/// Positive d is content in front of the screen plane. Forward pop is the
/// expensive direction for the eyes, so positive disparity is halved after the
/// mapping while negative disparity (depth behind the screen, which is
/// comfortable) is left alone.
enum Disparity {

    /// Disparity in pixels for every pixel of the frame.
    struct Field: @unchecked Sendable {
        let values: [Float]
        let width: Int
        let height: Int

        /// The largest forward pop in the field, in pixels. The inspector shows
        /// this so the number driving comfort is never hidden.
        let maxPositive: Float
        /// The largest push behind the screen plane, in pixels.
        let maxNegative: Float
    }

    /// Builds the disparity field from a stabilized nearness map.
    ///
    /// `frameWidth` is the width of the frame being synthesized, which is not
    /// necessarily the width of the nearness map: the model works at its own
    /// resolution and the field is expressed in the frame's pixel units so the
    /// warp can consume it directly.
    static func field(
        from nearness: NearnessMap,
        frameWidth: Int,
        tuning: EngineTuning
    ) -> Field {
        let count = nearness.values.count
        var values = [Float](repeating: 0, count: count)

        let gain = Float(tuning.disparityScale * Double(frameWidth))
        let convergence = Float(tuning.convergence)

        // d = S * W * (nearness - C). Positive always means in front of the
        // screen plane here, and it stays that way: the eye mapping convention
        // is applied at synthesis, not folded into the magnitude.
        //
        // Folding it in here was a real bug. Negating the gain silently swapped
        // which half of the field counted as "in front", so the comfort scaling
        // below was applied to content behind the screen, the depth ramp drew
        // near and far the wrong way round, and the inspector readouts were
        // reversed. The rendered stereo still looked right, which is exactly
        // why it survived the sign check.
        //
        // Written as one pass over a separate output array rather than two
        // aliased vDSP calls, so there is no reading and writing of the same
        // buffer in a single operation.
        nearness.values.withUnsafeBufferPointer { input in
            values.withUnsafeMutableBufferPointer { output in
                for index in 0..<count {
                    output[index] = (input[index] - convergence) * gain
                }
            }
        }

        // Scale forward pop only. Content behind the screen plane keeps its
        // full disparity because it is the comfortable direction.
        let forwardScale = Float(tuning.forwardPopScale)
        for index in 0..<count where values[index] > 0 {
            values[index] *= forwardScale
        }

        var maxPositive: Float = 0
        var maxNegative: Float = 0
        vDSP_maxv(values, 1, &maxPositive, vDSP_Length(count))
        vDSP_minv(values, 1, &maxNegative, vDSP_Length(count))

        return Field(
            values: values,
            width: nearness.width,
            height: nearness.height,
            maxPositive: max(maxPositive, 0),
            maxNegative: min(maxNegative, 0)
        )
    }

    enum Eye: Sendable {
        case left
        case right

        /// The multiplier applied to d when sampling for this eye.
        ///
        /// Symmetric splits the shift so neither eye carries all of it and the
        /// fused image stays centred on the original framing. Left eye
        /// untouched gives the left eye a factor of zero, which means it is
        /// literally the source frame, and hands the whole shift to the right.
        /// The fused image sits half a disparity off the original framing,
        /// which nobody can see, in exchange for one eye that is provably
        /// perfect.
        func sampleFactor(for synthesis: EngineTuning.Synthesis) -> Float {
            switch synthesis {
            case .symmetric:
                return self == .left ? 0.5 : -0.5
            case .leftEyeUntouched:
                return self == .left ? 0 : -1.0
            }
        }
    }
}
