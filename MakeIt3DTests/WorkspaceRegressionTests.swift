import XCTest
import AVFoundation
@testable import MakeIt3D

@MainActor
final class WorkspaceRegressionTests: XCTestCase {
    func testShotOverrideSurvivesNavigationAndMatchesExportRequest() async {
        let runner = ControlledConversionRunner()
        let model = model(runner: runner)
        let item = plannedVideo()
        model.conversions = [item]
        model.select(item)
        model.adjustmentScope = .shot
        var edited = item.effectiveTuning(at: .zero)
        edited.customDisparityPercent = 2.3
        edited.convergence = 0.25
        model.updateTuning(edited, for: item)
        model.scrub(to: 7)
        XCTAssertEqual(item.effectiveTuning(at: time(7)).convergence, 0.8, accuracy: 0.0001)
        model.scrub(to: 0.25)
        XCTAssertEqual(item.effectiveTuning(at: time(0.25)).disparityScale, 0.023, accuracy: 0.0001)
        XCTAssertEqual(item.effectiveTuning(at: time(0.25)).convergence, 0.25, accuracy: 0.0001)

        model.convertSelected()
        let started = await waitForInvocationCount(1, from: runner)
        XCTAssertTrue(started)
        guard started else { model.stopNow(); return }
        let request = await runner.request(for: 1)
        XCTAssertEqual(request.tuning(at: time(0.25)), item.effectiveTuning(at: time(0.25)))
        XCTAssertEqual(request.tuning(at: time(7)), item.effectiveTuning(at: time(7)))
        await runner.finish(1)
        let finished = await waitUntil { model.queuePhase == .idle }
        XCTAssertTrue(finished)
        XCTAssertFalse(item.settingsChangedSinceExport)
        model.scrub(to: 7)
        XCTAssertFalse(item.settingsChangedSinceExport)
        XCTAssertTrue(model.finished.contains { $0.id == item.id })
        XCTAssertFalse(model.readyToConvert.contains { $0.id == item.id })
    }

    func testWholeVideoAdjustmentAppliesAcrossAnExistingShotOverride() {
        let model = AppModel(systemFeedbackEnabled: false)
        let item = plannedVideo()
        model.conversions = [item]
        model.select(item)
        var shotEdit = item.effectiveTuning(at: .zero)
        shotEdit.customDisparityPercent = 2.5
        model.updateTuning(shotEdit, for: item)
        model.adjustmentScope = .video
        var wholeEdit = item.effectiveTuning(at: .zero)
        wholeEdit.customDisparityPercent = 1.3
        model.updateTuning(wholeEdit, for: item)
        for seconds in [0.2, 7.0] {
            XCTAssertEqual(item.effectiveTuning(at: time(seconds)).disparityScale, 0.013, accuracy: 0.0001)
        }
        XCTAssertEqual(item.effectiveTuning(at: time(7)).convergence, 0.8, accuracy: 0.0001)
    }

    func testWholeVideoAdjustmentIncludesAShotReturnedToAutomatic() {
        let model = AppModel(systemFeedbackEnabled: false)
        let item = plannedVideo()
        item.depthOverrides.global = .init(strengthPercent: 2, convergence: 0.3)
        model.conversions = [item]
        model.select(item)
        model.adjustmentScope = .shot
        model.returnToAutomatic(item)
        XCTAssertEqual(item.effectiveTuning(at: time(0.2)).convergence, 0.6, accuracy: 0.0001)

        model.adjustmentScope = .video
        var edit = item.effectiveTuning(at: .zero)
        edit.customDisparityPercent = 1.4
        edit.convergence = 0.4
        model.updateTuning(edit, for: item)
        for seconds in [0.2, 7.0] {
            XCTAssertEqual(item.effectiveTuning(at: time(seconds)).disparityScale, 0.014, accuracy: 0.0001)
            XCTAssertEqual(item.effectiveTuning(at: time(seconds)).convergence, 0.4, accuracy: 0.0001)
        }
    }

