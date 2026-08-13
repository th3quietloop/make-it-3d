import SwiftUI
import AppKit

/// The queue, in two parts: what is finished, and what is still to do.
///
/// They used to be one list. A converted file sat in a queue labelled "Queue"
/// wearing a Done chip, which says the work is still pending and finished at
/// the same time. Splitting them means the list you scan for "what do I send to
/// the headset" and the list you scan for "what is left" are different lists.
///
/// Finished sits on top on purpose. With the queue running unattended, the
/// state you come back to is a pile of results, and results are what you came
/// back for. During a run, Converting and Up Next stay above the scroll so a
/// long queue never hides either the live progress or the next promise.
struct QueueSidebarView: View {
    @Bindable var model: AppModel
    let isTargeted: Bool

    @State private var searchText = ""
    @State private var filter: QueueFilter = .all
    @State private var convertedExpanded = true
    @State private var dropTarget: QueueDropTarget?

    private var isReorderEnabled: Bool {
        filter == .all && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var pinnedActive: Conversion? {
        guard model.queueRunning else { return nil }
        return model.activeConversion
    }

    private var pinnedNext: Conversion? {
        guard model.queueRunning else { return nil }
        return model.nextWaitingConversion
    }

    private var pinnedIDs: Set<Conversion.ID> {
        Set([pinnedActive?.id, pinnedNext?.id].compactMap { $0 })
    }

    private var visibleFinished: [Conversion] {
        model.finished.filter { filter.includes($0, searchText: searchText) }
    }

    private var visibleWork: [Conversion] {
        model.upNext.filter {
            !pinnedIDs.contains($0.id) && filter.includes($0, searchText: searchText)
        }
    }

    private var failedCount: Int {
        model.conversions.reduce(into: 0) { count, conversion in
            if case .failed = conversion.status { count += 1 }
        }
    }

    private var hasVisibleScrollableRows: Bool {
        !visibleFinished.isEmpty || !visibleWork.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            QueueSidebarControls(searchText: $searchText, filter: $filter)
            Hairline()

            QueueRunSummary(
                summaryText: model.queueSummaryText,
                outputEstimateText: model.queueOutputEstimateText,
                phase: model.queuePhase,
                onPauseAfterCurrent: model.pauseAfterCurrent,
                onStopAfterCurrent: model.stopAfterCurrent,
                onResume: model.resumeQueue,
                onStopNow: model.stopNow
            )

            if pinnedActive != nil || pinnedNext != nil {
                Hairline()
                pinnedWork
            }

            Hairline()

            ScrollView {
                LazyVStack(spacing: 0) {
                    convertedSection
                    workSection

                    if !hasVisibleScrollableRows {
                        QueueEmptyResults(
                            hasSearch: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            filter: filter,
                            hasPinnedWork: !pinnedIDs.isEmpty
                        )
                    }
                }
                .padding(.top, Tokens.Space.xs)
                .padding(.bottom, Tokens.Space.m)
            }
            .scrollEdgeFade(top: true, bottom: true)
            .frame(maxHeight: .infinity)

            if let notice = model.priorityNotice {
                Hairline()
                QueuePriorityNotice(
                    content: notice,
                    onDismiss: model.dismissPriorityNotice
                )
            }

            Hairline()
            QueueStickyAddButton(action: model.chooseFiles)
        }
        .frame(minWidth: Tokens.Layout.sidebarMinWidth)
        .surfaceMaterial(.sidebar)
        .overlay(dragWake)
        .animation(Tokens.Motion.previewCrossfadeAnimation, value: isTargeted)
        // Finder keys, because this looks like a Finder list and anything that
        // looks like one is expected to behave like one.
        .onDeleteCommand { model.removeSelected() }
        // Focusable so Delete reaches the list, but without the system ring:
        // a 2pt accent outline around the entire sidebar reads as the drag
        // target state, which is a different message entirely.
        .focusable()
        .focusEffectDisabled()
        .onAppear {
            if model.queueRunning { convertedExpanded = false }
        }
        .onChange(of: model.queueRunning) { oldValue, newValue in
            if !oldValue && newValue {
                convertedExpanded = false
            }
        }
        .onChange(of: filter) { _, newValue in
            if newValue == .converted { convertedExpanded = true }
            if newValue != .all { dropTarget = nil }
        }
        .onChange(of: searchText) { _, newValue in
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                dropTarget = nil
            }
        }
    }

    @ViewBuilder
    private var pinnedWork: some View {
        VStack(spacing: 0) {
            if let active = pinnedActive {
                QueueSectionHeader(title: "Converting", count: 1)
                row(active, showsPosition: false, allowsDrag: false)
            }

            if let next = pinnedNext {
                QueueSectionHeader(title: "Up next", count: 1)
                if isReorderEnabled {
                    dropTargetView(.before(next.id))
                }
                row(next, showsPosition: true, allowsDrag: isReorderEnabled)
            }
        }
        .padding(.vertical, Tokens.Space.xxs)
    }

    @ViewBuilder
    private var convertedSection: some View {
        if !model.finished.isEmpty && (filter == .all || filter == .converted) {
            Section {
                if convertedExpanded {
                    ForEach(visibleFinished) { conversion in
                        row(conversion, showsPosition: false, allowsDrag: false)
                    }
                }
            } header: {
                QueueSectionHeader(
                    title: "Converted",
                    count: visibleFinished.count,
                    isExpanded: $convertedExpanded,
                    trailing: "Clear",
                    action: { model.clearFinished() }
                )
            }
        }
    }

    @ViewBuilder
    private var workSection: some View {
        if filter != .converted {
            Section {
                ForEach(visibleWork) { conversion in
                    QueueSidebarWorkItem(
                        model: model,
                        conversion,
                        isReorderEnabled: isReorderEnabled,
                        isDropTarget: dropTarget == .before(conversion.id),
                        onDropTargeted: { targeted in
                            updateDropTarget(.before(conversion.id), isTargeted: targeted)
                        },
                        onDrop: handleDrop,
                        onTap: { handleTap(conversion) }
                    )
                    .id(conversion.id)
                }

                if isReorderEnabled, !model.queuedWaiting.isEmpty {
                    dropTargetView(.end)
                }
            } header: {
                QueueSectionHeader(
                    title: filter == .failed ? "Failed" : "To convert",
                    count: visibleWork.count,
                    trailing: workHeaderActionTitle,
                    action: workHeaderAction
                )
            }
        }
    }

    private var workHeaderActionTitle: String? {
        if canRetryAll, filter == .failed || (filter == .all && model.selectedIDs.count < 2) {
            return "Retry all"
        }
        if model.selectedIDs.count > 1 { return "\(model.selectedIDs.count) selected" }
        return nil
    }

    private var workHeaderAction: (() -> Void)? {
        guard canRetryAll,
              filter == .failed || (filter == .all && model.selectedIDs.count < 2)
        else { return nil }
        return { model.retryAllFailed() }
    }

    private var canRetryAll: Bool {
        failedCount > 0 && model.queuePhase != .stopping
    }

    private var dragWake: some View {
        RoundedRectangle(cornerRadius: Tokens.Radius.panel, style: .continuous)
            .strokeBorder(
                isTargeted ? Tokens.Palette.accent : .clear,
                lineWidth: Tokens.Layout.focusRingWidth
            )
            .padding(Tokens.Space.xxs)
    }

    // MARK: Rows

    @ViewBuilder
    private func row(
        _ conversion: Conversion,
        showsPosition: Bool,
        allowsDrag: Bool
    ) -> some View {
        QueueSidebarRowHost(
            model: model,
            conversion: conversion,
            showsPosition: showsPosition,
            allowsDrag: allowsDrag,
            onTap: { handleTap(conversion) }
        )
        .id(conversion.id)
    }

    private func dropTargetView(_ target: QueueDropTarget) -> some View {
        QueueDropIndicator(isVisible: dropTarget == target)
            .dropDestination(for: QueueDragPayload.self) { payloads, _ in
                handleDrop(payloads, before: target.destinationID)
            } isTargeted: { isTargeted in
                updateDropTarget(target, isTargeted: isTargeted)
            }
    }

    private func handleDrop(_ payloads: [QueueDragPayload], before destinationID: UUID?) -> Bool {
        guard isReorderEnabled, let payload = payloads.first else { return false }
        model.reorderQueued(ids: payload.ids, before: destinationID)
        return true
    }

    private func updateDropTarget(_ target: QueueDropTarget, isTargeted: Bool) {
        if isTargeted {
            dropTarget = target
        } else if dropTarget == target {
            dropTarget = nil
        }
    }

    /// Finder click semantics. Shift takes the run, command picks and chooses,
    /// a plain click starts over.
    private func handleTap(_ conversion: Conversion) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) {
            model.extendSelection(to: conversion)
        } else if flags.contains(.command) {
            model.toggleSelection(conversion)
        } else {
            model.select(conversion)
        }
    }

}

