import SwiftUI
import AVKit

extension View {
    func workspaceSheets(model: AppModel) -> some View { modifier(WorkspaceSheets(model: model)) }
}
private struct WorkspaceSheets: ViewModifier {
    @Bindable var model: AppModel
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $model.workspace.preflightPresented) { ExportPreflightView(model: model) }
            .sheet(isPresented: $model.workspace.historyPresented) { ExportHistoryView(model: model) }
    }
}

private struct ExportPreflightView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.preflightConversions.count == 1 ? "Review your export" : "Review \(model.preflightConversions.count) exports")
                .font(.title2.weight(.semibold))
            Text("Spatial video · .mov · Full source resolution")
                .foregroundStyle(.secondary)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Destination").font(.caption).foregroundStyle(.secondary)
                    Text(model.outputFolder.path).textSelection(.enabled).lineLimit(2)
                }
                Spacer()
                Button("Choose…") { model.chooseOutputFolder() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.preflightConversions) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.displayName).font(.headline)
                            Text(model.outputURL(for: item).lastPathComponent).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            if let probe = item.probe {
                                Text("\(probe.width) × \(probe.height) · About \(AppModel.estimatedSize(for: probe)) · \(probe.audioTrackCount) audio track\(probe.audioTrackCount == 1 ? "" : "s")")
                                    .font(.callout).foregroundStyle(.secondary)
                                Text(probe.isHDR ? "HDR source will be converted to SDR. Inspect a short proof before exporting." : "SDR color · Audio tracks preserved")
                                    .font(.callout).foregroundStyle(probe.isHDR ? .orange : .secondary)
                            }
                            if let estimate = model.learnedEstimate(for: item) {
                                Text("Estimated on this Mac: \(AppModel.humanDuration(estimate.lowerBound))–\(AppModel.humanDuration(estimate.upperBound))")
                                    .font(.callout).foregroundStyle(.secondary)
                            } else { Text("Time estimate will improve after the first completed export on this Mac.").font(.callout).foregroundStyle(.secondary) }
                            Text(item.depthOverrides.isEmpty ? "Automatic depth for each shot" : "Your saved depth adjustments will be applied")
                                .font(.callout)
                        }
                        Divider()
                    }
                    ForEach(model.preflightProblems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }
            .frame(maxHeight: 330)
            Text("Existing files are kept. If a name is taken, the new export gets a numbered filename. File checks run after encoding; headset playback remains a separate review.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { model.workspace.preflightPresented = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export \(model.preflightConversions.count == 1 ? "Video" : "\(model.preflightConversions.count) Videos")") { model.confirmPreflight() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!model.preflightProblems.isEmpty)
            }
        }
        .padding(28).frame(width: 600).preferredColorScheme(.dark)
    }
}

private struct ExportHistoryView: View {
    @Bindable var model: AppModel
    @State private var selectedID: UUID?
    @State private var showFailuresOnly = false
    @State private var reviewURL: URL?
    @State private var player: AVPlayer?
    private var records: [ExportRecord] { model.workspace.history.filter { (!showFailuresOnly || !$0.passed) && (model.workspace.selectedBatchID == nil || $0.runID == model.workspace.selectedBatchID) } }
    private var selected: ExportRecord? { model.workspace.history.first { $0.id == selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Export history").font(.title2.weight(.semibold))
                Spacer()
                Toggle("Needs attention", isOn: $showFailuresOnly).toggleStyle(.checkbox)
                Button("Done") { model.workspace.historyPresented = false }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Picker("Batch", selection: $model.workspace.selectedBatchID) {
                    Text("All history").tag(Optional<UUID>.none)
                    ForEach(model.workspace.batches) { Text($0.title).tag(Optional($0.id)) }
                }.frame(maxWidth: 400)
                if let batch = model.workspace.batches.first(where: { $0.id == model.workspace.selectedBatchID }) {
                    Text("\(batch.completed) passed · \(batch.failed) failed · \(batch.skipped) skipped")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            HSplitView {
                List(records, selection: $selectedID) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(record.title, systemImage: record.passed ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(record.passed ? Color.primary : Color.orange)
                        Text("\(record.proof ? "Proof" : "Full export") · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4).tag(record.id)
                }.frame(minWidth: 230, idealWidth: 270)
                VStack(alignment: .leading, spacing: 12) {
                    if let selected {
                        Text(selected.passed ? "File checks passed" : "Needs attention").font(.headline)
                        if let variant = selected.variantName { Text("Version: \(variant)").font(.callout) }
                        Text("Headset viewing: not checked by this app").font(.callout).foregroundStyle(.secondary)
                        if let url = selected.outputURL {
                            Text(url.lastPathComponent).font(.callout).textSelection(.enabled)
                            HStack {
                                Button(selected.proof ? "Open Proof" : "Review") {
                                    if selected.proof, model.conversions.contains(where: { $0.id == selected.sourceID && (selected.sourceURL == nil || $0.sourceURL == selected.sourceURL) }) { model.reopenProof(selected) }
                                    else { reviewURL = url; player = AVPlayer(url: url) }
                                }
                                Button("Show in Finder") { model.reveal(url) }
                                Button("Share…") { model.share(url) }
                            }.disabled(!FileManager.default.fileExists(atPath: url.path))
                        }
                        if reviewURL != nil, let player {
                            VideoPlayer(player: player).frame(height: 180)
                            Text("Desktop playback shows one eye. Judge stereoscopic depth on your headset.").font(.caption).foregroundStyle(.secondary)
                        }
                        ScrollView {
                            Text(selected.report).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let source = model.conversions.first(where: { $0.id == selected.sourceID }) {
                            HStack {
                                Button("Inspect Source") { model.select(source); model.workspace.historyPresented = false }
                                if model.canRetry(source) { Button("Retry") { model.retry(source); model.workspace.historyPresented = false } }
                                if source.failureKind == .intake { Button("Locate Source…") { model.locateSource(source) } }
                            }
                        }
                    } else {
                        ContentUnavailableView("Select a result", systemImage: "clock", description: Text("Proofs, completed exports and failures stay here across sessions."))
                    }
                }.padding(.leading, 12).frame(minWidth: 350)
            }.frame(height: 450)
            HStack {
                Text("\(model.workspace.history.filter(\.passed).count) passed · \(model.workspace.history.filter { !$0.passed }.count) need attention")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Reveal Exports") { model.revealHistoryOutputs() }
                Button("Share Exports…") { model.shareHistoryOutputs() }
            }
        }.padding(24).frame(width: 870).preferredColorScheme(.dark)
            .onDisappear { player?.pause() }
            .onChange(of: selectedID) { _, _ in player?.pause(); player = nil; reviewURL = nil }
    }
}
