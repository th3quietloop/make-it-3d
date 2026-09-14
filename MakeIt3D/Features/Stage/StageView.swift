import SwiftUI
import CoreMedia

/// Original playback and depth inspection share one timeline and one stage.
struct StageView: View {
    @Bindable var model: AppModel
    let conversion: Conversion
    let isTargeted: Bool
    @State private var showTimeEntry = false
    @State private var timeEntry = ""
    @State private var showShotReview = false
    @State private var showSampleCredit = false
    @State private var timelineWindowSeconds: Double = 0
    @State private var timelineWindowStart: Double = 0

    private var showingPlayer: Bool {
        model.playback.isShowingProof || (model.previewMode == .source && !model.preview.inspectionAtNativeSize && !model.preview.showReconstructionRisk)
    }
    private var duration: Double { max(conversion.probe?.duration.seconds ?? 1, 0.01) }
    private var visibleRange: ClosedRange<Double> {
        if model.playback.isShowingProof, model.playback.duration > 0 {
            let start = model.playback.proofSourceStartSeconds
            return start...max(start + model.playback.duration, start + 0.01)
        }
        return 0...duration
    }
    private var timelineRange: ClosedRange<Double> {
        PreviewTimelineWindow.range(within: visibleRange, requestedSpan: timelineWindowSeconds, start: timelineWindowStart)
    }

