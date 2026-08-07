import SwiftUI

/// First launch. The one job is to get a file on screen in one gesture, so the
/// whole surface is the drop target and there is exactly one thing to read.
struct EmptyStateView: View {
    let isTargeted: Bool
    let onBrowse: () -> Void

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

            Button("Choose a file", action: onBrowse)
                .buttonStyle(.plain)
                .font(Tokens.Font.body)
                .foregroundStyle(Tokens.Palette.accent)
                .padding(.top, Tokens.Space.xs)
                .frame(minHeight: Tokens.Layout.minTarget)
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
    EmptyStateView(isTargeted: false) {}
        .frame(width: 900, height: 560)
}

#Preview("Drag over") {
    EmptyStateView(isTargeted: true) {}
        .frame(width: 900, height: 560)
}
