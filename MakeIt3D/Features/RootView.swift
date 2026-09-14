import SwiftUI
import UniformTypeIdentifiers

/// Three panes: queue on the left, viewer in the centre, inspector on the
/// right. The viewer is the hero because judging depth is the one job.
struct RootView: View {
    @Bindable var model: AppModel
    @State private var isTargeted = false
    @State private var showingActivity = false
    @State private var focusViewing = false
    @State private var previousSidebar = true
    @State private var previousInspector = true
    @State private var automaticSidebar = true

    var body: some View {
        VStack(spacing: 0) {
            workspaceNotice
            Group {
                if model.conversions.isEmpty {
                    EmptyStateView(
                        isTargeted: isTargeted,
                        onBrowse: openPanel,
                        onSample: { model.startGuidedTour() },
                        isFirstRun: !model.onboarding.isComplete
                    )
                } else {
                    panes
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.toasts.currentMessage != nil {
                Hairline()
                ToastRail(center: model.toasts) { showingActivity = true }
            }
        }
        .background(WindowVibrancy())
        .sheet(isPresented: $showingActivity) { ActivityHistoryView(center: model.toasts) }
        .sheet(isPresented: $model.workspace.reviewPresented) {
            if let selection = model.selection, let plan = selection.shotPlan {
                ShotReviewSheet(sourceURL: selection.sourceURL, plan: plan) { seconds in
                    model.scrub(to: seconds)
                    model.workspace.reviewPresented = false
                }
            }
        }
        .onAppear {
            if model.workspace.restoredNotice != nil { automaticSidebar = false }
            else if automaticSidebar && model.conversions.count <= 1 { model.sidebarVisible = false }
        }
        .onChange(of: model.conversions.count) { oldCount, newCount in
            guard automaticSidebar, !focusViewing else { return }
            if newCount <= 1 { model.sidebarVisible = false }
            else if oldCount <= 1 { model.sidebarVisible = true }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls: urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .toolbar { toolbarContent }
        .modifier(KeyboardMap(model: model))
        .workspaceSheets(model: model)
    }

    @ViewBuilder private var workspaceNotice: some View {
        if let error = model.workspace.saveError {
            HStack(spacing: Tokens.Space.s) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Tokens.Palette.errorText)
                Text(error).font(Tokens.Font.caption).textSelection(.enabled)
                Spacer()
                Button("Save session as…") { model.saveSessionAs() }
            }
            .padding(.horizontal, Tokens.Space.m).padding(.vertical, Tokens.Space.xs)
            .background(Tokens.Palette.panelRaised)
        } else if let notice = model.workspace.restoredNotice {
            HStack(spacing: Tokens.Space.s) {
                Image(systemName: "arrow.counterclockwise").foregroundStyle(Tokens.Palette.textSecondary)
                Text(notice).font(Tokens.Font.caption)
                Spacer()
                Button { model.workspace.restoredNotice = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss workspace notice")
            }
            .padding(.horizontal, Tokens.Space.m).padding(.vertical, Tokens.Space.xs)
            .background(Tokens.Palette.panel)
        }
    }

    // MARK: Panes

    private var panes: some View {
        HSplitView {
            if model.sidebarVisible {
                QueueSidebarView(model: model, isTargeted: isTargeted)
                    .frame(minWidth: Tokens.Layout.sidebarMinWidth,
                           idealWidth: Tokens.Layout.sidebarWidth, maxWidth: 336)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                if let banner = model.modelBanner {
                    bannerView(banner)
                }
                if let selection = model.selection {
                    StageView(model: model, conversion: selection, isTargeted: isTargeted)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity)
            // The stage is the one region that stays opaque. Depth is judged
            // against a dead field, not against the desktop.
            .background(Tokens.Palette.stage)

            if model.inspectorVisible, let selection = model.selection {
                Hairline(axis: .vertical).background(Tokens.Palette.stage)
                InspectorView(model: model, conversion: selection)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        }
        // Springs, not fixed durations: grabbing the toggle twice in a row now
        // animates from wherever the pane currently is instead of snapping to
        // the target and jumping.
        .animation(Tokens.Motion.panelSpring, value: model.inspectorVisible)
        .animation(Tokens.Motion.panelSpring, value: model.sidebarVisible)
    }

    /// A standing condition, not an event. Events go through toasts.
    private func bannerView(_ text: String) -> some View {
        HStack(spacing: Tokens.Space.xs) {
            Text(text)
                .font(Tokens.Font.body)
                .foregroundStyle(Tokens.Palette.errorText)
            Spacer()
        }
        .padding(.horizontal, Tokens.Space.m)
        .padding(.vertical, Tokens.Space.xs)
        .background(Tokens.Palette.bannerFill)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Add lives on the left, next to the queue it adds to, per the design
        // file. Proximity to what a control affects is the whole point.
        ToolbarItem(placement: .navigation) {
            Button {
                automaticSidebar = false
                model.sidebarVisible.toggle()
                focusViewing = false
            } label: {
                Label("Queue (\(model.conversions.count))", systemImage: "sidebar.leading")
            }
            .help("Show or hide the queue")
        }

        ToolbarItem(placement: .navigation) {
            Button(action: openPanel) {
                Label("Add", systemImage: "plus")
            }
            .help("Add videos to the queue")
        }

        ToolbarItem(placement: .principal) {
            if model.selection != nil {
                PreviewModePicker(mode: $model.previewMode)
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button { toggleViewingLayout() } label: {
                Label(focusViewing ? "Restore panels" : "Focus on video",
                      systemImage: focusViewing ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .help(focusViewing ? "Restore the previous panel layout" : "Enlarge the video and hide both panels")
            .disabled(model.selection == nil)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Export history…") { model.workspace.historyPresented = true }
                Button("Messages…") { showingActivity = true }
            } label: {
                Label("History", systemImage: model.toasts.pendingFailureCount > 0 ? "exclamationmark.bubble" : "clock.arrow.circlepath")
            } primaryAction: {
                model.workspace.historyPresented = true
            }
            .help("Open export history. The menu also contains messages and issues.")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                model.inspectorVisible.toggle()
                focusViewing = false
            } label: {
                Label("Adjust depth", systemImage: "slider.horizontal.3")
            }
            .help("Show or hide Adjust depth")
        }
    }

    private func toggleViewingLayout() {
        if focusViewing {
            model.sidebarVisible = previousSidebar
            model.inspectorVisible = previousInspector
        } else {
            previousSidebar = model.sidebarVisible
            previousInspector = model.inspectorVisible
            model.sidebarVisible = false
            model.inspectorVisible = false
        }
        focusViewing.toggle()
    }

    // MARK: Import

    private func openPanel() {
        model.chooseFiles()
    }
}

/// The keyboard map.
///
/// The bindings live in the menu bar (MakeIt3DApp) so they are discoverable.
/// These hidden buttons cover the unmodified keys, which menu items alone do
/// not reliably deliver while a control has focus. Arrow keys are deliberately
/// absent: they belong to whichever slider is focused, and stealing them made
/// Left mean two different things depending on where the user last clicked.
private struct KeyboardMap: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.background {
            VStack {
                ForEach(PreviewMode.allCases) { mode in
                    Button("") { model.previewMode = mode }
                        .keyboardShortcut(KeyEquivalent(mode.shortcut), modifiers: [])
                }
                Button("") {
                    if model.previewMode == .source || model.playback.isShowingProof { model.playback.togglePlayback() }
                    else { model.toggleWiggle() }
                }
                .keyboardShortcut(.space, modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }
}

#Preview {
    RootView(model: AppModel())
        .frame(width: 1200, height: 720)
}
