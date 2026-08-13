import SwiftUI
import AppKit

@main
struct MakeIt3DApp: App {
    @State private var model = AppModel()
    @State private var appearance = AppearanceSettings()
    @NSApplicationDelegateAdaptor(MakeIt3DAppDelegate.self) private var appDelegate

    init() {
        setvbuf(stdout, nil, _IOLBF, 0)
        // Headless gate. `Make It 3D --selftest [clip ...]` converts the synthetic
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

        if DepthContentCheck.shouldRun() {
            Task.detached { exit(await DepthContentCheck.run() ? 0 : 1) }
            RunLoop.main.run()
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
        Window(windowTitle, id: "main") {
            RootView(model: model)
                .frame(minWidth: 960, minHeight: 600)
                .preferredColorScheme(.dark)
                .environment(appearance)
                .onAppear { appDelegate.model = model }
        }
        .windowToolbarStyle(.unified)
        .commands { MakeIt3DCommands(model: model) }

        Settings {
            SettingsView(model: model)
                .preferredColorScheme(.dark)
                .environment(appearance)
        }
    }

    /// Pro apps name the document they are working on. "Make It 3D" forever tells
    /// the user nothing in Mission Control or the window menu.
    private var windowTitle: String {
        guard let name = model.selection?.displayName else { return "Make It 3D" }
        return "\(name) (Make It 3D)"
    }
}

/// Guards the exit.
///
/// Quitting mid conversion used to discard hours of work silently. This is the
/// one place in Make It 3D where a confirmation dialog is the right call: the
/// action is genuinely destructive and genuinely irreversible.
final class MakeIt3DAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?

    @MainActor
    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let model, model.isConverting else { return .terminateNow }
        return model.confirmQuitWhileConverting() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in DockProgress.shared.fraction = nil }
    }

    /// Files opened from outside the app.
    ///
    /// This covers Open With, double clicking a video whose default app is this
    /// one, and dropping files on the Dock icon. Without it those three did
    /// nothing at all: the app came to the front and ignored the file, which
    /// reads as a hang rather than an unsupported gesture. Dragging onto the
    /// window, the file picker, and launch arguments all worked, so the gap was
    /// invisible from inside the app and obvious from the Finder.
    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model else { return }
        model.add(urls: urls)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The keyboard map, in the menu bar, so every shortcut is discoverable rather
/// than folklore.
struct MakeIt3DCommands: Commands {
    @Bindable var model: AppModel

    /// Names what Delete will actually take, so a thirteen row selection does
    /// not hide behind the word "Remove".
    private var removeTitle: String {
        model.selectedIDs.count > 1 ? "Remove \(model.selectedIDs.count) Videos" : "Remove Video"
    }

    private var canResumeQueue: Bool {
        model.queuePhase == .paused
            || model.queuePhase == .pauseAfterCurrent
            || model.queuePhase == .stopAfterCurrent
    }

    private var canStopAfterCurrent: Bool {
        model.queuePhase == .running || model.queuePhase == .pauseAfterCurrent
    }

