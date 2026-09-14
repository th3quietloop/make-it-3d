import SwiftUI
import AVFoundation

struct ComputeBenchmark: Identifiable, Sendable {
    var preference: EngineTuning.ComputePreference
    var framesPerSecond: Double?
    var error: String?
    var id: String { preference.rawValue }
}

@Observable @MainActor final class ModelBenchmarkController {
    var results: [ComputeBenchmark] = []
    var isRunning = false
    var progress = ""
    var task: Task<Void, Never>?
    func cancel() { task?.cancel() }
    func run(source: URL) {
        guard !isRunning else { return }
        isRunning = true; results = []; progress = "Preparing three source frames…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false; self.task = nil; self.progress = "" }
            for choice in EngineTuning.ComputePreference.allCases {
                guard !Task.isCancelled else { return }
                self.progress = "Measuring \(choice.label)…"
                let worker = Task.detached(priority: .utility) { () -> ComputeBenchmark in
                    do {
                        let probe = try await Ingest.probe(url: source)
                        let reader = try await Ingest.FrameSource.open(probe: probe)
                        defer { reader.cancel() }
                        let estimator = try CoreMLDepthEstimator(computePreference: choice)
                        guard let warm = try reader.next() else { throw IngestError.noVideoTrack }
                        _ = try estimator.nearness(from: warm.pixelBuffer)
                        let began = Date()
                        var count = 0
                        while count < 3, let frame = try reader.next() {
                            try Task.checkCancellation()
                            _ = try estimator.nearness(from: frame.pixelBuffer)
                            count += 1
                        }
                        let elapsed = Date().timeIntervalSince(began)
                        return .init(preference: choice, framesPerSecond: count > 0 ? Double(count) / max(0.001, elapsed) : nil, error: count == 0 ? "The sample has too few frames." : nil)
                    } catch { return .init(preference: choice, error: error.localizedDescription) }
                }
                let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                self.results.append(result)
            }
        }
    }
}

struct ModelPerformanceSettings: View {
    @Bindable var model: AppModel
    @State private var benchmark = ModelBenchmarkController()
    var body: some View {
        Section("Depth model performance") {
            Text("Compare compute options using the selected video's first frames. This measures depth inference after warm-up; full export also includes decoding, reconstruction and encoding.")
                .font(.callout).foregroundStyle(.secondary)
            if let selection = model.selection {
                Picker("Compute for this video", selection: Binding(get: { selection.tuning.computePreference }, set: {
                    var tuning = selection.effectiveTuning(at: CMTime(seconds: model.playhead, preferredTimescale: 600))
                    tuning.computePreference = $0; model.updateTuning(tuning, for: selection)
                })) {
                    ForEach(EngineTuning.ComputePreference.allCases) { Text($0.label).tag($0) }
                }
                .disabled(model.isConverting || benchmark.isRunning)
                HStack {
                    Button("Measure on This Mac") { benchmark.run(source: selection.sourceURL) }
                        .disabled(benchmark.isRunning || model.isConverting || model.analysingID != nil || model.proofTask != nil)
                    if benchmark.isRunning { ProgressView().controlSize(.small); Button("Cancel") { benchmark.cancel() } }
                }
                if benchmark.isRunning { Text(benchmark.progress).font(.callout).foregroundStyle(.secondary) }
                ForEach(benchmark.results) { result in
                    HStack {
                        Text(result.preference.label)
                        Spacer()
                        if let fps = result.framesPerSecond {
                            Text("\(fps, specifier: "%.1f") frames/sec").monospacedDigit()
                        } else { Text(result.error ?? "Unavailable").font(.caption).foregroundStyle(.orange).lineLimit(2) }
                    }
                }
            } else { Text("Open a video to measure performance.").foregroundStyle(.secondary) }
            Text("Saved sessions retain each video's compute choice. Normal depth is the default; the temporal model remains experimental.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .onDisappear { benchmark.cancel() }
    }
}
