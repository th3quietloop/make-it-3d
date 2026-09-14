import SwiftUI
import CoreMedia

/// Keep the primary depth decisions beside the image. Technical cleanup and
/// headset metadata remain available without competing with those decisions.
struct InspectorView: View {
    @Bindable var model: AppModel
    let conversion: Conversion

    @State private var showAdvanced = false
    @State private var showPlayback = false
    @State private var showVerification = false
    @State private var isHoveringDestination = false
    @State private var showVariantNaming = false
    @State private var variantName = ""
    @State private var proofDuration = 5.0
    @State private var automaticProof = false
    @State private var showBatchSettings = false
    @State private var copyDepth = true
    @State private var copyCleanup = false
    @State private var copyModel = false
    @State private var showDepthFeedback = false

    private var effectiveTuning: EngineTuning {
        conversion.effectiveTuning(at: CMTime(seconds: model.playhead, preferredTimescale: 600))
    }
    private var tuning: Binding<EngineTuning> {
        Binding(get: { effectiveTuning }, set: { model.updateTuning($0, for: conversion) })
    }
    private var editable: Bool { !conversion.sourceMissing && !conversion.status.isConverting && conversion.planningProgress == nil }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.l) {
                    statusSection
                    VStack(alignment: .leading, spacing: Tokens.Space.s) {
                        HStack {
                            Text("Adjust depth").font(Tokens.Font.rowTitle)
                            Spacer()
                            if model.hasDriftedFromAuto(conversion) {
                                Button("Reset") { model.returnToAutomatic(conversion) }
                                    .font(Tokens.Font.caption)
                                    .help("Restore automatic depth for the selected scope")
                            }
                        }
                        Picker("Adjustment scope", selection: $model.adjustmentScope) {
                            Text("This shot").tag(AdjustmentScope.shot)
                            Text("Whole video").tag(AdjustmentScope.video)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(conversion.shotPlan?.shots.isEmpty != false)
                        strengthSection
                        balanceSection
                        if let reading = model.preview.reading {
                            DisclosureGroup("Depth feedback", isExpanded: $showDepthFeedback) {
                                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                                    DepthGauge(reading: reading)
                                    Text("Estimated depth load. Check the proof on your headset for comfort.")
                                        .font(Tokens.Font.caption)
                                        .foregroundStyle(Tokens.Palette.textSecondary)
                                }.padding(.top, Tokens.Space.xs)
                            }.font(Tokens.Font.caption)
                        }
                        variantsSection
                        if model.selectedIDs.count > 1 {
                            Button("Copy settings to selected videos…") { showBatchSettings = true }
                                .font(Tokens.Font.caption)
                                .popover(isPresented: $showBatchSettings) { batchSettingsPanel }
                        }
                    }
                    .disabled(!editable)
                    Hairline()
                    proofSection
                    if conversion.shotPlan != nil {
                        Button { model.workspace.reviewPresented = true } label: {
                            Label("Review shots…", systemImage: "square.grid.2x2")
                        }.font(Tokens.Font.body)
                    }
                    advancedSection.disabled(!editable)
                    if let report = conversion.report { verificationSection(report) }
                }
                .padding(Tokens.Space.m)
            }
            .scrollEdgeFade()
            Hairline()
            actionStack.padding(Tokens.Space.m)
        }
        .frame(width: Tokens.Layout.inspectorWidth)
        .surfaceMaterial(.panel)
        .popover(isPresented: $showVariantNaming) {
            VStack(alignment: .leading, spacing: Tokens.Space.m) {
                Text("Save a depth variant").font(Tokens.Font.rowTitle)
                TextField("Name", text: $variantName)
                    .onSubmit(saveVariant)
                HStack {
                    Button("Cancel") { showVariantNaming = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save", action: saveVariant)
                        .disabled(variantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(Tokens.Space.l)
            .frame(width: 300)
        }
    }

    @ViewBuilder private var statusSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            HStack(spacing: Tokens.Space.xs) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(conversion.failureMessage == nil ? Tokens.Palette.accent : Tokens.Palette.errorText)
                Text(statusTitle).font(Tokens.Font.bodyMedium)
            }
            if let progress = conversion.planningProgress {
                ProgressView(value: progress).tint(Tokens.Palette.accent)
                Text(model.analysingID == conversion.id ? "Preparing depth · \(Int(progress * 100))%" : "Waiting to prepare depth")
                    .font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textSecondary)
                if model.analysingID == conversion.id, let estimate = model.learnedEstimate(for: conversion, analysis: true) {
                    Text("Estimate: " + AppModel.humanDuration(estimate.upperBound * (1 - progress)) + " left")
                        .font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textSecondary)
                }
            } else if let failure = conversion.failureMessage {
                Text(failure).font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.errorText)
            } else if let plan = conversion.shotPlan {
                Text(plan.shots.count == 1 ? "One shot, automatically prepared." : "\(plan.shots.count) shots, automatically prepared.")
                    .font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textSecondary)
            } else if conversion.status.isReady {
                Button("Prepare automatic depth") { model.autoTune(conversion) }
                    .buttonStyle(.link).font(Tokens.Font.caption)
            }
            if conversion.sourceMissing {
                Text(conversion.status.isDone ? "The original is unavailable. Your finished export is still here." : "Locate the original to continue.")
                    .font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textSecondary)
                Button("Locate source…") { model.locateSource(conversion) }
                    .buttonStyle(.link).font(Tokens.Font.caption)
            }
        }
    }
    private var statusTitle: String {
        if conversion.planningProgress != nil { return "Preparing your video" }
        switch conversion.status {
        case .probing: return "Reading your video"
        case .ready: return "Ready to inspect"
        case .converting: return "Converting your video"
        case .done: return conversion.settingsChangedSinceExport ? "New adjustments to export" : "Export ready"
        case .failed: return "Needs attention"
        }
    }
    private var statusSymbol: String {
        switch conversion.status {
        case .done: return conversion.settingsChangedSinceExport ? "slider.horizontal.3" : "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .converting, .probing: return "clock"
        case .ready: return "viewfinder"
        }
    }

    private var variantsSection: some View {
        HStack {
            Menu {
                Button("Reset scope to automatic") { model.returnToAutomatic(conversion) }
                ForEach(model.workspace.variants.filter { $0.sourceID == conversion.id }) { variant in
                    Button(variant.name) { model.applyVariant(variant) }
                }
                Divider()
                Button("Save current variant…") { variantName = ""; showVariantNaming = true }
                if model.workspace.variants.contains(where: { $0.sourceID == conversion.id }) {
                    Menu("Delete variant") {
                        ForEach(model.workspace.variants.filter { $0.sourceID == conversion.id }) { variant in
                            Button(variant.name, role: .destructive) { model.deleteVariant(variant) }
                        }
                    }
                }
            } label: { Label("Variants", systemImage: "square.stack") }
            .menuStyle(.borderlessButton)
            Spacer()
            Button("Save variant…") { variantName = ""; showVariantNaming = true }
                .font(Tokens.Font.caption)
        }
    }
    private func saveVariant() {
        let name = variantName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        model.saveVariant(name: name)
        showVariantNaming = false
    }

    private var proofSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            Text("Try a short proof").font(Tokens.Font.bodyMedium)
            Text("Export a few seconds from the playhead before converting the whole video.")
                .font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textSecondary)
            if let progress = model.workspace.proofProgress {
                ProgressView(value: progress).tint(Tokens.Palette.accent)
                HStack {
                    Text(model.workspace.proofLabel ?? "Making proof…").font(Tokens.Font.caption)
                    Spacer()
                    Button("Cancel") { model.cancelProof() }
                }
            } else {
                HStack(spacing: Tokens.Space.s) {
                    Text("Length").font(Tokens.Font.caption)
                    Picker("Proof length", selection: $proofDuration) {
                        Text("3s").tag(3.0)
                        Text("5s").tag(5.0)
                        Text("8s").tag(8.0)
                    }.labelsHidden().frame(width: 70)
                    Spacer(minLength: 0)
                    Toggle("Auto", isOn: $automaticProof)
                        .toggleStyle(.checkbox)
                        .help("Use automatic depth instead of the current draft")
                }
                Button { model.makeProof(duration: proofDuration, automatic: automaticProof) } label: {
                    Label("Create \(Int(proofDuration))-second proof", systemImage: "play.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(!editable || conversion.probe == nil || model.queueRunning)
            }
            if let error = model.workspace.proofError {
                Text(error).font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.errorText)
            }
        }
    }

    private func verificationSection(_ report: VerificationReport) -> some View {
        DisclosureGroup(isExpanded: $showVerification) {
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                ForEach(Array(report.checks.enumerated()), id: \.offset) { _, check in
                    HStack(alignment: .top, spacing: Tokens.Space.xs) {
                        Image(systemName: check.skipped ? "minus.circle" : check.passed ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(check.skipped ? Tokens.Palette.textSecondary : check.passed ? Tokens.Palette.accent : Tokens.Palette.errorText)
                        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                            Text(check.skipped ? "\(check.name) · Not checked" : check.name)
                                .font(Tokens.Font.caption.weight(.medium))
                            Text(check.detail).font(Tokens.Font.caption)
                                .foregroundStyle(Tokens.Palette.textSecondary).textSelection(.enabled)
                        }
                    }
                }
                Text("File checks do not replace a viewing check on your headset.")
                    .font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textSecondary)
            }.padding(.top, Tokens.Space.s)
        } label: {
            Label(report.passed ? "File checks passed" : "Review file checks",
                  systemImage: report.passed ? "checkmark.shield" : "exclamationmark.shield")
                .font(Tokens.Font.bodyMedium)
        }
    }

    private func tuningEditing(_ editing: Bool) {
        if editing { model.beginTuningEdit() } else { model.endTuningEdit() }
    }

    private func resetDepthParameter(strength: Bool) {
        model.resetDepthParameter(strength: strength, for: conversion)
    }

    private var batchSettingsPanel: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            Text("Copy settings").font(Tokens.Font.rowTitle)
            Text("From \(conversion.displayName) to the other selected videos. Active conversions stay unchanged.")
                .font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textSecondary)
            Toggle("Strength and balance", isOn: $copyDepth)
            Toggle("Edge cleanup and hidden areas", isOn: $copyCleanup)
            Toggle("Depth model", isOn: $copyModel)
            HStack {
                Button("Cancel") { showBatchSettings = false }
                Spacer()
                Button("Apply to selection") {
                    model.applySettingsToSelected(includeDepth: copyDepth, includeCleanup: copyCleanup, includeModel: copyModel)
                    showBatchSettings = false
                }.disabled(!copyDepth && !copyCleanup && !copyModel)
            }
        }
        .padding(Tokens.Space.l).frame(width: 320)
    }

    // MARK: Actions

    /// Fixed height in every state, so the primary control never moves under
    /// the pointer as a row changes status.
    private var actionStack: some View {
        VStack(spacing: Tokens.Space.xs) {
            switch conversion.status {
            case .done(let url) where !conversion.settingsChangedSinceExport:
                SendToHeadsetButton(url: url)
                if model.queueRunning {
                    queueControlMenu
                } else {
                    HStack(spacing: Tokens.Space.m) {
                        Button("Show file") { model.reveal(url) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Tokens.Palette.textSecondaryVibrant)
                            .pressable()
                            .help("Reveal the converted file in the Finder.")
                        // Was "Convert again", which reads as the forward action
                        // on a screen where the forward action is a different
                        // video. It said "again" and the user heard "next". The
                        // redo now names the file it would redo, and the way to a
                        // new one is Add more videos at the foot of the queue.
                        // Quieter than Show file. This one spends the conversion
                        // time again, and the two were sitting at equal weight.
                        Button("Redo this one") { model.reconvert(conversion) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Tokens.Palette.textTertiary)
                            .pressable()
                            .help("Convert \(conversion.displayName) again and keep both files.")
                            .disabled(conversion.sourceMissing)
                    }
                    .font(Tokens.Font.body)
                    .frame(minHeight: Tokens.Layout.minTarget)
                }

            case .failed:
                ConvertButton(
                    title: "Retry",
                    state: model.canRetry(conversion) ? .normal : .disabled
                ) {
                    model.retry(conversion)
                }
                .help("Retry \(conversion.displayName).")

                if model.queueRunning {
                    queueControlMenu
                } else if failedCount > 1 {
                    Button("Retry all \(failedCount) failed") { model.retryAllFailed() }
                        .buttonStyle(.plain)
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Palette.accent)
                        .pressable()
                        .frame(minHeight: Tokens.Layout.minTarget)
                }

            case .converting:
                ConvertButton(title: convertTitle, state: convertState) {}
                    .help("Current batch progress.")
                queueControlMenu

            default:
                // Return commits, the way every export dialog in the
                // reference set does. It was already bound in the menu bar and
                // never shown, which is a shortcut nobody discovers.
                ConvertButton(title: convertTitle, state: convertState) {
                    model.showExportPreflight(for: model.selectedReady)
                }
                .help("Review export details, then convert. Command Return.")
                if model.queueRunning {
                    queueControlMenu
                } else if model.hasUnselectedWork {
                    // The primary button does what you picked. Doing the whole
                    // list is a real thing to want, so it gets its own control
                    // saying so, rather than being smuggled into the label of
                    // a button about the selection.
                    Button("Convert all \(model.readyToConvert.count) up next") {
                        model.showExportPreflight(for: model.readyToConvert, scope: .allReadyIncludingAdditions)
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
        .frame(minHeight: Tokens.Layout.actionStackHeight, alignment: .top)
    }

    private var failedCount: Int {
        model.conversions.reduce(into: 0) { count, candidate in
            if case .failed = candidate.status { count += 1 }
        }
    }

    /// Queue control is a menu because Pause, stop-after, and stop-now are three
    /// materially different promises. One button labelled Stop made the most
    /// destructive one look like the only one.
    private var queueControlMenu: some View {
        Menu {
            switch model.queuePhase {
            case .running:
                Button("Pause After Current") { model.pauseAfterCurrent() }
                Button("Stop After Current") { model.stopAfterCurrent() }
                Divider()
                Button("Stop Now", role: .destructive) { model.stopNow() }

            case .pauseAfterCurrent:
                Button("Resume Queue") { model.resumeQueue() }
                Button("Stop After Current") { model.stopAfterCurrent() }
                Divider()
                Button("Stop Now", role: .destructive) { model.stopNow() }

            case .stopAfterCurrent:
                Button("Resume Queue") { model.resumeQueue() }
                Divider()
                Button("Stop Now", role: .destructive) { model.stopNow() }

            case .paused:
                Button("Resume Queue") { model.resumeQueue() }
                Divider()
                Button("Stop Now", role: .destructive) { model.stopNow() }

            case .stopping:
                Text("Finishing the current depth pass, then cleaning up")

            case .idle:
                EmptyView()
            }
        } label: {
            HStack(spacing: Tokens.Space.xs) {
                Image(systemName: queueControlIcon)
                Text(queueControlTitle)
            }
            .font(Tokens.Font.body)
            .foregroundStyle(Tokens.Palette.textSecondary)
            .frame(minHeight: Tokens.Layout.minTarget)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .disabled(model.queuePhase == .stopping)
        .help("Pause, resume, or stop the conversion queue.")
        .accessibilityLabel("Queue controls")
        .accessibilityValue(queueControlTitle)
    }

    private var queueControlTitle: String {
        switch model.queuePhase {
        case .running: "Queue controls"
        case .pauseAfterCurrent: "Pauses after current"
        case .stopAfterCurrent: "Stops after current"
        case .paused: "Queue paused"
        case .stopping: "Stopping after the current depth pass"
        case .idle: "Queue controls"
        }
    }

    private var queueControlIcon: String {
        switch model.queuePhase {
        case .running: "ellipsis.circle"
        case .pauseAfterCurrent, .paused: "pause.circle"
        case .stopAfterCurrent: "stop.circle"
        case .stopping: "hourglass.circle"
        case .idle: "ellipsis.circle"
        }
    }

    /// Where the file will land, said before it lands rather than hidden in
    /// settings. This slot was an empty spacer holding the layout still.
    private var destinationNote: some View {
        Button {
            model.chooseOutputFolder()
        } label: {
            // A row that changes a setting has to look like it can be pressed.
            // This was a folder glyph and grey text, which is how a caption is
            // drawn, so nobody would ever have found it.
            HStack(spacing: Tokens.Space.xxs) {
                Image(systemName: "folder")
                Text("Saves to \(model.outputFolder.lastPathComponent)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.right")
                    .font(.system(size: Tokens.TypeScale.caption - 2))
            }
            .font(Tokens.Font.caption)
            .foregroundStyle(isHoveringDestination ? Tokens.Palette.accent : Tokens.Palette.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pressable()
        .onHover { isHoveringDestination = $0 }
        .help("Change where converted files are saved.")
        .frame(minHeight: Tokens.Layout.minTarget)
    }

    /// The button names what it will convert, which is the selection.
    ///
    /// It used to count everything ready in the whole list, so one video
    /// highlighted out of four read "Convert 4 videos". Selecting one thing and
    /// being offered an action on four is the kind of small lie that makes
    /// someone stop trusting the rest of the window.
    private var convertTitle: String {
        let count = model.selectedReady.count
        if model.isConverting { return "Converting" }
        if count > 1 { return "Convert \(count) videos" }
        return conversion.settingsChangedSinceExport ? "Convert with new settings" : "Convert"
    }

    private var convertState: ConvertButton.State {
        if model.isConverting {
            return .loading(fraction: model.queueProgress)
        }
        if model.queuePhase != .idle { return .disabled }
        if case .failed = conversion.status { return .disabled }
        if model.modelBanner != nil { return .disabled }
        if !model.selectedReady.isEmpty { return .normal }
        return .disabled
    }

    // MARK: Strength

    private var strengthSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            HStack {
                SectionLabel(text: "Depth strength")
                Spacer()
                Button { resetDepthParameter(strength: true) } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.plain).help("Reset strength to automatic")
                    .accessibilityLabel("Reset strength to automatic")
            }

            // One segmented well rather than three loose buttons, so it reads
            // as a single decision with three answers.
            HStack(spacing: 0) {
                ForEach(EngineTuning.Strength.allCases) { strength in
                    StrengthChip(
                        strength: strength,
                        isSelected: abs(effectiveTuning.disparityScale - strength.scale) < 0.000001
                    ) {
                        var updated = effectiveTuning
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

            Slider(value: Binding(
                get: { effectiveTuning.disparityScale * 100 },
                set: { value in
                    var updated = effectiveTuning
                    updated.customDisparityPercent = value
                    model.updateTuning(updated, for: conversion)
                }
            ), in: 0.2...4.0, onEditingChanged: tuningEditing) { Text("Depth strength") }
            .labelsHidden().tint(Tokens.Palette.accent)
            .accessibilityValue(String(format: "%.2f percent of frame width", effectiveTuning.disparityScale * 100))
            HStack {
                Text("Gentle")
                Spacer()
                Text(String(format: "%.2f%%", effectiveTuning.disparityScale * 100)).monospacedDigit()
                Spacer()
                Text("Strong")
            }
            .font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textSecondary)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Depth balance

    /// Convergence, renamed for what it does. The engine calls it the point
    /// where nearness maps to zero disparity; a person calls it whether the
    /// picture comes at you or sits back.
    private var balanceSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            HStack {
                SectionLabel(text: "Depth balance")
                Spacer()
                Button { resetDepthParameter(strength: false) } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.plain).help("Reset balance to automatic")
                    .accessibilityLabel("Reset balance to automatic")
            }

            Slider(value: Binding(
                get: { 1 - effectiveTuning.convergence },
                set: { value in
                    var updated = effectiveTuning
                    updated.convergence = 1 - value
                    model.updateTuning(updated, for: conversion)
                }
            ), in: 0...1, onEditingChanged: tuningEditing) {
                Text("Depth balance")
            }
            // The label stays for VoiceOver, but it is not drawn: on macOS a
            // Slider renders its label inline and it read as stray body text.
            .labelsHidden()
            .tint(Tokens.Palette.accent)
            .help("Left places more depth behind the screen. Right brings more content toward you.")
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
        switch effectiveTuning.convergence {
        case ..<0.3: return "More of the picture reaches toward you. Use gently."
        case ..<0.55: return "Depth extends in front of and behind the screen."
        case ..<0.8: return "More of the picture sits behind the screen."
        default: return "Nearly all the picture sits behind the screen, like a window."
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
                    gapFillingControl
                    edgeCleanupControl
                    depthDetailControls
                    playbackGroup
                    modelRow
                }
                .transition(.opacity)
            }
        }
    }

    // The eye rendering picker used to live here. It chose whether both eyes
    // were rebuilt halfway or the left eye was left exactly as filmed. It is
    // gone, and the behaviour is permanently the second one.
    //
    // Explaining it honestly took three paragraphs about inventing a second
    // viewpoint and what happens to the areas the camera never saw. A control
    // that needs three paragraphs is not a control, it is a decision the app
    // failed to make. None of the reference tools expose their renderer.
    //
    // Keeping one eye untouched is the better default and it is measurable:
    // the brain fuses two views and leans on the sharper one, and the gaps in
    // the other eye are filled from real pixels in earlier frames rather than
    // invented, which the disocclusion check verifies at 0 unfilled pixels.

    /// Whether gaps get filled from the background plate or smeared over.
    private var gapFillingControl: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            HStack {
                SectionLabel(text: "Rebuild hidden areas")
                Spacer()
                Toggle("Rebuild hidden areas", isOn: Binding(
                    get: { effectiveTuning.fillDisocclusions },
                    set: {
                        var updated = effectiveTuning
                        updated.fillDisocclusions = $0
                        model.updateTuning(updated, for: conversion)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Tokens.Palette.accent)
                .help("Disocclusion filling from a background plate.")
            }
            Text("Shifting the picture uncovers areas the camera never showed for that eye. Available earlier frames help fill them; remaining gaps use nearby pixels. Inspect moving edges in a proof.")
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
                Readout(value: String(format: "%.1f%%", effectiveTuning.overscan * 100))
                    .font(Tokens.Font.monoCaption)
            }
            Slider(value: tuning.overscan, in: 0...0.10, onEditingChanged: tuningEditing) { Text("Edge cleanup") }
                .labelsHidden()
                .tint(Tokens.Palette.accent)
                .help("Overscan. Zooms in slightly so the stretched edges fall outside the frame.")
                .accessibilityValue(String(format: "%.1f percent", effectiveTuning.overscan * 100))
            Text("Crops in a little to hide stretching at the left and right edges.")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var depthDetailControls: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                labelledSlider("Edge detail cleanup", value: tuning.edgeRefinement, range: 0...1,
                               format: "%.2f", display: effectiveTuning.edgeRefinement,
                               help: "Softens abrupt depth changes along object edges. Inspect fine detail in a proof.")
                Text("Higher values reduce abrupt depth edges but can soften fine details.")
                    .font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textSecondary)
            }
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                labelledSlider("Moving subject stability", value: tuning.motionRejection, range: 0...1,
                               format: "%.2f", display: effectiveTuning.motionRejection,
                               help: "Uses less historical depth where the picture changes. Judge this in a moving proof.")
                Text("Higher values rely less on older depth around motion. Check for trailing edges and flicker in a proof.")
                    .font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textSecondary)
            }
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
                        display: effectiveTuning.horizontalFOVDegrees,
                        help: "Horizontal field of view, in degrees."
                    )
                    labelledSlider(
                        "Eye spacing",
                        value: tuning.baselineMillimetres,
                        range: 5...80,
                        format: "%.1f mm",
                        display: effectiveTuning.baselineMillimetres,
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
                    get: { effectiveTuning.depthModel },
                    set: {
                        var updated = effectiveTuning
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

                Text(effectiveTuning.depthModel.explanation)
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
            Slider(value: value, in: range, onEditingChanged: tuningEditing) { Text(title) }
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