    var body: some View {
        VStack(spacing: 0) {
            inspectionHeader
            ZStack {
                Tokens.Palette.stage
                if showingPlayer {
                    PreviewPlayerSurface(player: model.playback.player,
                                         label: model.playback.isShowingProof ? "Converted proof playback" : "Original video playback")
                } else if let image = model.preview.displayed {
                    PreviewImageSurface(image: image, nativeSize: model.preview.inspectionAtNativeSize, label: stageDescription)
                } else {
                    loadingMessage
                }
                if isTargeted {
                    RoundedRectangle(cornerRadius: Tokens.Radius.panel)
                        .strokeBorder(Tokens.Palette.accent, lineWidth: Tokens.Layout.focusRingWidth)
                        .padding(Tokens.Space.xs)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            feedbackRow
            scrubber
            if let plan = conversion.shotPlan, plan.shots.count > 1 {
                ShotStrip(plan: plan, duration: duration, playhead: model.playhead, sourceURL: conversion.sourceURL) { seek($0) }
                    .padding(.horizontal, Tokens.Space.m)
                    .padding(.bottom, Tokens.Space.s)
            }
        }
        .background(Tokens.Palette.stage)
        .onAppear { preparePlayback() }
        .onChange(of: conversion.id) { _, _ in preparePlayback() }
        .onChange(of: model.playhead) { _, seconds in
            if timelineWindowSeconds > 0, !timelineRange.contains(seconds) { centerTimeline() }
        }
        .onChange(of: visibleRange) { _, _ in centerTimeline() }
        .onChange(of: model.previewMode) { _, mode in
            if mode != .source { model.playback.stop() }
            if model.playback.isShowingProof { model.playback.showOriginal(at: model.playhead) }
            if mode == .source {
                model.preview.comparison = .draft
                model.preview.showReconstructionRisk = false
            }
        }
        .onDisappear { model.playback.stop() }
        .sheet(isPresented: $showShotReview) {
            if let plan = conversion.shotPlan {
                ShotReviewSheet(sourceURL: conversion.sourceURL, plan: plan) { seconds in
                    seek(seconds)
                    showShotReview = false
                }
            }
        }
    }

    private var inspectionHeader: some View {
        VStack(spacing: Tokens.Space.xs) {
            HStack(spacing: Tokens.Space.s) {
                Text(stageTitle)
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Palette.textSecondaryVibrant)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Tokens.Space.xs)
                if model.playback.activeProofURL != nil {
                    Menu("Compare proof") {
                        Button("Original at this moment") {
                            model.playback.showOriginal(at: model.playhead)
                            model.previewMode = .source
                        }
                        Button("Converted proof") { model.playback.showProof(at: model.playhead) }
                        Divider()
                        Toggle("Loop proof", isOn: $model.playback.loopProof)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Menu {
                    Toggle("Actual size (100%)", isOn: Binding(
                        get: { !showingPlayer && model.preview.inspectionAtNativeSize },
                        set: { value in
                            model.playback.stop()
                            if model.playback.isShowingProof { model.playback.showOriginal(at: model.playhead) }
                            model.preview.inspectionAtNativeSize = value
                        }
                    ))
                    .help("One source pixel per screen pixel. Scroll to inspect the full-resolution image.")
                    Toggle("Reconstruction risk", isOn: Binding(
                        get: { model.preview.showReconstructionRisk },
                        set: { value in
                            model.playback.stop()
                            model.preview.isWigglePlaying = false
                            model.preview.showReconstructionRisk = value
                        }
                    ))
                        .disabled(model.playback.isShowingProof)
                    Divider()
                    Button("Review shots…") { showShotReview = true }
                        .disabled(conversion.shotPlan?.isEmpty ?? true)
                } label: {
                    Label(!showingPlayer && model.preview.inspectionAtNativeSize ? "100%" : "Inspect", systemImage: "viewfinder")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if !showingPlayer, model.previewMode != .source {
                Picker("Compare settings at the same frame", selection: $model.preview.comparison) {
                    ForEach(PreviewComparison.allCases) { comparison in
                        Text(comparison.label).tag(comparison)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 380)
                .help("Switch settings without moving the playhead or the inspected crop.")
                Text(conversion.tuning.depthModel == .video
                     ? "Still frame uses Normal depth · render a proof to check Steady"
                     : "Still frame · same time and crop")
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Palette.textSecondaryVibrant)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, Tokens.Space.m)
        .padding(.vertical, Tokens.Space.xs)
    }

    private var stageTitle: String {
        if model.playback.isShowingProof { return "\(model.workspace.proofLabel ?? "Converted proof") · output" }
        if showingPlayer { return "Original video" }
        if model.preview.showReconstructionRisk { return "Reconstruction risk · amber marks abrupt depth changes" }
        if model.preview.comparison == .original { return "Original · matching frame and crop" }
        if model.previewMode == .wiggle {
            return "\(model.preview.comparison.label) · \(model.preview.showingLeft ? "left" : "right") eye"
        }
        return model.previewMode.label
    }

    private var stageDescription: String {
        "\(stageTitle), \(conversion.displayName) at \(PreviewNavigation.timecode(model.preview.displayedSeconds ?? model.playhead))"
    }

    private var loadingMessage: some View {
        VStack(spacing: Tokens.Space.xs) {
            if model.preview.errorMessage == nil { ProgressView().controlSize(.small) }
            Text(model.preview.errorMessage ?? (model.preview.isWarmingUp ? "Preparing the depth engine" : "Loading this frame"))
                .font(Tokens.Font.body)
                .foregroundStyle(Tokens.Palette.textSecondaryVibrant)
                .multilineTextAlignment(.center)
            if model.preview.errorMessage != nil {
                Button("View original") { model.previewMode = .source }
            }
        }
        .padding(Tokens.Space.l)
    }

    private var feedbackRow: some View {
        HStack(spacing: Tokens.Space.xs) {
            if let error = showingPlayer ? model.playback.errorMessage : model.preview.errorMessage {
                Image(systemName: "exclamationmark.triangle")
                Text(error).lineLimit(2)
                Button("Try again") {
                    if showingPlayer { model.playback.seek(seconds: model.playhead); model.playback.play() }
                    else { model.refreshPreview(frameChanged: true) }
                }
            } else if !showingPlayer, model.preview.isRendering {
                ProgressView().controlSize(.mini)
                Text(model.preview.isWarmingUp ? "Preparing depth…" : "Updating preview…")
                if let actual = model.preview.displayedSeconds {
                    Text("Showing \(PreviewNavigation.timecode(actual))")
                }
            } else if !showingPlayer, !model.preview.isExactPreview {
                Text("Approximate frame")
            } else if model.playback.isShowingProof && model.workspace.proofStale {
                Text("Settings changed ·")
                Button("Create a new proof") { model.makeProof() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.Palette.accent)
                    .disabled(model.workspace.proofProgress != nil)
            } else if model.playback.isShowingProof {
                Text("Converted excerpt · 2D eye view on this Mac. Send it to check spatial depth.")
            } else if model.preview.showReconstructionRisk {
                Text("A guide to edges worth inspecting; it does not measure the finished reconstruction.")
            } else if model.previewMode == .stereo {
                Text("Use red-cyan glasses. This display is an anaglyph preview.")
            } else if model.previewMode == .depth {
                Text("Lighter areas are estimated to be nearer.")
            } else if model.previewMode == .wiggle {
                Text(model.preview.reduceMotion ? "Reduce Motion is on. Use the eye controls for a still comparison." : "Compare the still eye views, or choose Alternate eyes to see the shift.")
            } else {
                Text("Original file · normal video and audio playback")
            }
            Spacer(minLength: 0)
            if SampleClipSource.isSample(conversion.sourceURL) {
                Button("Sample credit") { showSampleCredit = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.Palette.accent)
                    .popover(isPresented: $showSampleCredit) {
                        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                            Text(SampleClipSource.title).font(Tokens.Font.bodyMedium)
                            Text(SampleClipSource.credit).font(Tokens.Font.caption)
                            Text("Six-second excerpt, resized and transcoded for this sample.")
                                .font(Tokens.Font.caption).foregroundStyle(.secondary)
                            Button("Try the depth lesson") {
                                showSampleCredit = false
                                model.demonstrateDepth()
                            }
                            Link(SampleClipSource.license, destination: SampleClipSource.licenseURL)
                            Link("Film and attribution", destination: SampleClipSource.sourceURL)
                        }
                        .padding(Tokens.Space.m)
                        .frame(width: 340)
                    }
            }
        }
        .font(Tokens.Font.caption)
        .foregroundStyle(Tokens.Palette.textSecondaryVibrant)
        .frame(minHeight: 26, alignment: .leading)
        .padding(.horizontal, Tokens.Space.m)
    }

    private var scrubber: some View {
        VStack(spacing: Tokens.Space.xs) {
        if timelineWindowSeconds > 0 {
            PreviewTimelineWindow(plan: conversion.shotPlan, range: timelineRange, fullRange: visibleRange,
                                  playhead: model.playhead,
                                  onPrevious: { moveTimeline(-1) }, onNext: { moveTimeline(1) },
                                  onCenter: { centerTimeline() }, onSeek: seek)
        }
        HStack(spacing: Tokens.Space.xs) {
            Button(action: toggleTransport) {
                Image(systemName: transportPlaying ? "pause.fill" : "play.fill")
                    .frame(width: Tokens.Layout.minTarget, height: Tokens.Layout.minTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(transportLabel)
            .help(transportLabel + ". Space.")
            .disabled(model.previewMode == .wiggle && !showingPlayer && (model.preview.reduceMotion || model.preview.showReconstructionRisk || model.preview.comparison == .original))

            if model.previewMode == .wiggle && !showingPlayer && model.preview.comparison != .original {
                Button(model.preview.showingLeft ? "Left eye" : "Right eye") { model.preview.flipEye() }
                    .font(Tokens.Font.caption)
                    .fixedSize()
                    .help("Show the other eye without moving the playhead.")
                    .disabled(model.preview.showReconstructionRisk)
            }

            Button {
                timeEntry = PreviewNavigation.timecode(model.playhead)
                showTimeEntry = true
            } label: {
                Text(PreviewNavigation.timecode(model.playhead))
                    .font(Tokens.Font.monoCaption)
                    .monospacedDigit()
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .help("Go to an exact time.")
            .popover(isPresented: $showTimeEntry) { timeEntryForm }

            Slider(value: Binding(
                get: { min(max(model.playhead, timelineRange.lowerBound), timelineRange.upperBound) },
                set: { seek($0) }
            ), in: timelineRange) { Text("Playhead") }
                .labelsHidden()
                .tint(Tokens.Palette.accent)
                .accessibilityValue(PreviewNavigation.timecode(model.playhead))
                .frame(minWidth: 40)

            Text(Timecode.string(from: timelineRange.upperBound))
                .font(Tokens.Font.monoCaption)
                .foregroundStyle(Tokens.Palette.textSecondaryVibrant)
                .fixedSize()

            Menu {
                Button("Bookmark this moment") { model.toggleBookmark() }
                Menu("Timeline zoom") {
                    ForEach([0.0, 30.0, 10.0, 2.0], id: \.self) { seconds in
                        Button {
                            timelineWindowSeconds = seconds
                            centerTimeline()
                        } label: {
                            if timelineWindowSeconds == seconds {
                                Label(seconds == 0 ? "Whole video" : "\(Int(seconds))-second window", systemImage: "checkmark")
                            } else {
                                Text(seconds == 0 ? "Whole video" : "\(Int(seconds))-second window")
                            }
                        }
                    }
                }
                if !conversion.bookmarks.isEmpty {
                    Divider()
                    ForEach(conversion.bookmarks.sorted(), id: \.self) { seconds in
                        Button(PreviewNavigation.timecode(seconds)) { seek(seconds) }
                    }
                }
                if let plan = conversion.shotPlan, plan.shots.count > 1 {
                    Divider()
                    Button("Previous shot") {
                        if let seconds = PreviewNavigation.previousShot(in: plan, at: model.playhead) { seek(seconds) }
                    }
                    Button("Next shot") {
                        if let seconds = PreviewNavigation.nextShot(in: plan, at: model.playhead) { seek(seconds) }
                    }
                    Button("Review shots…") { showShotReview = true }
                }
            } label: { Image(systemName: "bookmark") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Bookmarks, timeline zoom, and exact shot navigation.")
                .accessibilityLabel("Bookmarks, timeline zoom, and shots")
        }
        }
        .padding(Tokens.Space.s)
        .surfaceMaterial(.floating)
        .clipShape(.rect(cornerRadius: Tokens.Radius.panel))
        .padding(Tokens.Space.m)
    }

    private var timeEntryForm: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            Text("Go to time").font(Tokens.Font.bodyMedium)
            TextField("0:00.000", text: $timeEntry)
                .font(Tokens.Font.mono)
                .onSubmit { commitTimeEntry() }
            Text("Seconds, m:ss.mmm, or h:mm:ss.mmm")
                .font(Tokens.Font.caption)
                .foregroundStyle(.secondary)
            Button("Go") { commitTimeEntry() }
                .keyboardShortcut(.defaultAction)
                .disabled(PreviewNavigation.seconds(from: timeEntry) == nil)
        }
        .padding(Tokens.Space.m)
        .frame(width: 270)
    }

    private var transportPlaying: Bool {
        model.previewMode == .wiggle && !showingPlayer ? model.preview.isWigglePlaying : model.playback.isPlaying
    }
    private var transportLabel: String {
        if model.previewMode == .wiggle && !showingPlayer {
            return model.preview.isWigglePlaying ? "Pause eye alternation" : "Alternate eyes"
        }
        return model.playback.isPlaying ? "Pause video" : (model.playback.isShowingProof ? "Play proof" : "Play original")
    }
    private func toggleTransport() {
        if model.previewMode == .wiggle && !showingPlayer { model.toggleWiggle(); return }
        if !model.playback.isShowingProof, model.previewMode != .source { model.previewMode = .source }
        model.preview.inspectionAtNativeSize = false
        model.preview.showReconstructionRisk = false
        model.playback.togglePlayback()
    }
    private func seek(_ seconds: Double) {
        model.playback.stop()
        model.preview.isWigglePlaying = false
        let value = min(max(seconds, 0), duration)
        model.scrub(to: value)
    }
    private func preparePlayback() {
        model.playback.updateSource(url: conversion.sourceURL)
        model.playback.seek(seconds: model.playhead)
        centerTimeline()
    }
    private func centerTimeline() {
        guard timelineWindowSeconds > 0 else { return }
        timelineWindowStart = model.playhead - timelineWindowSeconds / 2
    }
    private func moveTimeline(_ direction: Double) {
        timelineWindowStart = timelineRange.lowerBound + direction * (timelineRange.upperBound - timelineRange.lowerBound) * 0.8
        let range = timelineRange
        if !range.contains(model.playhead) {
            seek(min(max(model.playhead, range.lowerBound), range.upperBound))
        }
    }
    private func commitTimeEntry() {
        guard let seconds = PreviewNavigation.seconds(from: timeEntry) else { return }
        seek(seconds)
        showTimeEntry = false
    }
}

/// Two common views lead; specialist inspection stays one explicit choice away.
struct PreviewModePicker: View {
    @Binding var mode: PreviewMode
    var body: some View {
        HStack(spacing: Tokens.Space.xs) {
            Picker("Preview", selection: $mode) {
                Text("Original").tag(PreviewMode.source)
                Text("Compare eyes").tag(PreviewMode.wiggle)
                if mode == .depth || mode == .stereo {
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: mode == .depth || mode == .stereo ? 355 : 210)
            Menu {
                ForEach([PreviewMode.depth, .stereo]) { item in
                    Button(item.label) { mode = item }
                }
            } label: {
                Image(systemName: mode == .depth || mode == .stereo ? "slider.horizontal.3.circle.fill" : "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .help("Depth map and red-cyan glasses previews")
            .accessibilityLabel("Additional preview modes")
        }
    }
}
