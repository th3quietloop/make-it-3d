import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

@MainActor extension AppModel {
    static func safeOutputName(pattern: String, sourceName: String) -> String {
        let expanded = pattern.replacingOccurrences(of: "{name}", with: sourceName)
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        var value = expanded.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix(".") { value.removeFirst() }
        if value.lowercased().hasSuffix(".mov") { value = String(value.dropLast(4)) }
        if value.isEmpty { value = "Spatial video" }
        return String(value.prefix(180))
    }

    func beginTuningEdit() {
        if tuningEditDepth == 0 { editUndoManager.beginUndoGrouping(); tuningEditCaptured = [] }
        tuningEditDepth += 1
    }
    func endTuningEdit() {
        guard tuningEditDepth > 0 else { return }
        tuningEditDepth -= 1
        if tuningEditDepth == 0 { editUndoManager.endUndoGrouping(); tuningEditCaptured = [] }
    }
    func registerTuningUndo(for conversion: Conversion) {
        if tuningEditDepth > 0 && tuningEditCaptured.contains(conversion.id) { return }
        tuningEditCaptured.insert(conversion.id)
        let tuning = conversion.tuning, overrides = conversion.depthOverrides
        let ownGroup = editUndoManager.groupingLevel == 0
        if ownGroup { editUndoManager.beginUndoGrouping() }
        editUndoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                guard !conversion.status.isConverting else { return }
                model.registerTuningUndo(for: conversion)
                conversion.tuning = tuning; conversion.depthOverrides = overrides
                model.refreshPreview(frameChanged: false); model.scheduleAutosave()
            }
        }
        editUndoManager.setActionName("Adjust Depth")
        if ownGroup { editUndoManager.endUndoGrouping() }
    }
    func registerQueueUndo() {
        let previous = conversions, selected = selectedIDs, focused = selectionID
        let ownGroup = editUndoManager.groupingLevel == 0
        if ownGroup { editUndoManager.beginUndoGrouping() }
        editUndoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                guard !model.queueRunning else { return }
                model.registerQueueUndo()
                model.conversions = previous; model.selectedIDs = selected; model.selectionID = focused
                model.refreshPreview(frameChanged: true)
                for item in previous {
                    if item.probe == nil { model.probe(item) }
                    if item.shotPlan == nil, item.planningProgress == nil, !item.status.isDone { model.autoTune(item, announce: false) }
                }
                model.scheduleAutosave()
            }
        }
        editUndoManager.setActionName("Edit Queue")
        if ownGroup { editUndoManager.endUndoGrouping() }
    }
    func moveSelection(by offset: Int) {
        let waiting = queuedWaiting
        let ids = selectedPriorityCandidates.map(\.id)
        guard !ids.isEmpty else { return }
        if offset < 0, let first = waiting.firstIndex(where: { ids.contains($0.id) }), first > 0 {
            reorderQueued(ids: ids, before: waiting[first - 1].id)
        } else if offset > 0, let last = waiting.lastIndex(where: { ids.contains($0.id) }), last + 1 < waiting.count {
            reorderQueued(ids: ids, before: last + 2 < waiting.count ? waiting[last + 2].id : nil)
        }
    }
    func toggleBookmark() {
        guard let selection else { return }
        if let index = selection.bookmarks.firstIndex(where: { abs($0 - playhead) < 0.1 }) { selection.bookmarks.remove(at: index) }
        else { selection.bookmarks.append(playhead); selection.bookmarks.sort() }
        scheduleAutosave()
    }
    func saveVariant(name: String) {
        guard let selection else { return }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        workspace.variants.append(.init(name: String(title.prefix(80)), sourceID: selection.id, tuning: selection.tuning, overrides: selection.depthOverrides))
        scheduleAutosave(); toasts.info("Saved \(title)")
    }
    func applyVariant(_ variant: DepthVariant) {
        guard let selection, !selection.status.isConverting, variant.sourceID == selection.id else { return }
        registerTuningUndo(for: selection)
        selection.tuning = variant.tuning; selection.depthOverrides = variant.overrides
        refreshPreview(frameChanged: false); scheduleAutosave()
    }
    func deleteVariant(_ variant: DepthVariant) {
        workspace.variants.removeAll { $0.id == variant.id }; scheduleAutosave()
    }
    func applySettingsToSelected(includeDepth: Bool, includeCleanup: Bool, includeModel: Bool) {
        guard let source = selection else { return }
        let depth = source.effectiveTuning(at: CMTime(seconds: playhead, preferredTimescale: 600))
        beginTuningEdit(); defer { endTuningEdit() }
        var count = 0
        for target in selectedConversions where target.id != source.id && !target.status.isConverting {
            registerTuningUndo(for: target)
            if includeDepth {
                target.depthOverrides = .init(global: .init(strengthPercent: depth.disparityScale * 100, convergence: depth.convergence))
            }
            if includeCleanup {
                target.tuning.fillDisocclusions = source.tuning.fillDisocclusions
                target.tuning.synthesis = source.tuning.synthesis
                target.tuning.overscan = source.tuning.overscan
                target.tuning.edgeRefinement = source.tuning.edgeRefinement
                target.tuning.motionRejection = source.tuning.motionRejection
                target.tuning.temporalAlpha = source.tuning.temporalAlpha
            }
            if includeModel { target.tuning.depthModel = source.tuning.depthModel; target.tuning.computePreference = source.tuning.computePreference }
            count += 1
        }
        scheduleAutosave(); toasts.info("Applied settings to \(count) videos")
    }

    func makeProof(duration: Double = 5, automatic: Bool = false) {
        guard !workspace.modelOperationInProgress, proofTask == nil, queuePhase == .idle, let conversion = selection, conversion.planningProgress == nil, let probe = conversion.probe else { return }
        let seconds = min(max(duration, 3), min(8, probe.duration.seconds))
        guard seconds > 0 else { return }
        let start = min(max(playhead, 0), max(0, probe.duration.seconds - seconds))
        let folder = WorkspaceStorage.proofsDirectory
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { workspace.proofError = error.localizedDescription; return }
        let url = folder.appendingPathComponent("\(Self.safeOutputName(pattern: "{name}", sourceName: conversion.displayName))_\(automatic ? "Auto" : "Draft")_\(UUID().uuidString.prefix(8)).mov")
        var request = ConversionRequest(probe: probe, tuning: conversion.tuning, outputURL: url, shotPlan: conversion.shotPlan)
        request.depthOverrides = automatic ? .init() : conversion.depthOverrides
        request.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: seconds, preferredTimescale: 600))
        let frozenRequest = request
        workspace.proofProgress = 0; workspace.proofError = nil; workspace.proofStale = false
        workspace.proofLabel = "\(automatic ? "Auto" : "Draft") · \(Int(seconds))s from \(String(format: "%.2f", start))s"
        playback.stop()
        let pendingAnalysis = analysisTask
        let runner = conversionRunner
        proofTask = Task { [weak self] in
            guard let self else { return }
            defer { self.workspace.proofProgress = nil; self.proofTask = nil; self.scheduleAnalysis(); self.scheduleAutosave() }
            if let pendingAnalysis { await pendingAnalysis.value }
            guard !Task.isCancelled else { return }
            let began = Date()
            let (stream, continuation) = AsyncStream<ConversionEvent>.makeStream()
            let worker = Task {
                await runner(frozenRequest) { continuation.yield($0) }
                continuation.finish()
            }
            await withTaskCancellationHandler {
                for await event in stream {
                    switch event {
                    case .started: break
                    case .progress(let fraction, _): self.workspace.proofProgress = fraction
                    case .finished(let report):
                        if Task.isCancelled {
                            try? FileManager.default.removeItem(at: report.outputURL)
                            self.workspace.proofLabel = "Proof cancelled"
                            break
                        }
                        self.recordExport(report, conversion: conversion, tuning: frozenRequest.tuning, overrides: frozenRequest.depthOverrides, seconds: Date().timeIntervalSince(began), proof: true, proofStart: start)
                        if report.passed, !Task.isCancelled {
                            if self.selection === conversion {
                                self.playback.loadProof(url: report.outputURL, sourceStartSeconds: start)
                                self.workspace.proofStale = conversion.tuning != frozenRequest.tuning || conversion.depthOverrides != frozenRequest.depthOverrides
                            }
                            self.toasts.success("Proof ready", detail: "\(conversion.displayName) · Available in History", actionLabel: "Open proof") { [weak self] in
                                guard let self, let record = self.workspace.history.first(where: { $0.outputURL == report.outputURL }) else { return }
                                self.reopenProof(record)
                            }
                        } else { self.workspace.proofError = "The proof failed verification. See History for the report." }
                    case .failed(let message): self.workspace.proofError = message
                    case .cancelled: self.workspace.proofLabel = "Proof cancelled"
                    }
                }
                await worker.value
            } onCancel: { worker.cancel() }
        }
    }
    func cancelProof() { proofTask?.cancel() }

    func showExportPreflight(for work: [Conversion], scope: QueueRunScope = .selectedSnapshot) {
        guard !workspace.modelOperationInProgress, !work.isEmpty, queuePhase == .idle, proofTask == nil else { return }
        workspace.preflightIDs = work.map(\.id); workspace.preflightScope = scope; workspace.preflightPresented = true
    }
    var preflightConversions: [Conversion] { conversions.filter { workspace.preflightIDs.contains($0.id) } }
    var preflightProblems: [String] {
        var problems: [String] = []
        let folder = outputFolder.standardizedFileURL
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            problems.append("The destination folder is unavailable. Reconnect the drive or choose another folder.")
        } else if !FileManager.default.isWritableFile(atPath: folder.path) { problems.append("The destination folder is not writable.") }
        for item in preflightConversions {
            if !FileManager.default.isReadableFile(atPath: item.sourceURL.path) { problems.append("\(item.displayName): source unavailable. Locate it in the session or reconnect its drive.") }
            if item.probe == nil || item.planningProgress != nil { problems.append("\(item.displayName): still preparing.") }
        }
        let needed = preflightConversions.compactMap(\.probe).reduce(Int64(0)) { partial, probe in
            let (sum, overflow) = partial.addingReportingOverflow(estimatedOutputBytes(for: probe)); return overflow ? .max : sum
        }
        if let free = freeBytesAtOutput(), Double(needed) * 1.2 > Double(free) { problems.append("There is not enough free space for this batch and working headroom.") }
        return problems
    }
    func confirmPreflight() {
        guard preflightProblems.isEmpty else { return }
        let work = preflightConversions
        workspace.preflightPresented = false
        startQueue(work, scope: workspace.preflightScope)
    }

    func recordExport(_ report: VerificationReport, conversion: Conversion, tuning: EngineTuning, overrides: DepthOverrides, seconds: Double, proof: Bool, proofStart: Double? = nil) {
        workspace.history.insert(.init(sourceID: conversion.id, title: conversion.displayName, outputURL: report.outputURL, passed: report.passed, report: report.text, tuning: tuning, overrides: overrides, duration: seconds, proof: proof, proofStart: proofStart,
            variantName: workspace.variants.last(where: { $0.sourceID == conversion.id && $0.tuning == tuning && $0.overrides == overrides })?.name, sourceURL: conversion.sourceURL, runID: !proof && isInCurrentRun(conversion) ? currentRunIdentifier : nil), at: 0)
        workspace.history = Array(workspace.history.prefix(500))
        if report.passed, let probe = conversion.probe, seconds > 0, let verifiedFrames = report.verifiedFrameCount, verifiedFrames > 0 {
            workspace.performance.append(.init(model: tuning.depthModel, width: probe.width, height: probe.height, frames: verifiedFrames, seconds: seconds, analysis: false))
            workspace.performance = Array(workspace.performance.suffix(100))
        }
        scheduleAutosave()
    }
    func recordFailedAttempt(_ conversion: Conversion, message: String) {
        workspace.history.insert(.init(sourceID: conversion.id, title: conversion.displayName, passed: false, report: message, tuning: conversion.tuning, overrides: conversion.depthOverrides, duration: 0, proof: false, sourceURL: conversion.sourceURL, runID: isInCurrentRun(conversion) ? currentRunIdentifier : nil), at: 0)
        workspace.history = Array(workspace.history.prefix(500))
        scheduleAutosave()
    }
    func learnedEstimate(for conversion: Conversion, analysis: Bool = false) -> ClosedRange<Double>? {
        guard let probe = conversion.probe else { return nil }
        let samples = workspace.performance.filter { $0.analysis == analysis && $0.model == (analysis ? .perFrame : conversion.tuning.depthModel) && $0.hardware == PerformanceSample.currentHardware && $0.frames > 0 && $0.seconds > 0 }
        guard !samples.isEmpty else { return nil }
        let currentPixels = Double(probe.width * probe.height)
        let rates = samples.suffix(12).map { $0.seconds / Double($0.frames) * (analysis ? 1 : currentPixels / max(1, Double($0.width * $0.height))) }.sorted()
        let frames = analysis ? max(1, probe.duration.seconds / ShotPlanner.sampleInterval) : Double(probe.estimatedFrameCount)
        return max(1, rates.first! * frames * 0.8)...max(1, rates.last! * frames * 1.2)
    }
    func shareHistoryOutputs() {
        let urls = workspace.history.filter { $0.passed && !$0.proof && (workspace.selectedBatchID == nil || $0.runID == workspace.selectedBatchID) }.compactMap(\.outputURL).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let view = NSApp.keyWindow?.contentView, !urls.isEmpty else { return }
        NSSharingServicePicker(items: Array(Set(urls))).show(relativeTo: .zero, of: view, preferredEdge: .maxY)
    }
    func revealHistoryOutputs() {
        NSWorkspace.shared.activateFileViewerSelecting(workspace.history.filter { $0.passed && !$0.proof && (workspace.selectedBatchID == nil || $0.runID == workspace.selectedBatchID) }.compactMap(\.outputURL))
    }

    func document() -> WorkspaceDocument {
        .init(conversions: conversions.map { item in
            var output: URL?
            if case .done(let url) = item.status { output = url }
            return .init(id: item.id, sourceURL: item.sourceURL, tuning: item.tuning, overrides: item.depthOverrides, exportedTuning: item.exportedTuning, exportedOverrides: item.exportedDepthOverrides, plan: item.shotPlan, exportedPlan: item.exportedShotPlan, outputURL: output, failure: item.failureMessage, interrupted: item.status.isConverting, bookmarks: item.bookmarks)
        }, selectionID: selectionID, playhead: playhead, outputFolder: outputFolder, filenamePattern: filenamePattern, sidebarVisible: sidebarVisible, inspectorVisible: inspectorVisible, variants: workspace.variants, history: workspace.history, performance: workspace.performance, batches: workspace.batches)
    }
    func scheduleAutosave() {
        guard systemFeedbackEnabled, !isRestoring, !isShuttingDown else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            self?.saveWorkspaceNow()
        }
    }
    func saveWorkspaceNow() {
        guard systemFeedbackEnabled, !isRestoring else { return }
        do {
            let value = document()
            try WorkspaceStorage.write(value, to: WorkspaceStorage.autosaveURL)
            if let session = workspace.sessionURL { try WorkspaceStorage.write(value, to: session) }
            workspace.savedAt = Date(); workspace.saveError = nil
        } catch { workspace.saveError = "Couldn't save this workspace: \(error.localizedDescription)" }
    }
    func restoreAutosave() {
        guard FileManager.default.fileExists(atPath: WorkspaceStorage.autosaveURL.path) else { return }
        do { try restore(WorkspaceStorage.read(WorkspaceDocument.self, from: WorkspaceStorage.autosaveURL)) }
        catch { workspace.saveError = "The last workspace couldn't be restored. It has been kept on disk." }
    }
    func restore(_ document: WorkspaceDocument) throws {
        guard document.version == 1 else { throw CocoaError(.fileReadUnknown) }
        guard !queueRunning, proofTask == nil else { return }
        isRestoring = true
        defer { isRestoring = false }
        analysisWorker?.cancel(); analysisTask?.cancel(); analysisWaiting = []
        editUndoManager.removeAllActions()
        conversions = document.conversions.map { saved in
            let item = Conversion(sourceURL: saved.sourceURL, id: saved.id)
            item.tuning = saved.tuning; item.depthOverrides = saved.overrides
            item.exportedTuning = saved.exportedTuning; item.exportedDepthOverrides = saved.exportedOverrides
            item.shotPlan = saved.plan; item.exportedShotPlan = saved.exportedPlan; item.bookmarks = saved.bookmarks
            if let output = saved.outputURL, FileManager.default.fileExists(atPath: output.path) { item.status = .done(outputURL: output) }
            if !FileManager.default.isReadableFile(atPath: saved.sourceURL.path) {
                item.sourceMissing = true
                if !item.status.isDone { item.status = .failed("Source unavailable. Choose Locate Source to reconnect it.") }
                item.failureKind = .intake
            }
            return item
        }
        selectionID = document.selectionID.flatMap { id in conversions.contains { $0.id == id } ? id : nil } ?? conversions.first?.id
        selectedIDs = Set([selectionID].compactMap { $0 }); playhead = max(0, document.playhead)
        outputFolder = document.outputFolder; filenamePattern = document.filenamePattern
        sidebarVisible = document.sidebarVisible; inspectorVisible = document.inspectorVisible
        workspace.variants = document.variants; workspace.history = document.history; workspace.performance = document.performance; workspace.batches = document.batches ?? []
        workspace.restoredNotice = document.conversions.contains(where: \.interrupted) ? "Workspace recovered. Interrupted exports are ready to restart; completed files are preserved." : "Workspace restored"
        for item in conversions where item.failureKind != .intake {
            probe(item)
            if item.shotPlan == nil { autoTune(item, announce: false) }
        }
        refreshPreview(frameChanged: true)
    }
    func saveSessionAs() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Make It 3D Session.json"
        panel.message = "Saves settings, scenes, bookmarks and history. Videos stay in their original locations."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try WorkspaceStorage.write(document(), to: url); workspace.sessionURL = url; toasts.success("Session saved") }
        catch { toasts.failure("Couldn't save session", detail: error.localizedDescription) }
    }
    func openSession() {
        guard !queueRunning, proofTask == nil else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try restore(WorkspaceStorage.read(WorkspaceDocument.self, from: url)); workspace.sessionURL = url; scheduleAutosave() }
        catch { toasts.failure("Couldn't open session", detail: error.localizedDescription) }
    }
    func locateSource(_ item: Conversion) {
        guard !item.status.isConverting, proofTask == nil else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = Self.supportedTypes; panel.message = "Locate \(item.sourceURL.lastPathComponent)"
        guard panel.runModal() == .OK, let url = panel.url, let index = conversions.firstIndex(where: { $0.id == item.id }) else { return }
        let replacement = Conversion(sourceURL: url, id: item.id)
        replacement.tuning = item.tuning
        replacement.depthOverrides.global = item.depthOverrides.global
        // Scene overrides and analysis refer to the old file; do not silently transfer them to unrelated footage.
        conversions[index] = replacement; probe(replacement); autoTune(replacement, announce: false)
        refreshPreview(frameChanged: true); scheduleAutosave()
    }
    func cleanUpForQuit() async {
        isShuttingDown = true
        autosaveTask?.cancel(); cancelProof(); analysisWorker?.cancel(); analysisTask?.cancel()
        playback.stop(); preview.isWigglePlaying = false
        if queueRunning { stopNow() }
        if let task = activePipelineTask { await task.value }
        if let task = queueDriverTask { await task.value }
        if let task = proofTask { await task.value }
        if let task = analysisTask { await task.value }
        saveWorkspaceNow()
    }
    func exportDiagnostics() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "MakeIt3D-diagnostics.json"
        panel.message = "Includes app, system and processing settings, check outcomes and counts. Does not include videos, filenames, full paths or model input."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        struct Diagnostic: Encodable {
            var appVersion: String; var system: String; var processors: Int; var memoryBytes: UInt64
            var queueCount: Int; var passedExports: Int; var failedExports: Int
            var settings: [EngineTuning]; var performance: [PerformanceSample]
        }
        let info = ProcessInfo.processInfo
        let value = Diagnostic(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development", system: info.operatingSystemVersionString, processors: info.processorCount, memoryBytes: info.physicalMemory, queueCount: conversions.count, passedExports: workspace.history.filter(\.passed).count, failedExports: workspace.history.filter { !$0.passed }.count, settings: conversions.map(\.tuning), performance: workspace.performance)
        do { try WorkspaceStorage.write(value, to: url); toasts.success("Diagnostics saved", actionLabel: "Show in Finder") { self.reveal(url) } }
        catch { toasts.failure("Couldn't save diagnostics", detail: error.localizedDescription) }
    }
}

