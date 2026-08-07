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