    private var failedCount: Int {
        model.conversions.reduce(into: 0) { count, conversion in
            if case .failed = conversion.status { count += 1 }
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add to Queue...") { addFiles() }
                .keyboardShortcut("o", modifiers: .command)
        }

        // Finder keys for a Finder-shaped list. The queue reads as a list of
        // files, so the shortcuts people already have in their hands have to
        // work: select a run, select the lot, delete the selection.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Select All Videos") { model.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(model.conversions.isEmpty)

            Button(removeTitle) { model.removeSelected() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(model.selectedIDs.isEmpty)
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("Send to Vision Pro") {
                if case .done(let url)? = model.selection?.status { model.share(url) }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!(model.selection?.status.isDone ?? false))

            Button("Show in Finder") {
                if case .done(let url)? = model.selection?.status { model.reveal(url) }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!(model.selection?.status.isDone ?? false))

            Divider()
            Button("Remove from Queue") { model.removeSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selection == nil)
        }

        CommandMenu("Queue") {
            Button("Convert Selected") { model.convertSelected() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.selectedReady.isEmpty || model.queuePhase != .idle)

            Button("Convert All Ready") { model.convertAllReady() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(model.readyToConvert.isEmpty || model.queuePhase != .idle)

            Divider()

            Button("Prioritize Selected") { model.prioritizeSelection() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!model.canPrioritize(model.selectedPriorityCandidates))

            Button("Skip Focused Video") {
                if let selection = model.selection { model.skip(selection) }
            }
            .disabled(model.selection.map { !model.canSkip($0) } ?? true)

            Divider()

            Button("Pause After Current") { model.pauseAfterCurrent() }
                .disabled(model.queuePhase != .running)

            Button("Resume Queue") { model.resumeQueue() }
                .disabled(!canResumeQueue)

            Button("Stop After Current") { model.stopAfterCurrent() }
                .disabled(!canStopAfterCurrent)

            Button("Stop Now") { model.stopNow() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model.queuePhase == .idle || model.queuePhase == .stopping)

            Divider()

            Button("Retry Focused Video") {
                if let selection = model.selection { model.retry(selection) }
            }
            .disabled(model.selection.map { !model.canRetry($0) } ?? true)

            Button(failedCount > 1 ? "Retry All \(failedCount) Failed" : "Retry All Failed") {
                model.retryAllFailed()
            }
            .disabled(failedCount == 0 || model.queuePhase == .stopping)
        }

        CommandMenu("Preview") {
            ForEach(PreviewMode.allCases) { mode in
                Button(mode.label) { model.previewMode = mode }
                    .keyboardShortcut(KeyEquivalent(mode.shortcut), modifiers: [])
            }
            Divider()
            Button(model.preview.isWigglePlaying ? "Pause Alternating" : "Start Alternating") {
                model.toggleWiggle()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model.previewMode != .wiggle || model.preview.reduceMotion)

            Button("Show Other Eye") { model.preview.flipEye() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.previewMode != .wiggle)

            Divider()
            // Cmd modified, so they never fight a focused slider for the
            // unmodified arrow keys.
            Button("Step Back One Frame") { model.step(frames: -1) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Step Forward One Frame") { model.step(frames: 1) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Back One Second") { model.step(seconds: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            Button("Forward One Second") { model.step(seconds: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
        }

        CommandGroup(after: .sidebar) {
            Button(model.inspectorVisible ? "Hide Settings" : "Show Settings") {
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
            Divider()
            Button("Reset First Run") {
                model.onboarding.reset()
                model.toasts.info("First run reset", detail: "Empty the queue to see it.")
            }
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

    /// An empty or token free pattern would silently produce files that
    /// overwrite each other, so the field says so rather than accepting it.
    private var patternProblem: String? {
        let trimmed = model.filenamePattern.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Give the pattern a name." }
        if !trimmed.contains("{name}") {
            return "Without {name}, every export gets the same filename."
        }
        if trimmed.contains("/") { return "Slashes aren't allowed in a filename." }
        return nil
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Save to") {
                    HStack(spacing: Tokens.Space.xs) {
                        Text(model.outputFolder.lastPathComponent)
                            .font(Tokens.Font.body)
                            .foregroundStyle(Tokens.Palette.textSecondary)
                            .help(model.outputFolder.path)
                        Button("Choose...") { chooseFolder() }
                    }
                }

                LabeledContent("Name them") {
                    VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                        TextField("Pattern", text: $model.filenamePattern)
                            .font(Tokens.Font.mono)
                            .frame(width: 180)
                        if let problem = patternProblem {
                            Text(problem)
                                .font(Tokens.Font.caption)
                                .foregroundStyle(Tokens.Palette.errorText)
                        }
                    }
                }

                Text("{name} becomes the original filename.")
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
            } header: {
                SectionLabel(text: "Exports")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 220)
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
