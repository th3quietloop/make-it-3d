import SwiftUI

/// First launch. The one job is to get a file on screen in one gesture, so the
/// whole surface is the drop target and there is exactly one thing to read.
struct EmptyStateView: View {
    let isTargeted: Bool
    let onBrowse: () -> Void
    let onSample: () -> Void
    /// True until the first run beats have been seen, which is the only thing
    /// that changes what this screen offers.
    var isFirstRun: Bool = false

    var body: some View {
        VStack(spacing: Tokens.Space.s) {
            Text("Drop a movie here.")
                .font(Tokens.Font.headline)
                .foregroundStyle(Tokens.Palette.textPrimary)
                .lineSpacing(Tokens.LineSpacing.labels(Tokens.TypeScale.headline))

            Text("Relief reads its depth and writes a spatial video your Vision Pro plays natively.")
                .font(Tokens.Font.body)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(Tokens.LineSpacing.supporting(Tokens.TypeScale.body))
                .frame(maxWidth: 380)

            HStack(spacing: Tokens.Space.l) {
                Button("Choose a file", action: onBrowse)
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        isFirstRun ? Tokens.Palette.textSecondary : Tokens.Palette.accent
                    )
                    .frame(minHeight: Tokens.Layout.minTarget)

                // Relief can make its own test clip, so a first time user can
                // see the judging loop with no files on hand. The label makes a
                // promise rather than describing a feature: the point is not
                // that a sample exists, it is that you get shown how to read
                // the depth.
                Button(isFirstRun ? "Show me how it works" : "Try a sample clip", action: onSample)
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        isFirstRun ? Tokens.Palette.accent : Tokens.Palette.textSecondary
                    )
                    .frame(minHeight: Tokens.Layout.minTarget)
                    .help("Relief makes a short clip and walks you through reading its depth.")
            }
            .font(Tokens.Font.body)
            .padding(.top, Tokens.Space.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Palette.stage)
        .overlay(
            // The drag over wake state: the stage border comes up to meet the
            // file rather than the layout shifting under the cursor.
            RoundedRectangle(cornerRadius: Tokens.Radius.panel)
                .strokeBorder(
                    isTargeted ? Tokens.Palette.accent : Tokens.Palette.hairline,
                    lineWidth: isTargeted ? Tokens.Layout.focusRingWidth : Tokens.Layout.hairlineWidth
                )
                .padding(Tokens.Space.m)
        )
        .animation(Tokens.Motion.previewCrossfadeAnimation, value: isTargeted)
    }
}

#Preview("Empty") {
    EmptyStateView(isTargeted: false, onBrowse: {}, onSample: {})
        .frame(width: 900, height: 560)
}

#Preview("First run") {
    EmptyStateView(isTargeted: false, onBrowse: {}, onSample: {}, isFirstRun: true)
        .frame(width: 900, height: 560)
}

#Preview("Drag over") {
    EmptyStateView(isTargeted: true, onBrowse: {}, onSample: {})
        .frame(width: 900, height: 560)
}