@MainActor extension AppModel {
    func demonstrateDepth() {
        guard let selection, !selection.status.isConverting else { return }
        inspectorVisible = true
        playback.stop()
        previewMode = .wiggle
        preview.isWigglePlaying = false
        let originalTuning = selection.tuning, originalOverrides = selection.depthOverrides
        adjustmentScope = .shot
        var exaggerated = selection.effectiveTuning(at: CMTime(seconds: playhead, preferredTimescale: 600))
        exaggerated.customDisparityPercent = 3.5
        updateTuning(exaggerated, for: selection)
        toasts.success("Compare the foreground edges", detail: "This exaggerated setting makes the eye shift easier to see. Use Show Other Eye, then restore the original amount.", actionLabel: "Restore depth") { [weak self] in
            guard let self else { return }
            self.registerTuningUndo(for: selection)
            selection.tuning = originalTuning; selection.depthOverrides = originalOverrides
            self.refreshPreview(frameChanged: false); self.scheduleAutosave()
            self.toasts.info("Depth restored", detail: "Try a short moving proof before exporting the full video.")
        }
    }
}

@MainActor extension AppModel {
    func reopenProof(_ record: ExportRecord) {
        guard record.proof, let url = record.outputURL, FileManager.default.fileExists(atPath: url.path),
              let source = conversions.first(where: { $0.id == record.sourceID }),
              record.sourceURL == nil || record.sourceURL == source.sourceURL else { return }
        select(source)
        playback.loadProof(url: url, sourceStartSeconds: record.proofStart ?? 0)
        workspace.proofLabel = "\(record.variantName ?? "Saved proof") · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))"
        workspace.proofStale = source.tuning != record.tuning || source.depthOverrides != record.overrides
        workspace.historyPresented = false
    }
}

