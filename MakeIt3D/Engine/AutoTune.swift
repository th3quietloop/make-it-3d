import Foundation

/// Works out the depth settings for a shot instead of making someone guess.
///
/// Two numbers come out: S, how far apart the eyes get pushed, and C, where the
/// screen plane sits in the scene. Both used to be one fixed value applied to
/// every frame of every film, which is like choosing one exposure for a whole
/// movie and hoping.
///
/// This is arithmetic, not a model. Disparity is linear in S, so the strength
/// that lands a shot on a chosen comfort budget can be solved for directly
/// rather than searched. The only judgement in here is the budget itself and
/// how much to trust a flat looking shot, and both are written down.
enum AutoTune {

    /// What the tuner aims for on the comfort scale, where 1.0 is exactly on
    /// budget. Deliberately under 1: the budget is the edge of comfortable, and
    /// aiming at the edge means half the shots land past it.
    static let target = 0.75

    /// Where the screen plane goes, as a percentile of the frame's nearness.
    ///
    /// 0.70 means the nearest 30% of the picture comes forward and the other
    /// 70% sits behind the screen. That split is not arbitrary: content in
    /// front of the screen plane is what tires eyes, and the comfort budget
    /// gives it roughly a third of the room it gives content behind. Putting
    /// most of the picture behind the glass is what makes a long film watchable.
    static let forwardShare = 0.30

    struct Result: Equatable, Sendable {
        let strength: Double
        let convergence: Double
        /// What the resulting comfort load should be, for the report.
        let predictedLoad: Double
        /// How much real depth the tuner found, 0 to 1.
        let confidence: Double

        /// Said in the language of watching something.
        var explanation: String {
            switch confidence {
            case ..<0.2:
                return "Not much real depth in this shot, so the settings stay gentle. Pushing a flat scene harder only makes it wobble."
            case ..<0.6:
                return "Moderate depth. Settings sit in the middle."
            default:
                return "Plenty of real depth here, so this shot can take a strong setting."
            }
        }
    }

    /// Solves for the settings that put this shot on the comfort target.
    ///
    /// - Parameters:
    ///   - content: what the model actually saw, before normalization.
    ///   - nearMassCurve: the frame's nearness distribution is not uniform, so
    ///     the convergence point is taken from the measured near mass rather
    ///     than assumed to sit at 0.70 of the range.
    static func settings(for content: DepthContent) -> Result {
        let confidence = content.confidence

        // Convergence. Start from the split the comfort budget implies, then
        // pull toward wherever the picture's mass actually is. A close up has a
        // big near mass and wants the plane further forward so the face lands
        // near the glass rather than out in the room.
        let base = 1.0 - forwardShare
        let measured = content.isMeasured ? content.nearMass : forwardShare
        // nearMass is the share of the frame in the near half. Convergence
        // moves toward the near end as that share grows.
        let convergence = min(max(base * 0.6 + (1.0 - measured) * 0.4, 0.35), 0.85)

        // Strength. Solve max(forwardLoad, behindLoad) = target for S.
        //
        //   forwardLoad = S * (1 - C) * forwardPopScale / forwardBudget
        //   behindLoad  = S * C / behindBudget
        //
        // Both are linear in S, so the binding one decides it and there is no
        // search to run.
        let forwardTerm = (1 - convergence) * EngineTuning.default.forwardPopScale
            / DepthReading.forwardBudget
        let behindTerm = convergence / DepthReading.behindBudget
        let binding = max(forwardTerm, behindTerm)

        // A shot with little real depth gets a smaller share of the budget,
        // because most of what it would be pushing is amplified noise.
        let effectiveTarget = target * (0.35 + 0.65 * confidence)
        let solved = binding > 0 ? effectiveTarget / binding : EngineTuning.Strength.standard.scale

        // The ceiling is Standard, not Deep.
        //
        // Deep was the ceiling until a full length film went through and came
        // back with visible cut out edges around people. That artifact is the
        // warp tearing where the depth map cliffs from subject to background,
        // and its width scales directly with disparity, so a third less
        // strength is a third less tear on exactly the shots that show it.
        //
        // The tuner is also the wrong thing to trust at the top of the range.
        // High confidence means the shot has a lot of depth in it, which
        // usually means a lot of depth discontinuity, which is precisely when
        // pushing hard hurts most. Until the disparity is feathered across
        // those edges, confidence should buy less than it did.
        //
        // Deep is still one click away in Custom for anyone who wants the pop
        // and does not mind the edges.
        let strength = min(max(solved, EngineTuning.Strength.soft.scale * 0.6),
                           EngineTuning.Strength.standard.scale)

        return Result(
            strength: strength,
            convergence: convergence,
            predictedLoad: strength * binding,
            confidence: confidence
        )
    }

    /// Applies a result to a tuning, leaving everything else alone.
    static func apply(_ result: Result, to tuning: EngineTuning) -> EngineTuning {
        var updated = tuning
        updated.customDisparityPercent = result.strength * 100
        updated.convergence = result.convergence
        return updated
    }
}
