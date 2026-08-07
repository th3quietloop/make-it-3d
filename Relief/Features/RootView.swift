import SwiftUI
import UniformTypeIdentifiers

/// Three panes: queue on the left, viewer in the centre, inspector on the
/// right. The viewer is the hero because judging depth is the one job.
struct RootView: View {
    @Bindable var model: AppModel
    @State private var isTargeted = false

    var body: some View {
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
        .background(Tokens.Palette.stage)
        .overlay(alignment: .bottomLeading) {
            // Toasts sit over the stage, above the scrubber, so they never
            // cover the picture being judged.
            ToastStack(center: model.toasts)
                .padding(Tokens.Space.m)
                .padding(.bottom, Tokens.Layout.paneHeaderHeight)
                .allowsHitTesting(!model.toasts.toasts.isEmpty)
        }
        .onDrop(of: AppModel.supportedTypes, isTargeted: $isTargeted) { providers in
            load(providers)
            return true
        }
        .toolbar { toolbarContent }
        .modifier(KeyboardMap(model: model))
    }

    // MARK: Panes

    private var panes: some View {
        HStack(spacing: 0) {
            if model.sidebarVisible {
                QueueSidebarView(model: model, isTargeted: isTargeted)
                    .frame(width: Tokens.Layout.sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Hairline(axis: .vertical)
            }

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

            if model.inspectorVisible, let selection = model.selection {
                Hairline(axis: .vertical)
                InspectorView(model: model, conversion: selection)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
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
                model.sidebarVisible.toggle()
            } label: {
                Label("Queue", systemImage: "sidebar.leading")
            }
            .help("Show or hide the queue")
        }

        ToolbarItem(placement: .navigation) {
            Button(action: openPanel) {
                Label("Add", systemImage: "plus")
            }
            .help("Add movies to the queue")
        }

        ToolbarItem(placement: .principal) {
            if model.selection != nil {
                PreviewModePicker(mode: $model.previewMode)
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                model.inspectorVisible.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the settings")
        }
    }

    // MARK: Import

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = AppModel.supportedTypes
        if panel.runModal() == .OK {
            model.add(urls: panel.urls)
        }
    }

    private func load(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.add(urls: [url]) }
            }
        }
    }
}

/// The keyboard map.
///
/// The bindings live in the menu bar (ReliefApp) so they are discoverable.
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
                Button("") { model.toggleWiggle() }
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