    func testWholeVideoStrengthEditPreservesAutomaticBalanceForOneShot() {
        let model = AppModel(systemFeedbackEnabled: false)
        let item = plannedVideo()
        item.depthOverrides.global = .init(strengthPercent: 2, convergence: 0.3)
        model.conversions = [item]
        model.select(item)
        model.returnToAutomatic(item)
        model.adjustmentScope = .video
        var edit = item.effectiveTuning(at: .zero)
        edit.customDisparityPercent = 1.4
        model.updateTuning(edit, for: item)
        XCTAssertEqual(item.effectiveTuning(at: time(0.2)).disparityScale, 0.014, accuracy: 0.0001)
        XCTAssertEqual(item.effectiveTuning(at: time(7)).disparityScale, 0.014, accuracy: 0.0001)
        XCTAssertEqual(item.effectiveTuning(at: time(0.2)).convergence, 0.6, accuracy: 0.0001)
        XCTAssertEqual(item.effectiveTuning(at: time(7)).convergence, 0.3, accuracy: 0.0001)
    }

    func testWholeVideoStrengthResetUsesEachShotsOwnAutomaticDepth() {
        let model = AppModel(systemFeedbackEnabled: false)
        let item = plannedVideo()
        item.depthOverrides = .init(global: .init(strengthPercent: 2, convergence: 0.3),
                                    shots: [0: .init(strengthPercent: 1.8)])
        model.conversions = [item]
        model.select(item)
        model.adjustmentScope = .video
        model.resetDepthParameter(strength: true, for: item)
        XCTAssertEqual(item.effectiveTuning(at: time(0.2)).disparityScale, 0.006, accuracy: 0.0001)
        XCTAssertEqual(item.effectiveTuning(at: time(7)).disparityScale, 0.012, accuracy: 0.0001)
        XCTAssertEqual(item.effectiveTuning(at: time(0.2)).convergence, 0.3, accuracy: 0.0001)
        XCTAssertEqual(item.effectiveTuning(at: time(7)).convergence, 0.3, accuracy: 0.0001)
    }

    func testProofAdmissionRejectsPausedQueueAndUnpreparedSelection() async {
        let runner = ControlledConversionRunner()
        let model = model(runner: runner)
        let item = plannedVideo()
        model.conversions = [item]
        model.select(item)
        model.convertSelected()
        let started = await waitForInvocationCount(1, from: runner)
        XCTAssertTrue(started)
        guard started else { model.stopNow(); return }
        model.pauseAfterCurrent()
        await runner.finish(1)
        let paused = await waitUntil { model.queuePhase == .paused }
        XCTAssertTrue(paused)
        model.makeProof()
        XCTAssertNil(model.proofTask)
        model.stopNow()
        item.planningProgress = 0.4
        model.makeProof()
        XCTAssertNil(model.proofTask)
    }

    func testQueueAdmissionWaitsForActiveProof() {
        let model = AppModel(systemFeedbackEnabled: false)
        let item = plannedVideo()
        model.conversions = [item]
        model.proofTask = Task {}
        defer { model.proofTask?.cancel(); model.proofTask = nil }
        model.startQueue([item], scope: .selectedSnapshot)
        XCTAssertEqual(model.queuePhase, .idle)
        XCTAssertNil(model.queueDriverTask)
    }

    func testFinishedProofDoesNotReplaceAnotherSelectedVideo() async {
        let runner = ControlledConversionRunner()
        let model = model(runner: runner)
        let original = plannedVideo()
        let other = QueueTestFixture.runnable("Other video")
        model.conversions = [original, other]
        model.select(original)
        model.makeProof()
        let started = await waitForInvocationCount(1, from: runner)
        XCTAssertTrue(started)
        guard started else { model.cancelProof(); return }
        model.select(other)
        await runner.finish(1)
        let finished = await waitUntil { model.proofTask == nil }
        XCTAssertTrue(finished)
        XCTAssertNil(model.playback.activeProofURL)
        XCTAssertEqual(model.playback.sourceURL, other.sourceURL)
        XCTAssertEqual(model.workspace.history.first?.sourceID, original.id)
        XCTAssertEqual(model.workspace.history.first?.proof, true)
    }

    func testProofRecordsFrozenSettingsAndMarksLaterEditsStale() async {
        let runner = ControlledConversionRunner()
        let model = model(runner: runner)
        let item = plannedVideo()
        model.conversions = [item]
        model.select(item)
        model.makeProof()
        let started = await waitForInvocationCount(1, from: runner)
        XCTAssertTrue(started)
        guard started else { model.cancelProof(); return }
        let request = await runner.request(for: 1)
        var edit = item.effectiveTuning(at: .zero)
        edit.customDisparityPercent = 2.4
        model.updateTuning(edit, for: item)
        await runner.finish(1)
        let finished = await waitUntil { model.proofTask == nil }
        XCTAssertTrue(finished)
        XCTAssertEqual(model.playback.activeProofURL, request.outputURL)
        XCTAssertTrue(model.workspace.proofStale)
        XCTAssertEqual(model.workspace.history.first?.overrides, request.depthOverrides)
        XCTAssertNotEqual(model.workspace.history.first?.overrides, item.depthOverrides)
    }

