import SwiftUI

@main
struct ReliefApp: App {
    @State private var model = AppModel()

    init() {
        setvbuf(stdout, nil, _IOLBF, 0)
        // Headless gate. `Relief --selftest [clip ...]` converts the synthetic
        // clip, checks the stereo sign convention, prints the verification
        // report, and exits without ever showing a window.
        //
        // The run loop has to keep turning while this happens: AVFoundation
        // delivers plenty of its work through the main queue, so blocking the
        // main thread on a semaphore here would deadlock the very APIs the test
        // is exercising. Instead the work goes to a detached task and exit()
        // ends the process when it finishes.
        if CommandLine.arguments.contains("--makeicon") {
            exit(IconRenderer.runFromCommandLine() ? 0 : 1)
        }

        if SelfTest.shouldRun() {
            let writerProbeOnly = CommandLine.arguments.contains("--writerprobe")
            Task.detached {
                let passed = writerProbeOnly
                    ? await WriterProbe.run()
                    : await SelfTest.run()
                exit(passed ? 0 : 1)
            }
            RunLoop.main.run()
        }
    }

    var body: some Scene {
        Window("Relief", id: "main") {
            RootView(model: model)
                .frame(minWidth: 960, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .windowToolbarStyle(.unified)
        .commands { ReliefCommands(model: model) }

        Settings {
            SettingsView(model: model)
                .preferredColorScheme(.dark)
        }
    }
}

/// The keyboard map, in the menu bar, so every shortcut is discoverable rather
/// than folklore.
struct ReliefCommands: Commands {
    @Bindable var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add to Queue...") { addFiles() }
                .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("Convert Selected") { model.convertSelected() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.selection == nil || model.isConverting)

            Button("Convert All Ready") { model.convertAllReady() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(model.isConverting)

            Button("Cancel Conversion") { model.cancelConversion() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.isConverting)

            Divider()
            Button("Remove from Queue") { model.removeSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selection == nil)
        }

        CommandMenu("Preview") {
            ForEach(PreviewMode.allCases) { mode in
                Button(mode.label) { model.previewMode = mode }
                    .keyboardShortcut(KeyEquivalent(mode.shortcut), modifiers: [])
            }
            Divider()
            Button(model.preview.isWigglePlaying ? "Pause Wiggle" : "Play Wiggle") {
                model.toggleWiggle()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model.previewMode != .wiggle)

            Divider()
            Button("Step Back One Frame") { model.step(frames: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Step Forward One Frame") { model.step(frames: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Back One Second") { model.step(seconds: -1) }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
            Button("Forward One Second") { model.step(seconds: 1) }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
        }

        CommandGroup(after: .sidebar) {
            Button(model.inspectorVisible ? "Hide Inspector" : "Show Inspector") {
                model.inspectorVisible.toggle()
            }
            .keyboardShortcut("i", modifiers: .command)

            Button(model.sidebarVisible ? "Hide Queue" : "Show Queue") {
                model.sidebarVisible.toggle()
            }
            .keyboardShortcut("l", modifiers: [.command, .control])
        }

        CommandMenu("Debug") {
            Button("Convert Golden Set") { model.queueGoldenSet() }
            Button("Reveal Golden Set Folder") { model.revealGoldenSetFolder() }
            Divider()
            Button("Run Sign Convention Check") { model.runSignConventionCheck() }
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = AppModel.supportedTypes
        if panel.runModal() == .OK {
            model.add(urls: panel.urls)
        }
    }
}

/// Level 3 disclosure: where exports land and what they are called.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Output folder") {
                    HStack(spacing: Tokens.Space.xs) {
                        Text(model.outputFolder.lastPathComponent)
                            .font(Tokens.Font.body)
                            .foregroundStyle(Tokens.Palette.textSecondary)
                        Button("Choose...") { chooseFolder() }
                    }
                }

                LabeledContent("Filename") {
                    TextField("Pattern", text: $model.filenamePattern)
                        .font(Tokens.Font.mono)
                        .frame(width: 180)
                }

                Text("{name} is replaced with the source filename.")
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
            } header: {
                SectionLabel(text: "Export")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 200)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.outputFolder = url
        }
    }
}

#Preview {
    SettingsView(model: AppModel())
}
