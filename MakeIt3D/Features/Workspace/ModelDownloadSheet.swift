import SwiftUI

/// Advanced, explicit model distribution. The publisher supplies the checksum;
/// the app verifies it and tests compatibility before changing the active model.
struct ModelDownloadSheet: View {
    @Bindable var model: AppModel
    let kind: EngineTuning.DepthModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var checksum = ""
    @State private var running = false
    @State private var fraction: Double?
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?
    @State private var completed = false
    private var valid: Bool {
        guard let url = URL(string: address), url.scheme?.lowercased() == "https", url.host != nil else { return false }
        return checksum.trimmingCharacters(in: .whitespacesAndNewlines).count == 64
            && checksum.trimmingCharacters(in: .whitespacesAndNewlines).allSatisfy(\.isHexDigit)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download \(kind.label) model").font(.title2.weight(.semibold))
            Text("Use a compatible Core ML ZIP package and the SHA-256 checksum provided by its publisher. The existing model stays active until the new one passes validation.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("HTTPS package URL", text: $address).textFieldStyle(.roundedBorder)
            TextField("Publisher's SHA-256 checksum", text: $checksum).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            if kind == .video { Text("The experimental temporal model can take several minutes to validate one window.").font(.callout).foregroundStyle(.secondary) }
            if running {
                if let fraction { ProgressView(value: fraction); Text("Downloading \(Int(fraction * 100))%").monospacedDigit() }
                else { HStack { ProgressView().controlSize(.small); Text("Checking package and running calibration…") } }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.orange).textSelection(.enabled) }
            if completed { Label("Model validated and activated", systemImage: "checkmark.circle").foregroundStyle(.green) }
            HStack {
                Button(running ? "Cancel Download" : "Close") { if running { task?.cancel() } else { dismiss() } }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Download and Validate") { download() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!valid || running || completed || model.queueRunning || model.proofTask != nil || model.analysingID != nil)
            }
        }.padding(24).frame(width: 560).interactiveDismissDisabled(running)
    }
    private func download() {
        guard let url = URL(string: address), valid else { return }
        let expected = checksum.trimmingCharacters(in: .whitespacesAndNewlines)
        running = true; model.workspace.modelOperationInProgress = true; fraction = 0; errorMessage = nil
        task = Task {
            defer { running = false; model.workspace.modelOperationInProgress = false; model.scheduleAnalysis(); task = nil }
            let worker = Task.detached(priority: .utility) {
                try await DepthModelStore.downloadAndInstall(from: url, expectedSHA256: expected, kind: kind) { value in
                    Task { @MainActor in fraction = value }
                }
            }
            do {
                _ = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                completed = true; model.refreshDepthModels()
            } catch is CancellationError { errorMessage = "Download cancelled. The previous model is still active." }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