    func testQuitWaitsForCancelledRedoToRestoreCompletedState() async {
        let runner = ControlledConversionRunner()
        let model = model(runner: runner)
        let item = plannedVideo()
        let previousOutput = QueueTestFixture.sourceURL("Previous export")
        item.status = .done(outputURL: previousOutput)
        item.exportedTuning = item.tuning
        item.exportedDepthOverrides = item.depthOverrides
        item.exportedShotPlan = item.shotPlan
        model.conversions = [item]
        model.reconvert(item)
        let started = await waitForInvocationCount(1, from: runner)
        XCTAssertTrue(started)
        guard started else { model.stopNow(); return }
        await model.cleanUpForQuit()
        XCTAssertEqual(model.queuePhase, .idle)
        XCTAssertEqual(item.status, .done(outputURL: previousOutput))
        XCTAssertEqual(model.document().conversions.first?.outputURL, previousOutput)
        XCTAssertNil(model.queueDriverTask)
        XCTAssertNil(model.analysisTask)
    }

    func testFailedVerificationKeepsReportAndDoesNotAnnounceSuccess() async {
        let model = AppModel(conversionRunner: { request, onEvent in
            onEvent(.finished(.init(outputURL: request.outputURL,
                                    checks: [.init(name: "Required stereo", passed: false, detail: "Missing stereo track")],
                                    producedAt: Date())))
        }, systemFeedbackEnabled: false)
        model.outputFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let item = QueueTestFixture.runnable("Verification failure")
        model.conversions = [item]
        model.selectedIDs = [item.id]
        model.convertSelected()
        let finished = await waitUntil { model.queuePhase == .idle }
        XCTAssertTrue(finished)
        XCTAssertFalse(item.status.isDone)
        XCTAssertNotNil(item.failureMessage)
        XCTAssertEqual(item.report?.checks.first?.name, "Required stereo")
        XCTAssertTrue(model.canRetry(item))
        XCTAssertFalse(model.toasts.toasts.contains { $0.tone == .success && $0.title.contains("is ready") })
        XCTAssertEqual(model.workspace.history.last?.passed, false)
    }

    func testFilenamePatternsRemainWithinChosenDestination() {
        let model = AppModel(systemFeedbackEnabled: false)
        model.outputFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let item = QueueTestFixture.conversion("Source")
        for pattern in ["../{name}", "folder/{name}", "\\\\server\\{name}", "", "...", "{name}\n.mov"] {
            model.filenamePattern = pattern
            let output = model.outputURL(for: item).standardizedFileURL
            XCTAssertEqual(output.deletingLastPathComponent().path, model.outputFolder.standardizedFileURL.path, pattern)
            XCTAssertEqual(output.pathExtension, "mov")
            XCTAssertFalse(output.deletingPathExtension().lastPathComponent.isEmpty)
        }
    }

    func testWorkspaceRoundtripPreservesPlansOverridesVariantsAndBookmarks() throws {
        let model = AppModel(systemFeedbackEnabled: false)
        let item = plannedVideo()
        item.depthOverrides = .init(global: .init(convergence: 0.7), shots: [0: .init(strengthPercent: 1.4)])
        item.bookmarks = [1.25, 6.5]
        model.conversions = [item]
        model.selectionID = item.id
        model.playhead = 6.5
        model.workspace.variants = [.init(name: "Gentle", sourceID: item.id, tuning: item.tuning, overrides: item.depthOverrides)]
        let document = model.document()
        let data = try JSONEncoder().encode(document)
        let restored = try JSONDecoder().decode(WorkspaceDocument.self, from: data)
        XCTAssertEqual(restored.version, 1)
        XCTAssertEqual(restored.selectionID, item.id)
        XCTAssertEqual(restored.playhead, 6.5)
        XCTAssertEqual(restored.conversions.first?.overrides, item.depthOverrides)
        XCTAssertEqual(restored.conversions.first?.bookmarks, item.bookmarks)
        XCTAssertEqual(restored.conversions.first?.plan?.shots.count, 2)
        XCTAssertEqual(restored.conversions.first?.plan?.shots.last?.end.seconds, 10)
        XCTAssertEqual(restored.variants, model.workspace.variants)
    }