/// Hosts the before-row drop affordance beside the row that owns its changing
/// eligibility. Keeping both inside this retained child prevents an early
/// probing state from permanently hiding the insertion target.
private struct QueueSidebarWorkItem: View {
    @Bindable var model: AppModel
    let conversion: Conversion
    let isReorderEnabled: Bool
    let isDropTarget: Bool
    let onDropTargeted: (Bool) -> Void
    let onDrop: ([QueueDragPayload], UUID?) -> Bool
    let onTap: () -> Void

    init(
        model: AppModel,
        _ conversion: Conversion,
        isReorderEnabled: Bool,
        isDropTarget: Bool,
        onDropTargeted: @escaping (Bool) -> Void,
        onDrop: @escaping ([QueueDragPayload], UUID?) -> Bool,
        onTap: @escaping () -> Void
    ) {
        self.model = model
        self.conversion = conversion
        self.isReorderEnabled = isReorderEnabled
        self.isDropTarget = isDropTarget
        self.onDropTargeted = onDropTargeted
        self.onDrop = onDrop
        self.onTap = onTap
    }

    var body: some View {
        let canMove = conversion.canMoveInQueue
        Group {
            if isReorderEnabled && canMove {
                QueueDropIndicator(isVisible: isDropTarget)
                    .dropDestination(for: QueueDragPayload.self) { payloads, _ in
                        onDrop(payloads, conversion.id)
                    } isTargeted: { targeted in
                        onDropTargeted(targeted)
                    }
            }

            QueueSidebarRowHost(
                model: model,
                conversion: conversion,
                showsPosition: true,
                allowsDrag: isReorderEnabled,
                onTap: onTap
            )
        }
    }
}

