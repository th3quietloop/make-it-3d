import Foundation

/// Every number the stereo synthesis uses.
///
/// The values are the Mac engine's, carried across unchanged, because the two
/// apps have to agree about what a given strength looks like. S and C mean
/// exactly what `MakeIt3D/Engine/EngineTuning.swift` says they mean:
///
///   d = S * W * (nearness - C)
///
/// S is strength as a fraction of frame width. C is convergence, the nearness
/// that lands on the screen plane and therefore gets zero disparity. Positive d
/// is content in front of the screen plane.
///
/// The difference here is that S and C move while the film is playing. That is
/// the entire product, so they live in their own struct and everything reads
/// them fresh every frame rather than baking them into anything.
struct StereoTuning: Sendable, Equatable {

    // MARK: The dial

    /// S, as a fraction of frame width.
    var strength: Double = 0.016

    /// C, the nearness that maps to zero disparity.
    var convergence: Double = 0.45

    /// What the dial can reach.
    ///
    /// The floor is zero rather than the Mac's softest preset, because "off" is
    /// a real answer to "is this too much" and the only way to compare against
    /// flat is to be able to get there. The ceiling is half again the Mac's
    /// Deep preset: past that the picture stops being watchable, and a dial
    /// that goes somewhere useless wastes the part of its travel that matters.
    static let strengthRange = 0.0...0.036
    static let convergenceRange = 0.05...0.95

    /// The Mac's three presets, so a number here means the same thing there.
    static let softStrength = 0.010
    static let standardStrength = 0.016
    static let deepStrength = 0.024

    // MARK: Comfort

    /// Positive disparity is content in front of the screen plane. It is scaled
    /// down so forward pop stays inside the comfort budget.
    var forwardPopScale: Double = 0.5

    // MARK: Synthesis

    /// How the two eye views are produced.
    enum Synthesis: String, Sendable, CaseIterable, Identifiable {
        /// Both eyes warped by half the disparity each.
        case symmetric
        /// The left eye is the source frame untouched and the right eye carries
        /// the full disparity.
        case leftEyeUntouched

        var id: String { rawValue }

        var label: String {
            switch self {
            case .symmetric: return "Balanced"
            case .leftEyeUntouched: return "Sharp left eye"
            }
        }

        /// The multiplier applied to d when sampling for an eye.
        ///
        /// Carried across from the Mac verbatim. The eye factor holds the whole
        /// stereo convention, so this function is the one place the sense of
        /// the picture can be reversed, and SignConventionCheck measures it.
        func factor(for eye: Eye) -> Float {
            switch self {
            case .symmetric:
                return eye == .left ? 0.5 : -0.5
            case .leftEyeUntouched:
                return eye == .left ? 0 : -1.0
            }
        }
    }

    enum Eye: Int, Sendable, CaseIterable {
        case left = 0
        case right = 1
    }

    /// Defaults to keeping the left eye pristine, for the Mac's reason: the
    /// visual system favours the sharper eye, so one perfect view plus one
    /// rebuilt view reads cleaner than two half rebuilt views. It also halves
    /// the warp work, which on a headset is not a rounding error.
    var synthesis: Synthesis = .leftEyeUntouched

    /// Flips which eye each view is sampled for.
    ///
    /// False is the verified setting. It exists as a named switch rather than a
    /// sign buried in a shader so that a reversal is a one line change with a
    /// check watching it, instead of a hunt.
    var invertDisparitySign: Bool = false

    // MARK: Warp

    /// Both synthesized views are scaled by this much and cropped to frame,
    /// hiding the edge stretch the mesh warp leaves behind.
    var overscan: Double = 0.025

    /// One warp mesh vertex per this many pixels.
    var meshVertexSpacing: Int = 4

    /// Fills disocclusions from a background plate rather than letting the warp
    /// mesh smear across them.
    var fillDisocclusions: Bool = true

    /// How far a triangle may stretch before its pixels are treated as a gap
    /// rather than as content. 1.0 is untouched.
    var stretchLimit: Double = 1.6

    /// Disparity at or below which a pixel counts as background worth keeping,
    /// as a fraction of the frame's own maximum push behind screen.
    var backgroundLevelFraction: Double = 0.35

    /// How quickly fresh background replaces what the plate already holds. Low,
    /// because the plate's value is its memory.
    var backgroundPlateBlend: Double = 0.15

    /// Joint bilateral upsampling, guided by frame luma.
    var bilateralSpatialSigma: Double = 4.0
    var bilateralLumaSigma: Double = 0.1

    static let `default` = StereoTuning()

    /// The tuning a shot's own metadata suggests, with everything else left
    /// alone. The suggestions are the Mac's opinion; the dial is the user's,
    /// so this is only ever applied when the user has not taken over.
    func applying(_ metadata: ShotMetadata) -> StereoTuning {
        var copy = self
        copy.strength = min(max(metadata.suggestedStrength, Self.strengthRange.lowerBound),
                            Self.strengthRange.upperBound)
        copy.convergence = min(max(metadata.suggestedConvergence, Self.convergenceRange.lowerBound),
                               Self.convergenceRange.upperBound)
        return copy
    }

    /// The largest forward pop this tuning produces on a shot, in pixels.
    ///
    /// Computed rather than measured off the GPU, because the shot metadata
    /// already says where its nearest point is: stored level 255 maps to
    /// `depthOffset + depthScale`. A reduction over the depth texture would
    /// give the same answer a frame later and cost a readback.
    func forwardPopPixels(shot: ShotMetadata, frameWidth: Int) -> Double {
        let nearest = shot.depthOffset + shot.depthScale
        return max(0, strength * Double(frameWidth) * (nearest - convergence) * forwardPopScale)
    }

    /// The largest push behind the screen plane, in pixels.
    func depthPixels(shot: ShotMetadata, frameWidth: Int) -> Double {
        let farthest = shot.depthOffset
        return max(0, strength * Double(frameWidth) * (convergence - farthest))
    }
}
