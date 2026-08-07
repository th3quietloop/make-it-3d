import Foundation

/// Every number the depth pipeline uses lives here. The golden set tunes these,
/// so nothing downstream is allowed to hardcode a constant.
struct EngineTuning: Sendable, Equatable, Codable {

    // MARK: Strength

    /// Disparity strength presets. The value is S in the disparity equation.
    enum Strength: String, Sendable, Codable, CaseIterable, Identifiable {
        case soft, standard, deep

        var id: String { rawValue }

        var label: String {
            switch self {
            case .soft: return "Soft"
            case .standard: return "Standard"
            case .deep: return "Deep"
            }
        }

        /// S, as a fraction of frame width.
        var scale: Double {
            switch self {
            case .soft: return 0.010
            case .standard: return 0.016
            case .deep: return 0.024
            }
        }

        /// What choosing this actually gets you, in the language of watching
        /// something rather than measuring it.
        var explanation: String {
            switch self {
            case .soft:
                return "Subtle depth. Easiest on the eyes for a full film."
            case .standard:
                return "Clear depth without pushing it. Start here."
            case .deep:
                return "Strong depth. Best for short clips and wide shots."
            }
        }
    }

    /// The active preset. When `customDisparityPercent` is non nil it wins.
    var strength: Strength = .standard

    /// Advanced override for S, expressed as a percentage of frame width so the
    /// inspector can show a human number. nil means follow the preset.
    var customDisparityPercent: Double?

    /// The effective S in the disparity equation.
    var disparityScale: Double {
        if let custom = customDisparityPercent { return custom / 100.0 }
        return strength.scale
    }

    // MARK: Disparity

    /// C, the convergence point. Nearness values above C sit in front of the
    /// screen plane, values below sit behind it.
    var convergence: Double = 0.45

    /// Positive disparity is content in front of the screen plane. It is scaled
    /// down so forward pop stays inside the comfort budget.
    var forwardPopScale: Double = 0.5

    /// Flips which eye each view is sampled for, at synthesis time.
    ///
    /// The convention being asserted: for an object nearer than the screen
    /// plane, the ray from the left eye through it meets the screen to the
    /// right of centre and the ray from the right eye meets it to the left.
    /// That is crossed disparity, so the left eye's copy sits further right.
    ///
    /// False is the verified setting. This deliberately does not touch the
    /// disparity magnitude, where positive always means in front of the screen,
    /// because negating that would silently reverse the meaning of every value
    /// downstream. SignConventionCheck measures the result from rendered pixels
    /// and fails the gate if it ever changes.
    var invertDisparitySign: Bool = false

    // MARK: Synthesis

    /// Both synthesized views are scaled by this much and cropped to frame,
    /// hiding the edge stretch the mesh warp leaves behind.
    var overscan: Double = 0.025

    /// One warp mesh vertex per this many pixels.
    var meshVertexSpacing: Int = 4

    /// How the two eye views are produced.
    enum Synthesis: String, Sendable, Codable, CaseIterable, Identifiable {
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

        var explanation: String {
            switch self {
            case .symmetric:
                return "Both eyes are rebuilt. Artifacts are shared evenly between them."
            case .leftEyeUntouched:
                return "The left eye stays exactly as filmed. All the rebuilding lands in the right eye."
            }
        }
    }

    /// Which depth model reads the footage.
    enum DepthModel: String, Sendable, Codable, CaseIterable, Identifiable {
        /// Depth Anything V2 Small. One frame at a time, smoothed afterwards.
        case perFrame
        /// Video Depth Anything Small. Reads a window of frames and is steady
        /// across a shot by construction rather than by averaging.
        case video

        var id: String { rawValue }

        var label: String {
            switch self {
            case .perFrame: return "Normal"
            case .video: return "Steady (slow)"
            }
        }

        var explanation: String {
            switch self {
            case .perFrame:
                return "Reads each frame on its own. Depth can drift slightly across a shot, which Relief smooths out."
            case .video:
                return "Reads a run of frames together, so depth holds perfectly still. Measured at roughly 300 times slower than Normal, so it is only realistic on clips of a few seconds."
            }
        }

        /// Roughly how many frames a second this model manages, measured on the
        /// synthetic clip. Used to warn before someone starts something that
        /// would run for weeks.
        var measuredFramesPerSecond: Double {
            switch self {
            case .perFrame: return 30
            case .video: return 0.04
            }
        }

        /// True for a model that is correct but not yet practical.
        var isExperimental: Bool { self == .video }
    }

    /// Defaults to the per frame model, because it is the one that is always
    /// present. The video model is used when it has been built into the app.
    var depthModel: DepthModel = .perFrame

    /// Fills disocclusions from a background plate rather than letting the warp
    /// mesh smear across them.
    var fillDisocclusions: Bool = true

    /// How far a triangle may stretch before its pixels are treated as a gap
    /// rather than as content. 1.0 is untouched.
    var stretchLimit: Double = 1.6

    /// Disparity at or below which a pixel counts as background worth keeping.
    /// Expressed as a fraction of the frame's own maximum push behind screen,
    /// so it adapts to the shot rather than to a fixed pixel count.
    var backgroundLevelFraction: Double = 0.35

    /// How quickly fresh background replaces what the plate already holds.
    /// Low, because the plate's value is its memory.
    var backgroundPlateBlend: Double = 0.15

    /// Defaults to keeping the left eye pristine.
    ///
    /// Warping both eyes by half spreads the artifacts evenly, which sounds
    /// fair and is not. The visual system tends to favour the sharper eye, so
    /// one perfect view plus one rebuilt view generally reads cleaner than two
    /// half rebuilt views. It also halves the warp work, because only one eye
    /// has to be rendered.
    var synthesis: Synthesis = .leftEyeUntouched

    // MARK: Depth normalization and stability

    /// Per frame, nearness is clamped to these percentiles then scaled to 0...1.
    var lowPercentile: Double = 0.02
    var highPercentile: Double = 0.98

    /// Exponential moving average factor across frames.
    var temporalAlpha: Double = 0.2

    /// If mean absolute nearness delta between consecutive frames exceeds this,
    /// the EMA resets to the new frame rather than smearing across the cut.
    var sceneCutThreshold: Double = 0.18

    /// Joint bilateral upsampling, guided by frame luma.
    var bilateralSpatialSigma: Double = 4.0
    var bilateralLumaSigma: Double = 0.1

    // MARK: Spatial metadata

    /// Horizontal field of view, degrees. Written as millidegrees.
    var horizontalFOVDegrees: Double = 63.4

    /// Stereo camera baseline, millimetres. Written as micrometres.
    var baselineMillimetres: Double = 19.2

    /// Horizontal disparity adjustment, as a fraction. Written as an int32 in
    /// the range -10000...10000 for -1.0...1.0.
    var horizontalDisparityAdjustment: Double = 0.025

    // MARK: Preview

    /// Preview runs at this height when the source is taller, so the judgment
    /// loop stays responsive while export stays full resolution.
    var previewMaxHeight: Int = 720

    static let `default` = EngineTuning()
}