/// Owns every state-dependent part of a lazy row. SwiftUI may keep a
/// `LazyVStack` child with the same identity alive while probing and automatic
/// planning finish. Reading the conversion here gives that retained child its
/// own Observation dependency, so its badge, drag capability, and context menu
/// become ready together.
private struct QueueSidebarRowHost: View {
    @Bindable var model: AppModel
    let conversion: Conversion
    let showsPosition: Bool
    let allowsDrag: Bool
    let onTap: () -> Void

    var body: some View {
        let canMove = conversion.canMoveInQueue
        let priorityCandidates = model.priorityCandidates(for: conversion)
        let canSkip = model.canSkip(conversion)
        let canRetry = model.canRetry(conversion)
        let position = showsPosition ? model.queuePosition(for: conversion) : nil
        let queueRunning = model.queueRunning
        let canPrioritize = model.canPrioritize(priorityCandidates)
        let status = conversion.status
        let selectedCount = model.selectedIDs.count
        let isSelected = model.selectedIDs.contains(conversion.id)
        let dragIDs = priorityCandidates.isEmpty
            ? [conversion.id]
            : priorityCandidates.map(\.id)

        let content = QueueRow(
            conversion: conversion,
            position: position,
            isSkippedThisRun: model.isSkippedInCurrentRun(conversion),
            isSelected: isSelected,
            isFocused: conversion.id == model.selectionID,
            isMultiSelect: model.selectedIDs.count > 1
        )
        .onTapGesture(perform: onTap)
        .contextMenu {
            rowMenu(
                canMove: canMove,
                priorityCandidates: priorityCandidates,
                canSkip: canSkip,
                canRetry: canRetry,
                queueRunning: queueRunning,
                canPrioritize: canPrioritize,
                status: status,
                selectedCount: selectedCount,
                isSelected: isSelected
            )
        }
        .help(conversion.sourceURL.path)

        if allowsDrag && canMove {
            content.draggable(QueueDragPayload(ids: dragIDs))
        } else {
            content
        }
    }

