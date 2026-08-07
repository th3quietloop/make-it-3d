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

        let scale = Float(tuning.disparityScale * Double(frameWidth))
        let convergence = Float(tuning.convergence)
        let sign: Float = tuning.invertDisparitySign ? -1 : 1

        // d = S * W * (nearness - C), then flip if the sign convention check
        // said to. Written as one pass over a separate output array rather than
        // two aliased vDSP calls, so there is no reading and writing of the
        // same buffer in a single operation.
        let gain = scale * sign
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

    /// Synthesis is symmetric: the left eye samples at x + d/2 and the right
    /// eye at x - d/2, so neither eye carries the whole shift and the fused
    /// image stays centred on the original framing.
    enum Eye: Sendable {
        case left
        case right

        /// The multiplier applied to d when sampling for this eye.
        var sampleFactor: Float {
            switch self {
            case .left: return 0.5
            case .right: return -0.5
            }
        }
    }
}
