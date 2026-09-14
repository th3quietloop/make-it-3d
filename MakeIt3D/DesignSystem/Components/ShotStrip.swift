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
/// One time scale drives segment bounds, the marker, and seeking. Separators
/// overlay their segments and never add time or layout width.
enum ShotTimeline {
    static func fraction(_ seconds: Double, duration: Double) -> Double {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(max(seconds / duration, 0), 1)
    }

    static func segment(_ shot: Shot, duration: Double, width: CGFloat) -> CGRect {
        let start = fraction(shot.start.seconds, duration: duration)
        let end = fraction(shot.end.seconds, duration: duration)
        return CGRect(x: width * start, y: 0, width: width * max(end - start, 0), height: 1)
    }
}

struct ShotStrip: View {
    let plan: ShotPlan
    let duration: Double
    let playhead: Double
    var sourceURL: URL? = nil
    let onScrub: (Double) -> Void
    @State private var showingShots = false

    private var currentIndex: Int {
        plan.shots.firstIndex { $0.start.seconds <= playhead && playhead < $0.end.seconds }
            ?? max(plan.shots.count - 1, 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Tokens.Palette.panelRaised
                    ForEach(plan.shots) { shot in
                        let bounds = ShotTimeline.segment(shot, duration: duration, width: geometry.size.width)
                        Rectangle()
                            .fill(Tokens.Palette.textTertiary.mix(with: Tokens.Palette.accent,
                                                               by: shot.settings.confidence))
                            .frame(width: bounds.width)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(Tokens.Palette.stage)
                                    .frame(width: Tokens.Layout.hairlineWidth)
                            }
                            .offset(x: bounds.minX)
                            .help(shotDescription(shot))
                    }
                    Rectangle()
                        .fill(Tokens.Palette.textPrimary)
                        .frame(width: Tokens.Layout.gaugeMarker)
                        .offset(x: min(geometry.size.width * ShotTimeline.fraction(playhead, duration: duration),
                                       max(geometry.size.width - Tokens.Layout.gaugeMarker, 0)))
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .onTapGesture { point in
                    guard geometry.size.width > 0 else { return }
                    onScrub(max(duration, 0) * min(max(point.x / geometry.size.width, 0), 1))
                }
            }
            .frame(height: Tokens.Layout.shotStripHeight)
            .clipShape(.rect(cornerRadius: Tokens.Radius.control))
            .accessibilityRepresentation {
                Slider(value: Binding(get: { min(max(playhead, 0), max(duration, 0.001)) },
                                      set: { value in onScrub(value) }), in: 0...max(duration, 0.001)) {
                    Text("Shot timeline")
                }
                .accessibilityValue("Shot \(currentIndex + 1) of \(plan.shots.count), \(Timecode.string(from: playhead))")
            }

            HStack(spacing: Tokens.Space.xs) {
                Button { jump(by: -1) } label: { Image(systemName: "backward.end") }
                    .disabled(currentIndex == 0 || plan.shots.isEmpty)
                    .help("Previous shot")
                    .accessibilityLabel("Previous shot")
                Button { showingShots.toggle() } label: {
                    Text(plan.shots.isEmpty ? "No shots" : "Shot \(currentIndex + 1) of \(plan.shots.count)")
                    Image(systemName: "square.grid.2x2")
                }
                .help("Inspect and navigate shots")
                .sheet(isPresented: $showingShots) {
                    if let sourceURL {
                        ShotReviewSheet(sourceURL: sourceURL, plan: plan) { time in
                            onScrub(time)
                            showingShots = false
                        }
                    } else {
                        List(plan.shots) { shot in
                            Button(shotDescription(shot)) { onScrub(shot.start.seconds); showingShots = false }
                        }.frame(width: 420, height: 360)
                    }
                }
                Button { jump(by: 1) } label: { Image(systemName: "forward.end") }
                    .disabled(currentIndex >= plan.shots.count - 1)
                    .help("Next shot")
                    .accessibilityLabel("Next shot")
                Spacer()
                Text("Estimated range").help("Color indicates the estimated depth range, not model certainty.")
                Text("Low")
                Circle().fill(Tokens.Palette.textTertiary).frame(width: 6, height: 6)
                Circle().fill(Tokens.Palette.accent).frame(width: 6, height: 6)
                Text("High")
            }
            .buttonStyle(.plain)
            .font(Tokens.Font.caption)
            .foregroundStyle(Tokens.Palette.textSecondary)
            .frame(minHeight: Tokens.Layout.minTarget)
        }
        .accessibilityElement(children: .contain)
    }

    private func jump(by delta: Int) {
        let index = currentIndex + delta
        guard plan.shots.indices.contains(index) else { return }
        onScrub(plan.shots[index].start.seconds)
    }
}

private func shotDescription(_ shot: Shot) -> String {
    "Shot \(shot.id + 1), \(Timecode.string(from: shot.start.seconds)). \(shot.settings.explanation)"
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