    @ViewBuilder
    private func rowMenu(
        canMove: Bool,
        priorityCandidates: [Conversion],
        canSkip: Bool,
        canRetry: Bool,
        queueRunning: Bool,
        canPrioritize: Bool,
        status: Conversion.Status,
        selectedCount: Int,
        isSelected: Bool
    ) -> some View {
        if canMove {
            Button(
                QueuePriorityCopy.actionTitle(
                    count: priorityCandidates.count,
                    queueRunning: queueRunning
                )
            ) {
                model.prioritize(priorityCandidates)
            }
            .disabled(!canPrioritize)
        }

        if canSkip {
            Button(status.isConverting ? "Skip Current Video" : "Skip This Run") {
                model.skip(conversion)
            }
        }

        if canRetry {
            Button("Retry") { model.retry(conversion) }
        }

        if canMove || canSkip || canRetry {
            Divider()
        }
        if case .done(let url) = status {
            Button("Send to Vision Pro") { model.share(url) }
            Button("Show in Finder") { model.reveal(url) }
            Button("Convert this again") { model.reconvert(conversion) }
                .disabled(queueRunning)
            Divider()
        }
        if selectedCount > 1, isSelected {
            Button("Remove \(selectedCount) videos") { model.removeSelected() }
        } else {
            Button("Remove") { model.remove(conversion) }
                .disabled(status.isConverting)
        }
    }
}

/// A compact section header, with optional disclosure and trailing action.
struct QueueSectionHeader: View {
    let title: String
    let count: Int
    var isExpanded: Binding<Bool>?
    var trailing: String?
    var action: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Tokens.Space.xs) {
            if let isExpanded {
                Button {
                    withAnimation(Tokens.Motion.panelSpring) {
                        isExpanded.wrappedValue.toggle()
                    }
                } label: {
                    HStack(spacing: Tokens.Space.xs) {
                        Image(systemName: "chevron.right")
                            .font(Tokens.Font.caption)
                            .foregroundStyle(Tokens.Palette.textTertiary)
                            .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                        SectionLabel(text: title)
                        countLabel
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded.wrappedValue ? "Collapse \(title)" : "Expand \(title)")
            } else {
                SectionLabel(text: title)
                countLabel
            }

            Spacer()
            if let trailing {
                if let action {
                    Button(trailing, action: action)
                        .buttonStyle(.plain)
                        .font(Tokens.Font.caption)
                        .foregroundStyle(isHovering ? Tokens.Palette.accent : Tokens.Palette.textTertiary)
                } else {
                    Text(trailing)
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                }
            }
        }
        .padding(.horizontal, Tokens.Space.m)
        .frame(height: Tokens.Layout.sectionHeaderHeight)
        // No material. This sat on an already translucent vibrant sidebar, so
        // two blurs stacked and it read as a grey bar hovering over the rows
        // rather than a label belonging to them. The headers are no longer
        // pinned either: two short sections do not need sticky behaviour, and
        // unpinning is what removes the need for a background at all.
        .onHover { isHovering = $0 }
    }

    private var countLabel: some View {
        Text("\(count)")
            .font(Tokens.Font.monoCaption)
            .foregroundStyle(Tokens.Palette.textTertiary)
    }
}

