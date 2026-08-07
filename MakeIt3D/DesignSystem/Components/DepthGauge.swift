import SwiftUI

/// How much depth this frame actually has, said in words.
///
/// This replaced a pair of readouts that said "In front 2.7 px" and
/// "Behind 4.4 px". Pixels of disparity are an implementation unit. Nobody
/// sitting down to watch a film thinks in them, and the numbers answered a
/// question nobody asked while leaving the only real question, is this
/// comfortable, unanswered.
///
/// The gauge answers that question directly and keeps the pixel values in the
/// tooltip for the one person who wants them.
struct DepthReading: Equatable {
    /// Largest forward pop, in pixels.
    let forward: Float
    /// Largest push behind the screen, in pixels (a negative number).
    let behind: Float
    /// Frame width the pixels were measured against.
    let frameWidth: Int
    /// What the model actually saw before normalization. Without this the
    /// gauge can only describe the settings, which is what it used to do.
    var content: DepthContent = .unknown

    /// Comfort budgets as a fraction of frame width. Forward is the strict one:
    /// content in front of the screen plane is what makes eyes tire, so it gets
    /// roughly a third of the room that content behind the screen gets.
    static let forwardBudget = 0.010
    static let behindBudget = 0.030

    /// 0 means flat. 1 means sitting exactly on the comfort budget. Above 1 is
    /// past it. The larger of the two directions wins, because comfort is
    /// decided by whichever one is worst.
    var load: Double {
        guard frameWidth > 0 else { return 0 }
        let width = Double(frameWidth)
        let forwardLoad = (Double(forward) / width) / Self.forwardBudget
        let behindLoad = (Double(abs(behind)) / width) / Self.behindBudget
        return max(forwardLoad, behindLoad)
    }

    enum Verdict: Equatable {
        /// The shot itself has almost no depth in it. This is about the
        /// footage, not the settings, and no setting fixes it.
        case noDepthInShot
        case gentle
        case comfortable
        case strong
        case tooMuch

        var label: String {
            switch self {
            case .noDepthInShot: return "Flat shot"
            case .gentle: return "Gentle depth"
            case .comfortable: return "Good depth"
            case .strong: return "Strong depth"
            case .tooMuch: return "Too strong"
            }
        }

        /// One line, in the language of watching something, not measuring it.
        var explanation: String {
            switch self {
            case .noDepthInShot:
                return "There is barely any real depth in this shot, so turning the strength up will make it wobble rather than pop."
            case .gentle:
                return "Subtle, easy to watch for a whole film."
            case .comfortable:
                return "Clear separation, comfortable to sit with."
            case .strong:
                return "Plenty of pop. Fine for a short clip, tiring for a long one."
            case .tooMuch:
                return "Likely to strain your eyes. Try Standard or Soft."
            }
        }
    }

    /// The verdict, from the footage first and the settings second.
    ///
    /// Order matters here. The gauge used to read `load` alone, and because
    /// every frame is normalized to a full nearness range before disparity is
    /// computed, `load` is a function of the strength and convergence settings
    /// and nothing else. It reported one of three fixed answers, one per
    /// preset, on every shot of every film. A flat wall and a canyon were
    /// indistinguishable to it.
    ///
    /// A shot with no real depth is now called out as such, whatever the
    /// settings say, because that is the one situation where changing the
    /// settings is the wrong move.
    var verdict: Verdict {
        if content.isMeasured, content.confidence < 0.12 { return .noDepthInShot }
        switch load {
        case ..<0.5: return .gentle
        case ..<1.0: return .comfortable
        case ..<1.4: return .strong
        default: return .tooMuch
        }
    }

    /// The exact numbers, for the tooltip.
    var precise: String {
        let base = String(
            format: "Forward %.1f px, behind %.1f px, on a %d px frame.",
            forward, abs(behind), frameWidth
        )
        guard content.isMeasured else { return base }
        return base + String(
            format: " Depth spread %.2f, confidence %.0f%%.",
            content.spread, content.confidence * 100
        )
    }
}

/// A bar from flat to too much, with this frame's marker on it.
struct DepthGauge: View {
    let reading: DepthReading

    /// Where the comfort budget sits on the track. Everything left of this is
    /// comfortable; everything right of it is spending eye budget.
    private let comfortStop: Double = 1.0 / 1.6
    private let scaleMax: Double = 1.6

    private var position: Double {
        min(max(reading.load / scaleMax, 0), 1)
    }

    private var isOverBudget: Bool { reading.load >= 1.4 }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "This shot")
                Spacer()
                Text(reading.verdict.label)
                    .font(Tokens.Font.bodyMedium)
                    .foregroundStyle(
                        isOverBudget ? Tokens.Palette.errorText : Tokens.Palette.accent
                    )
                    .contentTransition(.numericText())
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // The comfortable stretch, then the stretch that costs you.
                    HStack(spacing: 0) {
                        Capsule().fill(Tokens.Palette.accent.opacity(0.28))
                            .frame(width: geometry.size.width * comfortStop)
                        Capsule().fill(Tokens.Palette.error.opacity(0.28))
                    }

                    // This frame. It settles into place rather than jumping,
                    // so a slider drag reads as one continuous movement.
                    Capsule()
                        .fill(isOverBudget ? Tokens.Palette.errorText : Tokens.Palette.accent)
                        .frame(width: Tokens.Layout.gaugeMarker)
                        .animation(Tokens.Motion.panelSpring, value: position)
                        .offset(
                            x: min(
                                max(geometry.size.width * position - Tokens.Layout.gaugeMarker / 2, 0),
                                geometry.size.width - Tokens.Layout.gaugeMarker
                            )
                        )
                }
            }
            .frame(height: Tokens.Layout.gaugeHeight)

            HStack {
                Text("Flat")
                Spacer()
                Text("Too strong")
            }
            .font(Tokens.Font.caption)
            .foregroundStyle(Tokens.Palette.textTertiary)

            Text(reading.verdict.explanation)
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Palette.textSecondaryVibrant)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(Tokens.LineSpacing.labels(Tokens.TypeScale.caption))
        }
        .help(reading.precise)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Depth in this shot")
        .accessibilityValue("\(reading.verdict.label). \(reading.verdict.explanation)")
    }
}

#Preview {
    VStack(alignment: .leading, spacing: Tokens.Space.l) {
        DepthGauge(reading: DepthReading(forward: 0.4, behind: -0.6, frameWidth: 1280))
        DepthGauge(reading: DepthReading(forward: 5.6, behind: -9.2, frameWidth: 1280))
        DepthGauge(reading: DepthReading(forward: 22, behind: -40, frameWidth: 1280))
    }
    .padding(Tokens.Space.m)
    .frame(width: Tokens.Layout.inspectorWidth)
    .background(Tokens.Palette.panel)
}
