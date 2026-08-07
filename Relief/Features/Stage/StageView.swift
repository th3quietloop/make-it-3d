import SwiftUI
import CoreMedia

/// The viewer. The largest and brightest thing on screen, because judging depth
/// is the one job of this window.
struct StageView: View {
    @Bindable var model: AppModel
    let conversion: Conversion

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Tokens.Palette.stage

                if let image = model.preview.displayed {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .id(model.previewMode)
                        .transition(.opacity)
                } else if let message = model.preview.errorMessage {
                    stageMessage(message, isError: true)
                } else {
                    stageMessage("Reading depth", isError: false)
                }

                if model.previewMode == .stereo {
                    eyeBadges
                }
            }
            // 150ms crossfade on mode switch. Job: feedback.
            .animation(Tokens.Motion.previewCrossfadeAnimation, value: model.previewMode)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.previewMode == .wiggle {
                wiggleHint
            }

            scrubber
        }
        .background(Tokens.Palette.stage)
    }

    // MARK: Overlays

    private func stageMessage(_ text: String, isError: Bool) -> some View {
        Text(text)
            .font(Tokens.Font.rowTitle)
            .foregroundStyle(isError ? Tokens.Palette.error : Tokens.Palette.textTertiary)
            .multilineTextAlignment(.center)
            .padding(Tokens.Space.l)
    }

    /// The one place vermilion appears in the running app, and it is paired
    /// with cyan and means literally left eye and right eye.
    private var eyeBadges: some View {
        VStack {
            HStack(spacing: Tokens.Space.xs) {
                Text("L")
                    .foregroundStyle(Tokens.Palette.stereoL)
                Text("R")
                    .foregroundStyle(Tokens.Palette.accent)
                Spacer()
            }
            .font(Tokens.Font.monoCaption)
            .padding(Tokens.Space.m)
            Spacer()
        }
    }

    private var wiggleHint: some View {
        Text("If the wiggle looks wrong, the export will too. Tune Strength until it reads.")
            .font(Tokens.Font.caption)
            .foregroundStyle(Tokens.Palette.textTertiary)
            .padding(.horizontal, Tokens.Space.m)
            .padding(.bottom, Tokens.Space.xs)
    }

    // MARK: Scrubber

    /// The only shadow in the app lives here.
    private var scrubber: some View {
        HStack(spacing: Tokens.Space.s) {
            Text(Timecode.precise(
                seconds: model.playhead,
                fps: conversion.probe?.nominalFrameRate ?? 30
            ))
            .font(Tokens.Font.monoCaption)
            .foregroundStyle(Tokens.Palette.textSecondary)
            .frame(width: 72, alignment: .leading)

            Slider(
                value: Binding(
                    get: { model.playhead },
                    set: { model.scrub(to: $0) }
                ),
                in: 0...max(conversion.probe?.duration.seconds ?? 1, 0.01)
            )
            .tint(Tokens.Palette.accent)
            // Zero animation on scrub: speed is the affordance.
            .animation(nil, value: model.playhead)

            Text(conversion.probe?.displayDuration ?? "0:00")
                .font(Tokens.Font.monoCaption)
                .foregroundStyle(Tokens.Palette.textTertiary)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, Tokens.Space.m)
        .padding(.vertical, Tokens.Space.s)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.panel)
                .fill(Tokens.Palette.panel)
                .shadow(
                    color: Tokens.Shadow.scrubberColor,
                    radius: Tokens.Shadow.scrubberRadius,
                    y: Tokens.Shadow.scrubberY
                )
        )
        .padding(Tokens.Space.m)
    }
}

/// The preview mode control, centred over the stage in the toolbar.
struct PreviewModePicker: View {
    @Binding var mode: PreviewMode

    var body: some View {
        Picker("Preview mode", selection: $mode) {
            ForEach(PreviewMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 320)
    }
}
