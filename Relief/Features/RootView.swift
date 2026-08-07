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
                EmptyStateView(isTargeted: isTargeted, onBrowse: openPanel)
            } else {
                panes
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Palette.stage)
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
                QueueSidebarView(model: model)
                    .frame(width: Tokens.Layout.sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Hairline(axis: .vertical)
            }

            VStack(spacing: 0) {
                if let banner = model.modelBanner {
                    bannerView(banner)
                }
                if let selection = model.selection {
                    StageView(model: model, conversion: selection)
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
        .animation(Tokens.Motion.inspectorAnimation, value: model.inspectorVisible)
        .animation(Tokens.Motion.inspectorAnimation, value: model.sidebarVisible)
    }

    private func bannerView(_ text: String) -> some View {
        HStack(spacing: Tokens.Space.xs) {
            Text(text)
                .font(Tokens.Font.body)
                .foregroundStyle(Tokens.Palette.error)
            Spacer()
        }
        .padding(.horizontal, Tokens.Space.m)
        .padding(.vertical, Tokens.Space.xs)
        .background(Tokens.Palette.bannerFill)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.sidebarVisible.toggle()
            } label: {
                Label("Queue", systemImage: "sidebar.leading")
            }
            .help("Show or hide the queue")
        }

        ToolbarItem(placement: .primaryAction) {
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
            .help("Show or hide the inspector")
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

/// The keyboard map, wired as invisible buttons so the shortcuts work whether
/// or not the menu bar has focus. The menu commands in ReliefApp carry the same
/// bindings, which is what makes them discoverable.
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
                Button("") { model.step(frames: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { model.step(frames: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { model.step(seconds: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: .shift)
                Button("") { model.step(seconds: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: .shift)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }
}

#Preview {
    RootView(model: AppModel())
        .frame(width: 1200, height: 720)
}