struct QueueRow: View {
    let conversion: Conversion
    let position: QueuePosition?
    let isSkippedThisRun: Bool
    let isSelected: Bool
    /// The one row driving the stage. Distinct from selection, because a
    /// thirteen row selection still shows exactly one picture.
    let isFocused: Bool
    /// True when the user has more than one row selected.
    let isMultiSelect: Bool

    @State private var isHovering = false
    /// Drives the stereo fuse when a conversion lands.
    @State private var fuseAmount: CGFloat = 0

    var body: some View {
        HStack(spacing: Tokens.Space.s) {
            thumbnail

            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                title
                subtitle
            }

            Spacer(minLength: 0)

            if let position {
                QueuePositionBadge(position: position)
            }

            // The finished row's whole point is getting the file to the
            // headset, so the action lives on the row rather than three clicks
            // away in a context menu.
            if case .done(let url) = conversion.status, isHovering {
                SendGlyph(url: url)
            }
        }
        // Space.xs, not Space.s. The selection fill is inset by Space.xs, so
        // Space.s here put the thumbnail at 20pt while every label in the pane
        // sat at 16pt. Three different left edges in a 264pt column: 8 for the
        // fill, 20 for the row, 16 for the labels. Nothing lined up with
        // anything, which is a thing you feel before you can name it.
        .padding(.horizontal, Tokens.Space.xs)
        .padding(.vertical, Tokens.Space.xs)
        .frame(minHeight: Tokens.Layout.queueRowHeight)
        .background(background)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onChange(of: conversion.status) { _, new in
            if case .done = new { runStereoFuse() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: Title, with the signature moment

    @ViewBuilder
    private var title: some View {
        ZStack(alignment: .leading) {
            // The stereo fuse: on completion the title splits into a vermilion
            // and a cyan copy offset 2px, then fuses back to white. The
            // anaglyph identity, spent once, at the only moment that earns it.
            if fuseAmount > 0 {
                Text(conversion.displayName)
                    .foregroundStyle(Tokens.Palette.stereoL)
                    .offset(x: -Tokens.Motion.fuseOffset * fuseAmount)
                Text(conversion.displayName)
                    .foregroundStyle(Tokens.Palette.accent)
                    .offset(x: Tokens.Motion.fuseOffset * fuseAmount)
            }
            Text(conversion.displayName)
                .foregroundStyle(Tokens.Palette.textPrimary)
                .opacity(1 - fuseAmount)
        }
        .font(Tokens.Font.rowTitle)
        .lineLimit(1)
        .truncationMode(.middle)
    }

    private func runStereoFuse() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        fuseAmount = 1
        withAnimation(Tokens.Motion.fuseSpring) {
            fuseAmount = 0
        }
    }

    // MARK: Row furniture

    @ViewBuilder
    private var subtitle: some View {
        switch conversion.status {
        case .probing:
            // A skeleton, not the word "Reading". Text that says it is loading
            // is a spinner in prose.
            RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                .fill(Tokens.Palette.panelRaised)
                .frame(width: Tokens.Layout.durationColumn, height: Tokens.TypeScale.caption)
                .accessibilityLabel("Reading file")

        case .ready:
            HStack(spacing: Tokens.Space.xs) {
                Text(conversion.probe?.displayDuration ?? "")
                    .font(Tokens.Font.monoCaption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                if isSkippedThisRun {
                    Chip(text: "Skipped this run")
                } else if conversion.settingsChangedSinceExport {
                    Chip(text: "Settings changed")
                }
            }

        case .converting(let fraction, _):
            HStack(spacing: Tokens.Space.xs) {
                Text("\(Int(fraction * 100))%")
                    .font(Tokens.Font.monoCaption)
                    .foregroundStyle(Tokens.Palette.accent)
                    .contentTransition(.numericText())
                if let remaining = conversion.estimatedSecondsRemaining {
                    Text("\(AppModel.humanDuration(remaining)) left")
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                }
            }

        case .done:
            HStack(spacing: Tokens.Space.xs) {
                if isSkippedThisRun {
                    Chip(text: "Skipped this run")
                } else {
                    Text("Ready to send")
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                }
                if conversion.settingsChangedSinceExport, !isSkippedThisRun {
                    Chip(text: "Settings changed")
                }
            }

        case .failed(let message):
            // The reason lives on the row that failed. It used to live only in
            // the inspector of whichever row happened to be selected, so a
            // queue of failures was a queue of red chips with no explanation.
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                Chip(text: "Couldn't convert", tone: .error)
                Text(message)
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Palette.errorText)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.Radius.panel, style: .continuous)
                .fill(Tokens.Palette.panelRaised)

            if let image = conversion.thumbnail {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    // Aspect fill overflows its frame, so it has to be clipped
                    // to the thumbnail box before the corner radius is applied.
                    // Without this the image spills across the sidebar.
                    .frame(
                        width: Tokens.Layout.thumbnailSize,
                        height: Tokens.Layout.thumbnailSize
                    )
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.panel, style: .continuous))
                    // The thumbnail dims while its row converts.
                    .opacity(conversion.status.isConverting ? Tokens.StateShift.dimmed : 1)
            }

