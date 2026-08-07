import SwiftUI
import UniformTypeIdentifiers

/// Phase 1 shell: one window, a drop target, a filename, a determinate progress
/// bar, and Reveal in Finder when it lands. Phase 3 replaces this with the
/// three pane layout from the design file.
struct RootView: View {
    @Bindable var model: AppModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: Tokens.Space.m) {
            if let banner = model.modelBanner {
                Text(banner)
                    .font(Tokens.Font.body)
                    .foregroundStyle(Tokens.Palette.error)
            }

            if model.conversions.isEmpty {
                dropZone
            } else {
                queue
                controls
            }
        }
        .padding(Tokens.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Palette.stage)
        .onDrop(of: AppModel.supportedTypes, isTargeted: $isTargeted) { providers in
            load(providers)
            return true
        }
    }

    private var dropZone: some View {
        VStack(spacing: Tokens.Space.s) {
            Text("Drop a movie here.")
                .font(Tokens.Font.headline)
                .foregroundStyle(Tokens.Palette.textPrimary)
            Text("Relief reads its depth and writes a spatial video your Vision Pro plays natively.")
                .font(Tokens.Font.body)
                .foregroundStyle(Tokens.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.panel)
                .strokeBorder(
                    isTargeted ? Tokens.Palette.accent : Tokens.Palette.hairline,
                    lineWidth: Tokens.Layout.focusRingWidth
                )
        )
    }

    private var queue: some View {
        VStack(spacing: Tokens.Space.xs) {
            ForEach(model.conversions) { conversion in
                row(conversion)
            }
        }
    }

    @ViewBuilder
    private func row(_ conversion: Conversion) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            HStack {
                Text(conversion.displayName)
                    .font(Tokens.Font.rowTitle)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                Spacer()
                statusLabel(conversion)
            }

            if case .converting(let fraction, _) = conversion.status {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(Tokens.Palette.accent)
            }

            if case .done(let url) = conversion.status {
                Button("Reveal in Finder") { model.reveal(url) }
                    .font(Tokens.Font.body)
            }
        }
        .padding(Tokens.Space.s)
        .background(Tokens.Palette.panel, in: RoundedRectangle(cornerRadius: Tokens.Radius.panel))
    }

    @ViewBuilder
    private func statusLabel(_ conversion: Conversion) -> some View {
        switch conversion.status {
        case .probing:
            Text("Reading")
                .font(Tokens.Font.monoCaption)
                .foregroundStyle(Tokens.Palette.textTertiary)
        case .ready:
            Text(conversion.probe?.displayDuration ?? "")
                .font(Tokens.Font.monoCaption)
                .foregroundStyle(Tokens.Palette.textSecondary)
        case .converting(let fraction, _):
            Text("\(Int(fraction * 100))%")
                .font(Tokens.Font.monoCaption)
                .foregroundStyle(Tokens.Palette.accent)
        case .done:
            Text("Done")
                .font(Tokens.Font.monoCaption)
                .foregroundStyle(Tokens.Palette.accent)
        case .failed(let message):
            Text(message)
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Palette.error)
                .lineLimit(2)
        }
    }

    private var controls: some View {
        HStack(spacing: Tokens.Space.s) {
            Button("Add") { openPanel() }
            Spacer()
            if model.isConverting {
                Button("Cancel") { model.cancelConversion() }
            } else {
                Button("Convert") { model.convertAllReady() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

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

#Preview {
    let model = AppModel()
    return RootView(model: model)
        .frame(width: 960, height: 600)
}