    func testRestoreKeepsCompletedExportWhenOriginalIsUnavailable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("Finished.mov")
        try Data([0]).write(to: output)
        let item = Conversion(sourceURL: folder.appendingPathComponent("Moved original.mov"))
        item.status = .done(outputURL: output)
        item.exportedTuning = item.tuning
        item.exportedDepthOverrides = item.depthOverrides
        let source = AppModel(systemFeedbackEnabled: false)
        source.conversions = [item]
        let restored = AppModel(systemFeedbackEnabled: false)
        try restored.restore(source.document())
        let result = try XCTUnwrap(restored.conversions.first)
        guard case .done(let restoredOutput) = result.status else {
            return XCTFail("An existing export must remain available when only its original is missing")
        }
        XCTAssertEqual(restoredOutput, output)
        XCTAssertTrue(result.sourceMissing)
        XCTAssertFalse(result.canMoveInQueue)
    }

    func testUndoRemovalRequeuesInterruptedAnalysis() {
        let model = AppModel(systemFeedbackEnabled: false)
        let item = QueueTestFixture.runnable("Interrupted analysis")
        item.planningProgress = 0.5
        model.conversions = [item]
        model.analysisWaiting = [item.id]
        model.remove(item)
        XCTAssertTrue(model.conversions.isEmpty)
        model.editUndoManager.undo()
        XCTAssertEqual(model.conversions.first?.id, item.id)
        XCTAssertNotNil(item.planningProgress, "Undo should resume preparation before this video is exportable")
        model.cancelAnalysis(item)
    }

    func testRemovingLastVideoClearsOriginalPlayback() {
        let model = AppModel(systemFeedbackEnabled: false)
        let item = plannedVideo()
        model.conversions = [item]
        model.select(item)
        XCTAssertNotNil(model.playback.player.currentItem)
        model.remove(item)
        XCTAssertNil(model.selectionID)
        XCTAssertNil(model.playback.player.currentItem)
        XCTAssertNil(model.playback.sourceURL)
    }

    func testVisibleRangeAndSelectAllExcludeHiddenRows() {
        let model = AppModel(systemFeedbackEnabled: false)
        let first = QueueTestFixture.conversion("Match A")
        let hidden = QueueTestFixture.conversion("Hidden")
        let last = QueueTestFixture.conversion("Match B")
        model.conversions = [first, hidden, last]
        let visible = [first.id, last.id]
        model.select(first)
        model.extendSelection(to: last, visibleOrder: visible)
        XCTAssertEqual(model.selectedIDs, Set(visible))
        model.visibleQueueIDs = visible
        model.selectAll()
        XCTAssertEqual(model.selectedIDs, Set(visible))
        XCTAssertFalse(model.selectedIDs.contains(hidden.id))
        model.visibleQueueIDs = []
        model.selectAll()
        XCTAssertTrue(model.selectedIDs.isEmpty, "A zero-result search must not select hidden videos")
        model.visibleQueueIDs = nil
        model.selectAll()
        XCTAssertEqual(model.selectedIDs, Set([first.id, hidden.id, last.id]))
    }

    private func model(runner: ControlledConversionRunner) -> AppModel {
        let model = AppModel(conversionRunner: { request, onEvent in
            await runner.run(request, onEvent: onEvent)
        }, systemFeedbackEnabled: false)
        model.outputFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return model
    }
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
    private func plannedVideo() -> Conversion {
        let item = QueueTestFixture.runnable("Planned", duration: 10)
        let settings = [
            AutoTune.Result(strength: 0.006, convergence: 0.6, predictedLoad: 0.5, confidence: 0.5),
            AutoTune.Result(strength: 0.012, convergence: 0.8, predictedLoad: 0.5, confidence: 0.5)
        ]
        item.shotPlan = ShotPlan(shots: (0..<2).map { index in
            Shot(id: index, start: time(Double(index) * 5), end: time(Double(index + 1) * 5),
                 content: .unknown, settings: settings[index])
        }, samplesTaken: 20, seconds: 1)
        return item
    }
}
