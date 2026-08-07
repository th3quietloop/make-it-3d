import SwiftUI

/// Parameters, on the right, in the Final Cut dialect. Level 0 is the preset
/// row and Convert; Level 1 is convergence; Level 2 is behind Advanced.
struct InspectorView: View {
    @Bindable var model: AppModel
    let conversion: Conversion

    @State private var showAdvanced = false

    private var tuning: Binding<EngineTuning> {
        Binding(
            get: { conversion.tuning },
            set: { model.updateTuning($0, for: conversion) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.l) {
                    strengthSection
                    convergenceSection
                    readoutSection
                    advancedSection
                }
                .padding(Tokens.Space.m)
            }

            Hairline()

            VStack(spacing: Tokens.Space.xs) {
                ConvertButton(title: "Convert", state: convertState) {
                    model.convertAllReady()
                }
                if case .done(let url) = conversion.status {
                    HStack(spacing: Tokens.Space.s) {
                        Button("Reveal in Finder") { model.reveal(url) }
                            .buttonStyle(.plain)
                            .font(Tokens.Font.body)
                            .foregroundStyle(Tokens.Palette.accent)
                        ShareLink(item: url) {
                            Text("Share")
                                .font(Tokens.Font.body)
                                .foregroundStyle(Tokens.Palette.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(minHeight: Tokens.Layout.minTarget)
                }
            }
            .padding(Tokens.Space.m)
        }
        .frame(width: Tokens.Layout.inspectorWidth)
        .background(Tokens.Palette.panel)
    }

    // MARK: Convert state

    private var convertState: ConvertButton.State {
        if model.isConverting {
            return .loading(fraction: model.queueProgress)
        }
        if case .failed(let message) = conversion.status { return .error(message) }
        if model.modelBanner != nil { return .disabled }
        if conversion.status.isReady || conversion.settingsChangedSinceExport { return .normal }
        if conversion.status.isDone { return .disabled }
        return .disabled
    }

    // MARK: Sections

    private var strengthSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            SectionLabel(text: "Strength")
            HStack(spacing: Tokens.Space.xxs) {
                ForEach(EngineTuning.Strength.allCases) { strength in
                    StrengthChip(
                        strength: strength,
                        isSelected: conversion.tuning.customDisparityPercent == nil
                            && conversion.tuning.strength == strength
                    ) {
                        var updated = conversion.tuning
                        updated.strength = strength
                        updated.customDisparityPercent = nil
                        model.updateTuning(updated, for: conversion)
                    }
                }
            }
        }
    }

    private var convergenceSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            HStack {
                SectionLabel(text: "Convergence")
                Spacer()
                Readout(value: String(format: "%.2f", conversion.tuning.convergence))
                    .font(Tokens.Font.monoCaption)
            }

            // The tick marks the screen plane: everything above it sits in
            // front of the screen, everything below sits behind.
            ZStack(alignment: .leading) {
                Slider(value: tuning.convergence, in: 0...1)
                    .tint(Tokens.Palette.accent)
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Tokens.Palette.textTertiary)
                        .frame(width: Tokens.Layout.hairlineWidth, height: Tokens.Layout.tickHeight)
                        .offset(x: geometry.size.width * 0.45, y: -2)
                }
                .allowsHitTesting(false)
            }

            Text("Where the screen plane sits.")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Palette.textTertiary)
        }
    }

    private var readoutSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            SectionLabel(text: "This frame")
            HStack {
                VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                    Text("In front")
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                    Readout(
                        value: String(format: "%.1f px", model.preview.disparityNear),
                        size: Tokens.TypeScale.readout
                    )
                }
                Spacer()
                VStack(alignment: .trailing, spacing: Tokens.Space.xxs) {
                    Text("Behind")
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                    Readout(
                        value: String(format: "%.1f px", abs(model.preview.disparityFar)),
                        size: Tokens.TypeScale.readout
                    )
                }
            }
        }
    }

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: Tokens.Space.m) {
                customDisparityControl

                labelledSlider(
                    "Overscan",
                    value: tuning.overscan,
                    range: 0...0.10,
                    format: "%.1f%%",
                    display: conversion.tuning.overscan * 100
                )
                labelledSlider(
                    "Field of view",
                    value: tuning.horizontalFOVDegrees,
                    range: 30...120,
                    format: "%.1f deg",
                    display: conversion.tuning.horizontalFOVDegrees
                )
                labelledSlider(
                    "Baseline",
                    value: tuning.baselineMillimetres,
                    range: 5...80,
                    format: "%.1f mm",
                    display: conversion.tuning.baselineMillimetres
                )

                VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                    SectionLabel(text: "Model")
                    Text(CoreMLDepthEstimator.modelResourceName)
                        .font(Tokens.Font.monoCaption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                }
            }
            .padding(.top, Tokens.Space.s)
        } label: {
            SectionLabel(text: "Advanced")
        }
        .animation(Tokens.Motion.inspectorAnimation, value: showAdvanced)
    }

    private var customDisparityControl: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            HStack {
                SectionLabel(text: "Custom disparity")
                Spacer()
                Toggle("", isOn: Binding(
                    get: { conversion.tuning.customDisparityPercent != nil },
                    set: { isOn in
                        var updated = conversion.tuning
                        updated.customDisparityPercent = isOn
                            ? conversion.tuning.strength.scale * 100
                            : nil
                        model.updateTuning(updated, for: conversion)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Tokens.Palette.accent)
            }

            if let percent = conversion.tuning.customDisparityPercent {
                HStack {
                    Slider(
                        value: Binding(
                            get: { percent },
                            set: {
                                var updated = conversion.tuning
                                updated.customDisparityPercent = $0
                                model.updateTuning(updated, for: conversion)
                            }
                        ),
                        in: 0.2...5.0
                    )
                    .tint(Tokens.Palette.accent)
                    Readout(value: String(format: "%.2f%%", percent))
                        .font(Tokens.Font.monoCaption)
                        .frame(width: Tokens.Layout.percentColumn, alignment: .trailing)
                }
            }
        }
    }

    private func labelledSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String,
        display: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            HStack {
                SectionLabel(text: title)
                Spacer()
                Readout(value: String(format: format, display))
                    .font(Tokens.Font.monoCaption)
            }
            Slider(value: value, in: range)
                .tint(Tokens.Palette.accent)
        }
    }
}

/// One of the three strength presets.
struct StrengthChip: View {
    let strength: EngineTuning.Strength
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(strength.label)
                .font(Tokens.Font.body)
                .foregroundStyle(
                    isSelected ? Tokens.Palette.stage : Tokens.Palette.textSecondary
                )
                .frame(maxWidth: .infinity)
                .frame(height: Tokens.Layout.minTarget)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.control)
                        .fill(fill)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var fill: Color {
        if isSelected {
            return isHovering
                ? Tokens.Palette.accent.shiftedLightness(by: Tokens.StateShift.hover)
                : Tokens.Palette.accent
        }
        return isHovering ? Tokens.Palette.panelRaised : Tokens.Palette.controlFillQuiet
    }
}
