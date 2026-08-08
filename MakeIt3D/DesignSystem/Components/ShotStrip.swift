import SwiftUI
import CoreMedia

/// The film's shots, laid out along the timeline, each coloured by how much
/// real depth is in it.
///
/// This is the visible form of the thing the app was previously hiding: a film
/// is not one scene, and one depth setting across all of it is a compromise
/// between shots that never wanted the same answer. Once you can see that the
/// third shot is nearly flat and the seventh is a canyon, the per shot tuning
/// stops being a feature and starts being obvious.
struct ShotStrip: View {
    let plan: ShotPlan
    let duration: Double
    let playhead: Double
    let onScrub: (Double) -> Void

    @State private var hovered: Shot.ID?

    private var totalSeconds: Double { max(duration, 0.001) }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    HStack(spacing: Tokens.Layout.hairlineWidth) {
                        ForEach(plan.shots) { shot in
                            segment(shot, in: geometry.size.width)
                        }
                    }

                    // Where you are, over the top of all of it.
                    Rectangle()
                        .fill(Tokens.Palette.textPrimary)
                        .frame(width: Tokens.Layout.gaugeMarker)
                        .offset(x: min(max(geometry.size.width * (playhead / totalSeconds), 0),
                                       geometry.size.width - Tokens.Layout.gaugeMarker))
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    onScrub(totalSeconds * Double(location.x / geometry.size.width))
                }
            }
            .frame(height: Tokens.Layout.shotStripHeight)
            .clipShape(.rect(cornerRadius: Tokens.Radius.control, style: .continuous))

            HStack {
                Text(caption)
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                Spacer()
                // The legend, because a colour ramp with no key is decoration.
                HStack(spacing: Tokens.Space.xxs) {
                    Text("Flat")
                    Rectangle()
                        .fill(LinearGradient(
                            colors: [Tokens.Palette.textTertiary, Tokens.Palette.accent],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: 32, height: Tokens.Layout.hairlineWidth * 4)
                        .clipShape(Capsule())
                    Text("Deep")
                }
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Palette.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shots")
        .accessibilityValue(plan.summary)
    }

    private func segment(_ shot: Shot, in width: CGFloat) -> some View {
        let fraction = shot.duration.seconds / totalSeconds
        return Rectangle()
            .fill(colour(for: shot))
            .frame(width: max(width * fraction, 1))
            .overlay {
                if hovered == shot.id {
                    Rectangle().fill(Tokens.Palette.textPrimary.opacity(0.18))
                }
            }
            .onHover { hovered = $0 ? shot.id : nil }
            .help(tooltip(for: shot))
    }

    /// Confidence, as colour. A shot the tuner does not trust reads grey,
    /// which is also what it looks like: no information.
    private func colour(for shot: Shot) -> Color {
        let confidence = shot.settings.confidence
        return Tokens.Palette.textTertiary.mix(with: Tokens.Palette.accent, by: confidence)
    }

    private func tooltip(for shot: Shot) -> String {
        String(
            format: "Shot %d, %@. Depth %.1f%% of frame width, balance %.2f. %@",
            shot.id + 1,
            AppModel.humanDuration(shot.duration.seconds),
            shot.settings.strength * 100,
            shot.settings.convergence,
            shot.settings.explanation
        )
    }

    private var caption: String {
        guard let current = plan.shot(at: CMTime(seconds: playhead, preferredTimescale: 600)) else {
            return plan.summary
        }
        // Was followed by the tuner explaining its reasoning, unprompted,
        // while you are trying to look at a picture. The colour already
        // carries it and the tooltip has the detail for anyone who asks.
        return "Shot \(current.id + 1) of \(plan.shots.count)"
    }
}

#Preview {
    ShotStrip(
        plan: ShotPlan(
            shots: (0..<6).map { index in
                Shot(
                    id: index,
                    start: CMTime(seconds: Double(index) * 10, preferredTimescale: 600),
                    end: CMTime(seconds: Double(index + 1) * 10, preferredTimescale: 600),
                    content: DepthContent(low: 1, high: Float(index) * 0.4 + 1.1, median: 1, nearMass: 0.3),
                    settings: AutoTune.settings(
                        for: DepthContent(low: 1, high: Float(index) * 0.4 + 1.1, median: 1, nearMass: 0.3)
                    )
                )
            },
            samplesTaken: 120,
            seconds: 4.2
        ),
        duration: 60,
        playhead: 22,
        onScrub: { _ in }
    )
    .padding(Tokens.Space.m)
    .frame(width: 640)
    .background(Tokens.Palette.stage)
}