            if case .converting(let fraction, _) = conversion.status {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Tokens.Palette.accent, lineWidth: Tokens.Layout.progressRingWidth)
                    .rotationEffect(.degrees(-90))
                    .frame(width: Tokens.Layout.progressRing, height: Tokens.Layout.progressRing)
            }
        }
        .frame(width: Tokens.Layout.thumbnailSize, height: Tokens.Layout.thumbnailSize)
    }

    /// Selection, the way macOS draws it.
    ///
    /// There used to be a 2pt accent bar down the leading edge. That is the
    /// Bootstrap list-group pattern, and no Apple list has ever used it: Finder,
    /// Mail, Music and the Xcode navigator all encode selection as a filled
    /// rounded rectangle inset from the edges. The bar is gone.
    private var background: some View {
        RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
            .fill(fill)
            .overlay {
                // Fill says selected. The outline says which selected row is
                // the one on the stage, and that is only a question worth
                // answering when more than one is selected. On a single
                // selection it was a second signal for a state the fill had
                // already carried.
                if isFocused && isSelected && isMultiSelect {
                    RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                        .strokeBorder(Tokens.Palette.accent.opacity(0.55), lineWidth: Tokens.Layout.hairlineWidth)
                }
            }
            .padding(.horizontal, Tokens.Space.xs)
            .padding(.vertical, Tokens.Space.xxs)
    }

    private var fill: Color {
        if isSelected { return Tokens.Palette.selectionFill }
        if isHovering { return Tokens.Palette.panelRaised }
        return .clear
    }
}

/// A small share glyph that appears on a finished row when you point at it.
private struct SendGlyph: View {
    let url: URL

    @State private var anchor: NSView?

    var body: some View {
        Button {
            guard let anchor else { return }
            NSSharingServicePicker(items: [url])
                .show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .frame(width: Tokens.Layout.iconButton, height: Tokens.Layout.iconButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RowShareAnchor(view: $anchor))
        .help("Send to Vision Pro")
        .accessibilityLabel("Send to Vision Pro")
    }
}

private struct RowShareAnchor: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let anchor = NSView()
        DispatchQueue.main.async { view = anchor }
        return anchor
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

#Preview {
    QueueSidebarView(model: AppModel(), isTargeted: false)
        .frame(width: Tokens.Layout.sidebarWidth, height: 500)
        .environment(AppearanceSettings())
}
