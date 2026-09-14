import SwiftUI

struct ModelLibrarySettings: View {
    @Bindable var model: AppModel
    @State private var selectedKind: EngineTuning.DepthModel = .perFrame
    @State private var installing = false
    @State private var installTask: Task<Void, Never>?
    @State private var resultMessage: String?
    @State private var refreshID = 0
    @State private var downloadPresented = false
    var body: some View {
        Section("Model library") {
            Picker("Model", selection: $selectedKind) {
                ForEach(EngineTuning.DepthModel.allCases) { Text($0.label).tag($0) }
            }.disabled(installing)
            if let installed = DepthModelStore.installedModel(for: selectedKind) {
                LabeledContent("Active", value: installed.displayName)
                Text("Validated \(installed.inputWidth) × \(installed.inputHeight) input · Calibration \(installed.inferenceSeconds, specifier: "%.2f")s")
                    .font(.callout).foregroundStyle(.secondary)
                Text("SHA-256: \(installed.checksum)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            } else { Text("Built-in \(selectedKind.label) model").foregroundStyle(.secondary) }
            HStack {
                Button("Import…") { importModel() }
                Button("Download…") { downloadPresented = true }
                Button("Use Built-in") {
                    do { try DepthModelStore.useBuiltInModel(for: selectedKind); refreshID += 1; model.refreshDepthModels(); resultMessage = "Built-in model restored. Updating scene analysis." }
                    catch { resultMessage = error.localizedDescription }
                }
            }.disabled(installing || model.queueRunning || model.analysingID != nil || model.proofTask != nil)
            if installing {
                HStack { ProgressView().controlSize(.small); Text("Validating and measuring the model…"); Button("Cancel") { installTask?.cancel() } }
            }
            if let resultMessage { Text(resultMessage).font(.callout).foregroundStyle(.secondary) }
            Text(selectedKind == .video ? "Experimental temporal inference can take minutes for a single window. Import validates a full window before activating it." : "Imported models are copied, checked with a real inference, and activated only after validation. Keep the built-in model available as a fallback.")
                .font(.callout).foregroundStyle(.secondary)
        }.id(refreshID)
            .sheet(isPresented: $downloadPresented) { ModelDownloadSheet(model: model, kind: selectedKind) }
    }
    private func importModel() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose a compatible .mlpackage or .mlmodelc. The model will be tested before activation."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let kind = selectedKind
        installing = true; model.workspace.modelOperationInProgress = true; resultMessage = nil
        installTask = Task {
            defer { installing = false; model.workspace.modelOperationInProgress = false; model.scheduleAnalysis(); installTask = nil }
            let worker = Task.detached(priority: .utility) { try await DepthModelStore.install(from: url, kind: kind) }
            do {
                let installed = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                refreshID += 1
                model.refreshDepthModels()
                resultMessage = "\(installed.displayName) validated. Updating scene analysis; preview and exports now use the selected model."
            } catch is CancellationError { resultMessage = "Import cancelled. The previous model is still active." }
            catch { resultMessage = "Import failed: \(error.localizedDescription)" }
        }
    }
}