@MainActor extension AppModel {
    func refreshDepthModels() {
        guard !queueRunning, proofTask == nil, analysingID == nil else { return }
        playback.stop()
        preview.clear()
        preview = PreviewController()
        modelBanner = CoreMLDepthEstimator.bundledModelURL() == nil ? "The depth model is unavailable." : nil
        for item in conversions where !item.sourceMissing {
            item.shotPlan = nil
            autoTune(item, announce: false)
        }
        refreshPreview(frameChanged: true)
        scheduleAutosave()
    }
}

@MainActor extension AppModel {
    func resetDepthParameter(strength: Bool, for conversion: Conversion) {
        guard !conversion.status.isConverting else { return }
        registerTuningUndo(for: conversion)
        if playback.activeProofURL != nil { workspace.proofStale = true }
        let shotID = conversion.shotPlan?.shot(at: CMTime(seconds: playhead, preferredTimescale: 600))?.id
        if adjustmentScope == .video || shotID == nil {
            if strength { conversion.depthOverrides.global?.strengthPercent = nil }
            else { conversion.depthOverrides.global?.convergence = nil }
            for id in conversion.depthOverrides.shots.keys {
                if strength {
                    conversion.depthOverrides.shots[id]?.strengthPercent = nil
                    conversion.depthOverrides.shots[id]?.automaticStrength = nil
                } else {
                    conversion.depthOverrides.shots[id]?.convergence = nil
                    conversion.depthOverrides.shots[id]?.automaticConvergence = nil
                }
            }
        } else if let shotID {
            var adjustment = conversion.depthOverrides.shots[shotID] ?? .init()
            if strength { adjustment.strengthPercent = nil; adjustment.automaticStrength = true }
            else { adjustment.convergence = nil; adjustment.automaticConvergence = true }
            conversion.depthOverrides.shots[shotID] = adjustment
        }
        refreshPreview(frameChanged: false); scheduleAutosave()
    }
}
