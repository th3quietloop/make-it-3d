import SwiftUI

/// The one control this app exists for.
///
/// It is a drag, not a slider, and the difference matters. A slider is a thing
/// you look at while you move it, and looking at a control means not looking at
/// the picture. The whole point is to change the depth while watching the film,
/// so the gesture is a horizontal drag anywhere on the surface, the readout is
/// large enough to catch in peripheral vision, and there is no thumb to hunt
/// for.
///
/// No animation on the value, deliberately. Any easing between where the dial
/// was and where it is would mean the picture disagrees with the number for a
/// few frames, and the number is the only thing the user has to hold on to.
struct DepthDial: View {

    let value: Double
    let range: ClosedRange<Double>
    let label: String
    /// The unit the readout is in, and how to say the number in it.
    let format: (Double) -> String
    let onChange: (Double) -> Void

    @State private var dragStartValue: Double?
    @GestureState private var isDragging = false

    /// How much of the range one full width of travel covers. One, so the
    /// control's width is the range, which is the only mapping nobody has to
    /// learn.
    private let travelFraction = 1.0

    var body: some View {
        GeometryReader { geometry in
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: VisionTokens.Radius.control)
                    .fill(.white.opacity(0.10))

                RoundedRectangle(cornerRadius: VisionTokens.Radius.control)
                    .fill(VisionTokens.Palette.accent.opacity(isDragging ? 0.55 : 0.38))
                    .frame(width: max(geometry.size.width * fraction, 0))

                HStack {
                    Text(label)
                        .font(VisionTokens.Font.bodyMedium)
                        .foregroundStyle(VisionTokens.Palette.textPrimary)
                    Spacer()
                    Text(format(value))
                        .font(VisionTokens.Font.monoReadout)
                        .foregroundStyle(VisionTokens.Palette.textPrimary)
                }
                .padding(.horizontal, VisionTokens.Space.m)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { drag in
                        let start = dragStartValue ?? value
                        if dragStartValue == nil { dragStartValue = value }
                        let span = range.upperBound - range.lowerBound
                        let delta = Double(drag.translation.width) / Double(geometry.size.width)
                        onChange(start + delta * span * travelFraction)
                    }
                    .onEnded { _ in dragStartValue = nil }
            )
        }
        // Tall enough to hit while leaning back, and tall enough for a 28pt
        // readout to sit in without crowding.
        .frame(height: 72)
    }
}

/// The comfort gauge: where this shot's depth lands, in pixels of disparity.
///
/// Pixels rather than a five star rating, because pixels are the thing that
/// makes eyes ache and a number can be argued with. Forward pop is drawn in
/// vermilion and depth behind the screen in cyan, which is the one place in
/// this app the paired stereo colours are allowed, because here they carry
/// their literal meaning.
struct DisparityGauge: View {

    let forwardPixels: Double
    let behindPixels: Double
    let frameWidth: Int

    /// Roughly one percent of frame width forward is the comfort budget the Mac
    /// engine works to.
    private var budget: Double { Double(frameWidth) * 0.01 }

    var body: some View {
        VStack(alignment: .leading, spacing: VisionTokens.Space.xs) {
            SectionLabel("Disparity")

            GeometryReader { geometry in
                let scale = geometry.size.width / 2 / max(budget * 1.6, 1)
                ZStack(alignment: .center) {
                    Capsule().fill(.white.opacity(0.10))

                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Capsule()
                            .fill(VisionTokens.Palette.accent)
                            .frame(width: min(behindPixels * scale, geometry.size.width / 2))
                        Capsule()
                            .fill(VisionTokens.Palette.stereoL)
                            .frame(width: min(forwardPixels * scale, geometry.size.width / 2))
                        Spacer(minLength: 0)
                    }

                    // The screen plane. Everything left of it sits behind the
                    // screen, everything right of it comes toward you.
                    Rectangle()
                        .fill(.white.opacity(0.55))
                        .frame(width: 1)
                }
            }
            .frame(height: 10)

            HStack {
                Text("\(Int(behindPixels.rounded())) px behind")
                Spacer()
                Text("\(Int(forwardPixels.rounded())) px forward")
            }
            .font(VisionTokens.Font.monoCaption)
            .foregroundStyle(
                forwardPixels > budget
                    ? VisionTokens.Palette.error
                    : VisionTokens.Palette.textSecondary
            )
        }
    }
}

#Preview {
    VStack(spacing: VisionTokens.Space.l) {
        DepthDial(
            value: 0.016,
            range: StereoTuning.strengthRange,
            label: "Depth",
            format: { String(format: "%.2f %%", $0 * 100) },
            onChange: { _ in }
        )
        DisparityGauge(forwardPixels: 12, behindPixels: 31, frameWidth: 1920)
    }
    .padding(VisionTokens.Space.xl)
    .frame(width: 480)
}
