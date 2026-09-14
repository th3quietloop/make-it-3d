import SwiftUI

/// A detail window below the image complements the whole-film shot overview.
/// Its bounds remain fixed while scrubbing, avoiding a timeline that slides
/// underneath the pointer. External navigation recenters only when necessary.
struct PreviewTimelineWindow: View {
    let plan: ShotPlan?
    let range: ClosedRange<Double>
    let fullRange: ClosedRange<Double>
    let playhead: Double
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onCenter: () -> Void
    let onSeek: (Double) -> Void

    private var span: Double { max(0.01, range.upperBound - range.lowerBound) }
    private var zoom: Double { (fullRange.upperBound - fullRange.lowerBound) / span }
    private var visibleShots: [Shot] {
        plan?.shots.filter { $0.end.seconds > range.lowerBound && $0.start.seconds < range.upperBound } ?? []
    }

    var body: some View {
        VStack(spacing: Tokens.Space.xxs) {
            HStack(spacing: Tokens.Space.xs) {
                Button(action: onPrevious) { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous timeline window")
                    .disabled(range.lowerBound <= fullRange.lowerBound)
                Text("\(PreviewNavigation.timecode(range.lowerBound)) – \(PreviewNavigation.timecode(range.upperBound)) · \(zoom, specifier: "%.1f")×")
                    .font(Tokens.Font.monoCaption)
                    .lineLimit(1)
                    .accessibilityLabel("Timeline window from \(PreviewNavigation.timecode(range.lowerBound)) to \(PreviewNavigation.timecode(range.upperBound)), \(zoom, specifier: "%.1f") times zoom")
                Button(action: onNext) { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next timeline window")
                    .disabled(range.upperBound >= fullRange.upperBound)
                Spacer(minLength: 0)
                Button("Center on playhead", action: onCenter)
                    .font(Tokens.Font.caption)
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Tokens.Palette.textSecondaryVibrant)

            if !visibleShots.isEmpty {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        ForEach(visibleShots) { shot in
                            let start = max(shot.start.seconds, range.lowerBound)
                            let end = min(shot.end.seconds, range.upperBound)
                            let selected = playhead >= shot.start.seconds && playhead < shot.end.seconds
                            Button { onSeek(start) } label: {
                                Text("Shot \(shot.id + 1)")
                                    .font(Tokens.Font.caption)
                                    .lineLimit(1)
                                    .frame(width: max(1, geometry.size.width * (end - start) / span), height: 24)
                                    .background(Tokens.Palette.accent.opacity(selected ? 0.22 : 0.08))
                                    .overlay(alignment: .leading) {
                                        Rectangle().fill(Tokens.Palette.accent.opacity(0.7)).frame(width: 1)
                                    }
                                    .clipped()
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Shot \(shot.id + 1), from \(PreviewNavigation.timecode(shot.start.seconds)) to \(PreviewNavigation.timecode(shot.end.seconds)). Inspect this shot.")
                            .help("Shot \(shot.id + 1) · \(PreviewNavigation.timecode(shot.start.seconds))")
                        }
                    }
                }
                .frame(height: 24)
                .clipShape(.rect(cornerRadius: Tokens.Radius.control))
            }
        }
    }

    nonisolated static func range(within bounds: ClosedRange<Double>, requestedSpan: Double, start: Double) -> ClosedRange<Double> {
        let fullSpan = bounds.upperBound - bounds.lowerBound
        guard requestedSpan > 0, requestedSpan < fullSpan else { return bounds }
        let span = max(0.01, requestedSpan)
        let lower = min(max(start, bounds.lowerBound), bounds.upperBound - span)
        return lower...(lower + span)
    }
}
