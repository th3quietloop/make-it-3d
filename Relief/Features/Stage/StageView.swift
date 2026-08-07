import SwiftUI
import CoreMedia

/// The viewer. The largest and brightest thing on screen, because judging depth
/// is the one job of this window.
struct StageView: View {
    @Bindable var model: AppModel
    let conversion: Conversion
    let isTargeted: Bool

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
                        .accessibilityElement()
                        .accessibilityLabel(stageDescription)
                } else if let message = model.preview.errorMessage {
                    stageMessage(message, isError: true)
                } else {
                    warmupMessage
                }

                if model.previewMode == .stereo {
                    eyeBadges
                }
                if model.previewMode == .wiggle {
                    wiggleControls
                }
            }
            // 150ms crossfade on mode switch. Job: feedback.
            .animation(Tokens.Motion.previewCrossfadeAnimation, value: model.previewMode)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                // Drag over wake: the stage border comes up to meet the file
                // rather than the layout shifting under the cursor.
                RoundedRectangle(cornerRadius: Tokens.Radius.panel, style: .continuous)
                    .strokeBorder(
                        isTargeted ? Tokens.Palette.accent : .clear,
                        lineWidth: Tokens.Layout.focusRingWidth
                    )
                    .padding(Tokens.Space.xs)
            )
            .animation(Tokens.Motion.previewCrossfadeAnimation, value: isTargeted)

            scrubber
        }
        .background(Tokens.Palette.stage)
    }

    private var stageDescription: String {
        let mode = model.previewMode.label
        let time = Timecode.string(from: model.playhead)
        if model.previewMode == .wiggle {
            let eye = model.preview.showingLeft ? "left eye" : "right eye"
            return "\(mode) preview, \(eye), \(conversion.displayName) at \(time)"
        }
        return "\(mode) preview of \(conversion.displayName) at \(time)"
    }

    // MARK: Overlays

    private func stageMessage(_ text: String, isError: Bool) -> some View {
        Text(text)
            .font(Tokens.Font.rowTitle)
            .foregroundStyle(isError ? Tokens.Palette.errorText : Tokens.Palette.textSecondary)
            .multilineTextAlignment(.center)
            .padding(Tokens.Space.l)
    }

    /// The first depth read has to load the model onto the Neural Engine, which
    /// takes seconds. A static string for that long reads as a crash, so the
    /// first one says it is a one time cost.
    @ViewBuilder
    private var warmupMessage: some View {
        VStack(spacing: Tokens.Space.xs) {
            Text(model.preview.isWarmingUp ? "Warming up the depth engine" : "Reading depth")
                .font(Tokens.Font.rowTitle)
                .foregroundStyle(Tokens.Palette.textSecondary)
            if model.preview.isWarmingUp {
                Text("Only takes this long the first time.")
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
            }
        }
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
        .accessibilityHidden(true)
    }

    /// Which eye is showing and whether it is running. A paused wiggle used to
    /// be indistinguishable from Source mode.
    private var wiggleControls: some View {
        VStack {
            HStack(spacing: Tokens.Space.xs) {
                Button {
                    model.toggleWiggle()
                } label: {
                    Image(systemName: model.preview.isWigglePlaying ? "pause.fill" : "play.fill")
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Palette.stage)
                        .frame(width: Tokens.Layout.minTarget, height: Tokens.Layout.minTarget)
                        .background(Tokens.Palette.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.preview.reduceMotion)
                .help(model.preview.reduceMotion
                      ? "Alternation is off while Reduce Motion is on. Use Flip to compare."
                      : "Play or pause the alternation. Space.")

                Button("Flip") { model.preview.flipEye() }
                    .buttonStyle(.plain)
                    .font(Tokens.Font.monoCaption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .frame(minHeight: Tokens.Layout.minTarget)
                    .help("Show the other eye.")

                Text(model.preview.showingLeft ? "LEFT" : "RIGHT")
                    .font(Tokens.Font.monoCaption)
                    .foregroundStyle(
                        model.preview.showingLeft
                            ? Tokens.Palette.stereoL : Tokens.Palette.accent
                    )

                Spacer()
            }
            .padding(Tokens.Space.m)
            Spacer()
        }
    }

    // MARK: Scrubber

    /// The only shadow in the app lives here.
    private var scrubber: some View {
        HStack(spacing: Tokens.Space.s) {
            Text(Timecode.string(from: model.playhead))
                .font(Tokens.Font.monoCaption)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .frame(width: Tokens.Layout.durationColumn, alignment: .leading)
                .help(Timecode.precise(
                    seconds: model.playhead,
                    fps: conversion.probe?.nominalFrameRate ?? 30
                ))

            Slider(
                value: Binding(
                    get: { model.playhead },
                    set: { model.scrub(to: $0) }
                ),
                in: 0...max(conversion.probe?.duration.seconds ?? 1, 0.01)
            ) {
                Text("Playhead")
            }
            .labelsHidden()
            .tint(Tokens.Palette.accent)
            // Zero animation on scrub: speed is the affordance.
            .animation(nil, value: model.playhead)
            .accessibilityValue(Timecode.string(from: model.playhead))

            // Both ends speak the same dialect. The frame accurate reading is
            // in the tooltip, where it does not compete.
            Text(conversion.probe?.displayDuration ?? "0:00")
                .font(Tokens.Font.monoCaption)
                .foregroundStyle(Tokens.Palette.textTertiary)
                .frame(width: Tokens.Layout.durationColumn, alignment: .trailing)
        }
        .padding(.horizontal, Tokens.Space.m)
        .padding(.vertical, Tokens.Space.s)
        .surfaceMaterial(.floating)
        .clipShape(.rect(cornerRadius: Tokens.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.panel, style: .continuous)
                .strokeBorder(Tokens.Palette.hairlineVibrant, lineWidth: Tokens.Layout.hairlineWidth)
        )
        .shadow(
            color: Tokens.Shadow.scrubberColor,
            radius: Tokens.Shadow.scrubberRadius,
            y: Tokens.Shadow.scrubberY
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
        .frame(width: Tokens.Layout.previewPickerWidth)
        .help("Source, depth map, red and cyan stereo, or eye by eye comparison.")
    }
}
