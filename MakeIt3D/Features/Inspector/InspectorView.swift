import SwiftUI

/// One decision, and a drawer for everyone else.
///
/// This pane used to show twenty one things at rest: two named controls, a
/// gauge, a nested disclosure, and the captions each of them needed in order to
/// be understandable. Every one of those was a question put to someone who came
/// here to watch a film, and the app can answer all of them better than a person
/// can by eye. Now it shows one decision, its result, a way in for anyone who
/// disagrees, and the commit.
///
/// The evidence did not disappear, it moved. The shot strip under the picture
/// says what the depth is doing across the film, in the place where you are
/// already looking. A panel is a worse place to prove something than the picture
/// itself.
///
/// The engine's language never appears. It thinks in convergence, disparity,
/// overscan and baseline; the terms of art live in tooltips for anyone who wants
/// them.
struct InspectorView: View {
    @Bindable var model: AppModel
    let conversion: Conversion

    @State private var showCustom = false
    @State private var showAdvanced = false
    @State private var showPlayback = false

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
                    autoSection
                    customSection
                }
                .padding(Tokens.Space.m)
            }
            .scrollEdgeFade()

            Spacer(minLength: 0)

            Hairline()
            actionStack
                .padding(Tokens.Space.m)
        }
        .frame(width: Tokens.Layout.inspectorWidth)
        .surfaceMaterial(.panel)
    }

    // MARK: Custom

    /// Everything that used to be at the top level, behind one door.
    ///
    /// One door, not two. Strength, balance and the old More controls list were
    /// three separate levels of disclosure, which is a filing cabinet rather
    /// than a design. Anyone opening this has already decided they disagree with
    /// Auto, and someone who disagrees wants the whole workbench, not another
    /// chevron.
    private var customSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            Button {
                withAnimation(Tokens.Motion.panelSpring) { showCustom.toggle() }
            } label: {
                HStack(spacing: Tokens.Space.xs) {
                    SectionLabel(text: "Custom")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                        .rotationEffect(.degrees(showCustom ? 90 : 0))
                }
                .contentShape(Rectangle())
                .frame(minHeight: Tokens.Layout.minTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Custom depth controls")
            .accessibilityValue(showCustom ? "Expanded" : "Collapsed")

            if showCustom {
                VStack(alignment: .leading, spacing: Tokens.Space.l) {
                    strengthSection
                    balanceSection

                    // The gauge belongs to the sliders, not to the panel. It is
                    // feedback for a control, and with the controls hidden it
                    // was a readout of a decision the user did not make.
                    if let reading = model.preview.reading {
                        DepthGauge(reading: reading)
                    }

                    advancedSection
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: Auto

    /// The button that means nobody has to understand any of the controls
    /// underneath it.
    ///
    /// It sits above them rather than below, because the intended order is
    /// press Auto, then adjust if you disagree, not fiddle with dials and
    /// discover afterwards that the app could have done it.
    private var autoSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            if let progress = conversion.planningProgress {
                working(progress)
            } else if let plan = conversion.shotPlan {
                verdict(plan)
            } else {
                invitation
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Tokens.Motion.panelSpring, value: conversion.shotPlan)
        .animation(Tokens.Motion.panelSpring, value: conversion.planningProgress != nil)
    }

    /// Nothing decided yet. One object, and room around it.
    private var invitation: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            Button {
                model.autoTune(conversion)
            } label: {
                HStack(spacing: Tokens.Space.xs) {
                    Image(systemName: "wand.and.stars")
                    Text("Set the depth for me")
                }
                .font(Tokens.Font.bodyMedium)
                .foregroundStyle(Tokens.Palette.stage)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .modifier(PrimaryActionSurface(isHovering: false, isPressed: false, isFocused: false))
            .pressable()
            .disabled(conversion.probe == nil)
            .help("Finds every cut and works out the best depth for each shot on its own.")

            Text("Finds every cut and picks the depth for each shot on its own.")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(Tokens.LineSpacing.labels(Tokens.TypeScale.caption))
        }
    }

    /// Thinking. The count is the interesting part, so it is the big thing.
    private func working(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            Text("\(Int(progress * 100))%")
                .font(Tokens.Font.monoReadout)
                .foregroundStyle(Tokens.Palette.textPrimary)
                .contentTransition(.numericText())
            ProgressView(value: progress)
                .tint(Tokens.Palette.accent)
            Text("Looking at every shot in the film.")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Palette.textSecondaryVibrant)
        }
    }

    /// Decided. This replaces the gauge: one sentence about the footage, one
    /// about comfort, and a quiet way to run it again.
    private func verdict(_ plan: ShotPlan) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            HStack(spacing: Tokens.Space.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Tokens.Palette.accent)
                Text(plan.shots.count == 1 ? "Depth set" : "Depth set for \(plan.shots.count) shots")
                    .font(Tokens.Font.bodyMedium)
                    .foregroundStyle(Tokens.Palette.textPrimary)
            }

            Text(plan.comfortNote)
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Palette.textSecondaryVibrant)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(Tokens.LineSpacing.labels(Tokens.TypeScale.caption))

            Button("Do it again") { model.autoTune(conversion) }
                .buttonStyle(.plain)
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Palette.accent)
                .pressable()
                .frame(minHeight: Tokens.Layout.minTarget, alignment: .leading)
        }
    }

    // MARK: Actions

    /// Fixed height in every state, so the primary control never moves under
    /// the pointer as a row changes status.
    private var actionStack: some View {
        VStack(spacing: Tokens.Space.xs) {
            switch conversion.status {
            case .done(let url) where !conversion.settingsChangedSinceExport:
                SendToHeadsetButton(url: url)
                HStack(spacing: Tokens.Space.m) {
                    Button("Show file") { model.reveal(url) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Tokens.Palette.textSecondaryVibrant)
                        .pressable()
                        .help("Reveal the converted file in the Finder.")
                    // Was "Convert again", which reads as the forward action
                    // on a screen where the forward action is a different
                    // movie. It said "again" and the user heard "next". The
                    // redo now names the file it would redo, and the way to a
                    // new one is Add more movies at the foot of the queue.
                    Button("Redo this one") { model.reconvert(conversion) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Tokens.Palette.textSecondaryVibrant)
                        .pressable()
                        .disabled(model.isConverting)
                        .help("Convert \(conversion.displayName) again and keep both files.")
                }
                .font(Tokens.Font.body)
                .frame(minHeight: Tokens.Layout.minTarget)

            default:
                ConvertButton(title: convertTitle, state: convertState) {
                    model.convertSelected()
                }
                if model.isConverting {
                    Button("Stop") { model.cancelConversion() }
                        .buttonStyle(.plain)
                        .font(Tokens.Font.body)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .pressable()
                        .frame(minHeight: Tokens.Layout.minTarget)
                } else if model.hasUnselectedWork {
                    // The primary button does what you picked. Doing the whole
                    // list is a real thing to want, so it gets its own control
                    // saying so, rather than being smuggled into the label of
                    // a button about the selection.
                    Button("Convert all \(model.readyToConvert.count) up next") {
                        model.convertAllReady()
                    }
                    .buttonStyle(.plain)
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Palette.accent)
                    .pressable()
                    .frame(minHeight: Tokens.Layout.minTarget)
                } else {
                    destinationNote
                }
            }
        }
        .frame(height: Tokens.Layout.actionStackHeight, alignment: .top)
    }

    /// Where the file will land, said before it lands rather than hidden in
    /// settings. This slot was an empty spacer holding the layout still.
    private var destinationNote: some View {
        Button {
            model.chooseOutputFolder()
        } label: {
            HStack(spacing: Tokens.Space.xxs) {
                Image(systemName: "folder")
                Text("Saves to \(model.outputFolder.lastPathComponent)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(Tokens.Font.caption)
            .foregroundStyle(Tokens.Palette.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pressable()
        .help("Change where converted files are saved.")
        .frame(minHeight: Tokens.Layout.minTarget)
    }

    /// The button names what it will convert, which is the selection.
    ///
    /// It used to count everything ready in the whole list, so one movie
    /// highlighted out of four read "Convert 4 movies". Selecting one thing and
    /// being offered an action on four is the kind of small lie that makes
    /// someone stop trusting the rest of the window.
    private var convertTitle: String {
        let count = model.selectedReady.count
        if model.isConverting { return "Converting" }
        if count > 1 { return "Convert \(count) movies" }
        return conversion.settingsChangedSinceExport ? "Convert with new settings" : "Convert"
    }

    private var convertState: ConvertButton.State {
        if model.isConverting {
            return .loading(fraction: model.queueProgress)
        }
        if case .failed = conversion.status { return .normal }
        if model.modelBanner != nil { return .disabled }
        if conversion.status.isReady || conversion.settingsChangedSinceExport { return .normal }
        return .disabled
    }

    // MARK: Strength

    private var strengthSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            SectionLabel(text: "Depth strength")

            // One segmented well rather than three loose buttons, so it reads
            // as a single decision with three answers.
            HStack(spacing: 0) {
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
            .padding(Tokens.Space.xxs / 2)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                    .fill(Tokens.Palette.controlFillQuiet)
            )

            // Was "How far apart the two eye views are pushed", which is the
            // mechanism. Nobody buying this owns a pair of eye views. Say what
            // changes on screen, and say the tradeoff, because more depth
            // reads as better right up until your eyes give out an hour in.
            Text("How much 3D. None of them crop the picture: stronger just pushes depth further, and tires your eyes faster.")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Depth balance

    /// Convergence, renamed for what it does. The engine calls it the point
    /// where nearness maps to zero disparity; a person calls it whether the
    /// picture comes at you or sits back.
    private var balanceSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            SectionLabel(text: "Depth balance")

            Slider(value: tuning.convergence, in: 0...1) {
                Text("Depth balance")
            }
            // The label stays for VoiceOver, but it is not drawn: on macOS a
            // Slider renders its label inline and it read as stray body text.
            .labelsHidden()
            .tint(Tokens.Palette.accent)
            .help("Convergence: where the screen plane sits, 0 to 1.")
            .accessibilityValue(balanceDescription)

            HStack {
                Text("Like a window")
                Spacer()
                Text("Reaches out")
            }
            .font(Tokens.Font.caption)
            .foregroundStyle(Tokens.Palette.textTertiary)

            // "Sits back" and "Comes forward" describe the picture. These
            // describe the experience, which is the thing being chosen between:
            // looking through a window at a scene, or having the scene lean
            // into the room with you.
            Text(balanceDescription)
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Says where the balance currently sits in words, so the control explains
    /// itself without a number the user has to interpret.
    private var balanceDescription: String {
        switch conversion.tuning.convergence {
        case ..<0.3: return "Most of the picture sits behind the screen."
        case ..<0.55: return "Balanced. Most of the picture sits at screen depth."
        case ..<0.8: return "More of the picture comes toward you."
        default: return "Nearly everything comes toward you. Easy to overdo."
        }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            // A plain row rather than a DisclosureGroup, because the group's
            // built in chevron indents its label and breaks the left rail that
            // every other section label aligns to.
            Button {
                withAnimation(Tokens.Motion.panelSpring) { showAdvanced.toggle() }
            } label: {
                // Chevron on the trailing edge, so the label stays flush with
                // every other section label. A leading chevron indents its own
                // label and breaks the left rail the rest of the pane aligns to.
                HStack(spacing: Tokens.Space.xs) {
                    SectionLabel(text: "More controls")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                }
                .contentShape(Rectangle())
                .frame(minHeight: Tokens.Layout.minTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More controls")
            .accessibilityValue(showAdvanced ? "Expanded" : "Collapsed")

            if showAdvanced {
                VStack(alignment: .leading, spacing: Tokens.Space.l) {
                    fineTuneControl
                    synthesisControl
                    gapFillingControl
                    edgeCleanupControl
                    playbackGroup
                    modelRow
                }
                .transition(.opacity)
            }
        }
    }

    /// Custom disparity percent, renamed. It is the same dial as the preset
    /// row, just continuous.
    private var fineTuneControl: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            HStack {
                SectionLabel(text: "Fine-tune strength")
                Spacer()
                Toggle("Fine-tune strength", isOn: Binding(
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
                .help("Set the strength by hand instead of using the presets.")
            }

            if let percent = conversion.tuning.customDisparityPercent {
                HStack(spacing: Tokens.Space.s) {
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
                    ) {
                        Text("Strength")
                    }
                    .labelsHidden()
                    .tint(Tokens.Palette.accent)
                    .accessibilityValue(String(format: "%.2f percent of frame width", percent))

                    Readout(value: String(format: "%.2f%%", percent))
                        .font(Tokens.Font.monoCaption)
                        .frame(width: Tokens.Layout.percentColumn, alignment: .trailing)
                }
                Text("Percentage of the picture's width. The presets are 1.0, 1.6, and 2.4.")
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Which eye gets rebuilt.
    ///
    /// This control cannot be understood without knowing that 3D from a flat
    /// film is invented rather than filmed, so the section says that first.
    /// "Eye rendering" as a bare label asked the reader to already know.
    private var synthesisControl: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            SectionLabel(text: "Where the patching goes")

            Text("Making 3D means inventing a second viewpoint. Moving things sideways uncovers areas the camera never saw, and those have to be patched.")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(Tokens.LineSpacing.labels(Tokens.TypeScale.caption))

            Picker("Where the patching goes", selection: Binding(
                get: { conversion.tuning.synthesis },
                set: {
                    var updated = conversion.tuning
                    updated.synthesis = $0
                    model.updateTuning(updated, for: conversion)
                }
            )) {
                ForEach(EngineTuning.Synthesis.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(conversion.tuning.synthesis.explanation)
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Whether gaps get filled from the background plate or smeared over.
    private var gapFillingControl: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            HStack {
                SectionLabel(text: "Rebuild hidden areas")
                Spacer()
                Toggle("Rebuild hidden areas", isOn: Binding(
                    get: { conversion.tuning.fillDisocclusions },
                    set: {
                        var updated = conversion.tuning
                        updated.fillDisocclusions = $0
                        model.updateTuning(updated, for: conversion)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Tokens.Palette.accent)
                .help("Disocclusion filling from a background plate.")
            }
            Text("Shifting the picture uncovers areas the camera never showed for that eye. Make It 3D fills them from earlier frames instead of stretching a neighbouring pixel across.")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(Tokens.LineSpacing.labels(Tokens.TypeScale.caption))
        }
    }

    /// Overscan, renamed. It hides the stretched edges the warp leaves behind,
    /// which is a thing you can see, unlike the word overscan.
    private var edgeCleanupControl: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            HStack {
                SectionLabel(text: "Edge cleanup")
                Spacer()
                Readout(value: String(format: "%.1f%%", conversion.tuning.overscan * 100))
                    .font(Tokens.Font.monoCaption)
            }
            Slider(value: tuning.overscan, in: 0...0.10) { Text("Edge cleanup") }
                .labelsHidden()
                .tint(Tokens.Palette.accent)
                .help("Overscan. Zooms in slightly so the stretched edges fall outside the frame.")
                .accessibilityValue(String(format: "%.1f percent", conversion.tuning.overscan * 100))
            Text("Crops in a little to hide stretching at the left and right edges.")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Field of view and baseline. These write metadata for the headset and
    /// change nothing about the conversion or the preview, so they are grouped
    /// apart and say so. A control next to a picture that does not change the
    /// picture teaches people that controls here are decorative.
    private var playbackGroup: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            Button {
                withAnimation(Tokens.Motion.panelSpring) { showPlayback.toggle() }
            } label: {
                HStack(spacing: Tokens.Space.xs) {
                    SectionLabel(text: "Headset playback")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                        .rotationEffect(.degrees(showPlayback ? 90 : 0))
                }
                .contentShape(Rectangle())
                .frame(minHeight: Tokens.Layout.minTarget)
            }
            .buttonStyle(.plain)
            .accessibilityValue(showPlayback ? "Expanded" : "Collapsed")

            if showPlayback {
                VStack(alignment: .leading, spacing: Tokens.Space.m) {
                    Text("Written into the file for the Vision Pro to read. These do not change the conversion or the preview.")
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(Tokens.LineSpacing.labels(Tokens.TypeScale.caption))

                    labelledSlider(
                        "Viewing angle",
                        value: tuning.horizontalFOVDegrees,
                        range: 30...120,
                        format: "%.1f deg",
                        display: conversion.tuning.horizontalFOVDegrees,
                        help: "Horizontal field of view, in degrees."
                    )
                    labelledSlider(
                        "Eye spacing",
                        value: tuning.baselineMillimetres,
                        range: 5...80,
                        format: "%.1f mm",
                        display: conversion.tuning.baselineMillimetres,
                        help: "Stereo camera baseline, in millimetres."
                    )
                }
                .transition(.opacity)
            }
        }
    }

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            SectionLabel(text: "Depth reading")

            if VideoDepthEstimator.isAvailable {
                Picker("Depth reading", selection: Binding(
                    get: { conversion.tuning.depthModel },
                    set: {
                        var updated = conversion.tuning
                        updated.depthModel = $0
                        model.updateTuning(updated, for: conversion)
                    }
                )) {
                    ForEach(EngineTuning.DepthModel.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(conversion.tuning.depthModel.explanation)
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(Tokens.LineSpacing.labels(Tokens.TypeScale.caption))
            } else {
                Text(CoreMLDepthEstimator.modelResourceName)
                    .font(Tokens.Font.monoCaption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func labelledSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String,
        display: Double,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            HStack {
                SectionLabel(text: title)
                Spacer()
                Readout(value: String(format: format, display))
                    .font(Tokens.Font.monoCaption)
            }
            Slider(value: value, in: range) { Text(title) }
                .labelsHidden()
                .tint(Tokens.Palette.accent)
                .help(help)
                .accessibilityValue(String(format: format, display))
        }
    }
}

/// One of the three strength presets, inside the shared well.
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
                    RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                        .fill(fill)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pressable()
        .onHover { isHovering = $0 }
        .help(strength.explanation)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var fill: Color {
        if isSelected {
            return isHovering
                ? Tokens.Palette.accent.shiftedLightness(by: Tokens.StateShift.hover)
                : Tokens.Palette.accent
        }
        return isHovering ? Tokens.Palette.panelRaised : .clear
    }
}
