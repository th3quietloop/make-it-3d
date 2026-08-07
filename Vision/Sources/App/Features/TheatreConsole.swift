import SwiftUI

/// The dial, as it appears in the room under the picture.
///
/// One job: change the depth without looking away from the film. So it carries
/// the dial, the number, the comfort gauge and nothing else. Play and pause is
/// here because reaching for a window to stop a film is absurd; everything
/// slower than that lives in the control window, where taking your eyes off the
/// picture is not a cost.
struct TheatreConsole: View {

    let model: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: VisionTokens.Space.s) {
            HStack(spacing: VisionTokens.Space.m) {
                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonBorderShape(.circle)

                DepthDial(
                    value: model.tuning.strength,
                    range: StereoTuning.strengthRange,
                    label: "Depth",
                    format: { String(format: "%.2f %%", $0 * 100) },
                    onChange: { model.setStrength($0) }
                )
            }

            if let pixels = model.disparityPixels, let file = model.file {
                DisparityGauge(
                    forwardPixels: pixels.forward,
                    behindPixels: pixels.behind,
                    frameWidth: file.width
                )
            }

            HStack {
                if model.followsSuggestions {
                    Text("Following the film's own reading of this shot.")
                        .font(VisionTokens.Font.caption)
                        .foregroundStyle(VisionTokens.Palette.textTertiary)
                } else {
                    Button("Back to the film's reading") { model.followSuggestions() }
                        .font(VisionTokens.Font.caption)
                }
                Spacer()
            }
        }
        .padding(VisionTokens.Space.l)
        .frame(width: 760)
        .glassBackgroundEffect()
    }
}
