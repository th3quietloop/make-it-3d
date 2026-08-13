import XCTest
@testable import MakeIt3D

@MainActor
final class QueueFreshEdgeRegressionTests: XCTestCase {
    func testActiveTuningUpdateIsBlockedWithoutStartingAnotherInvocation() async {
        let runner = ControlledConversionRunner()
        let model = makeModel(runner: runner)
        let conversion = QueueTestFixture.runnable("Active")
        model.conversions = [conversion]
        model.selectedIDs = [conversion.id]

        model.convertSelected()
        await runner.waitForInvocation(count: 1)
        let frozenTuning = conversion.tuning
        var attemptedTuning = frozenTuning
        attemptedTuning.convergence = 0.25

        model.updateTuning(attemptedTuning, for: conversion)
        model.convertSelected()
        try? await Task.sleep(for: .milliseconds(30))

        let invocationCount = await runner.invocationCount()
        let request = await runner.request(for: 1)
        XCTAssertEqual(conversion.tuning, frozenTuning)
        XCTAssertEqual(request.tuning, frozenTuning)
        XCTAssertEqual(invocationCount, 1)

        model.stopNow()
        await runner.waitForCancellation(of: 1)
        let becameIdle = await awaitQueuePhase(.idle, model: model)
        XCTAssertTrue(becameIdle)
    }

    func testAdmittedChangedSettingsExportCanBeSkippedWithoutLosingPriorOutput() async {
        let runner = ControlledConversionRunner()
        let model = makeModel(runner: runner)
        let active = QueueTestFixture.runnable("Active")
        let (changed, priorURL) = changedExport("Changed")
        model.conversions = [active, changed]

        model.convertAllReady()
        await runner.waitForInvocation(count: 1)

        XCTAssertTrue(model.isInCurrentRun(changed))
        XCTAssertTrue(model.canSkip(changed))
        model.skip(changed)

        XCTAssertTrue(model.isSkippedInCurrentRun(changed))
        XCTAssertEqual(changed.status, .done(outputURL: priorURL))
        XCTAssertTrue(changed.settingsChangedSinceExport)
        XCTAssertEqual(model.queueWorkSummary.skippedCount, 1)

        await runner.finish(1)
        let becameIdle = await awaitQueuePhase(.idle, model: model)
        let invocationCount = await runner.invocationCount()
        if !becameIdle {
            model.stopNow()
            if invocationCount > 1 {
                await runner.waitForCancellation(of: invocationCount)
            }
        }
        XCTAssertTrue(becameIdle)
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(changed.status, .done(outputURL: priorURL))
    }

    func testCancelledChangedSettingsReexportRestoresPriorDoneURL() async {
        let runner = ControlledConversionRunner()
        let model = makeModel(runner: runner)
        let (conversion, priorURL) = changedExport("Cancelled Reexport")
        model.conversions = [conversion]

        model.convertAllReady()
        await runner.waitForInvocation(count: 1)
        model.stopNow()
        await runner.waitForCancellation(of: 1)

        let becameIdle = await awaitQueuePhase(.idle, model: model)
        XCTAssertTrue(becameIdle)
        XCTAssertEqual(conversion.status, .done(outputURL: priorURL))
        XCTAssertTrue(conversion.settingsChangedSinceExport)
        XCTAssertNil(conversion.failureKind)
    }

    func testFailedChangedSettingsReexportRestoresPriorDoneURLAndDoesNotLoop() async {
        let runner = ControlledConversionRunner()
        let model = makeModel(runner: runner)
        let (conversion, priorURL) = changedExport("Failed Reexport")
        model.conversions = [conversion]

        model.convertAllReady()
        await runner.waitForInvocation(count: 1)
        await runner.fail(1)
        let becameIdle = await awaitQueuePhase(.idle, model: model)
        let invocationCount = await runner.invocationCount()

        if !becameIdle {
            model.stopNow()
            if invocationCount > 1 {
                await runner.waitForCancellation(of: invocationCount)
            }
        }
        XCTAssertTrue(becameIdle)
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(conversion.status, .done(outputURL: priorURL))
        XCTAssertTrue(conversion.settingsChangedSinceExport)
        XCTAssertEqual(conversion.failureKind, .conversion)
    }

    func testExplicitReconvertPreservesPriorOutputAndReportAfterCancellationAndFailure() async {
        let runner = ControlledConversionRunner()
        let model = makeModel(runner: runner)
        let conversion = QueueTestFixture.runnable("Explicit Redo")
        let priorURL = QueueTestFixture.sourceURL("Explicit Redo prior spatial")
        let priorReport = VerificationReport(
            outputURL: priorURL,
            checks: [
                .init(name: "Existing export", passed: true, detail: "Keep this report")
            ],
            producedAt: Date(timeIntervalSince1970: 123)
        )
        conversion.status = .done(outputURL: priorURL)
        conversion.exportedTuning = conversion.tuning
        conversion.report = priorReport
        model.conversions = [conversion]

        XCTAssertFalse(conversion.settingsChangedSinceExport)
        model.reconvert(conversion)
        let cancellationAttemptStarted = await waitForInvocationCount(1, from: runner)
        XCTAssertTrue(cancellationAttemptStarted)
        guard cancellationAttemptStarted else {
            model.stopNow()
            return
        }

        model.stopNow()
        await runner.waitForCancellation(of: 1)
        let cancellationBecameIdle = await awaitQueuePhase(.idle, model: model)
        let countAfterCancellation = await runner.invocationCount()

        XCTAssertTrue(cancellationBecameIdle)
        XCTAssertEqual(countAfterCancellation, 1)
        XCTAssertEqual(conversion.status, .done(outputURL: priorURL))
        XCTAssertEqual(conversion.report?.text, priorReport.text)
        XCTAssertFalse(conversion.settingsChangedSinceExport)
        XCTAssertNil(conversion.failureKind)

        model.reconvert(conversion)
        let failureAttemptStarted = await waitForInvocationCount(2, from: runner)
        XCTAssertTrue(failureAttemptStarted)
        guard failureAttemptStarted else {
            model.stopNow()
            return
        }

        await runner.fail(2)
        let failureBecameIdle = await awaitQueuePhase(.idle, model: model)
        let finalInvocationCount = await runner.invocationCount()

        if !failureBecameIdle { model.stopNow() }
        XCTAssertTrue(failureBecameIdle)
        XCTAssertEqual(finalInvocationCount, 2)
        XCTAssertEqual(conversion.status, .done(outputURL: priorURL))
        XCTAssertEqual(conversion.report?.text, priorReport.text)
        XCTAssertFalse(conversion.settingsChangedSinceExport)
        XCTAssertEqual(conversion.failureKind, .conversion)
    }

    func testPlanningRowsAreExcludedUntilAReadyNudgeResumesTheDriver() async {
        let runner = ControlledConversionRunner()
        let model = makeModel(runner: runner)
        let active = QueueTestFixture.runnable("Active")
        let nudgeAnchor = QueueTestFixture.runnable("Skipped Nudge Anchor")
        let planning = QueueTestFixture.runnable("Planning")
        model.conversions = [active, nudgeAnchor, planning]

        model.convertAllReady()
        await runner.waitForInvocation(count: 1)
        model.skip(nudgeAnchor)
        planning.planningProgress = 0.5

        XCTAssertFalse(model.readyToConvert.contains { $0.id == planning.id })
        XCTAssertFalse(model.selectedReady.contains { $0.id == planning.id })
        XCTAssertFalse(model.queuedWaiting.contains { $0.id == planning.id })
        XCTAssertNil(model.queuePosition(for: planning))

        await runner.finish(1)
        let waitingForPlanning = await waitUntil {
            model.queuePhase == .running && model.activeConversion == nil
        }
        try? await Task.sleep(for: .milliseconds(30))
        let invocationCountBeforeNudge = await runner.invocationCount()
        XCTAssertTrue(waitingForPlanning)
        XCTAssertEqual(invocationCountBeforeNudge, 1)

        planning.planningProgress = nil
        model.reorderQueued(ids: [planning.id], before: nudgeAnchor.id, announce: false)
        let resumed = await waitForInvocationCount(2, from: runner)
        XCTAssertTrue(resumed)
        guard resumed else {
            model.stopNow()
            return
        }

        await runner.finish(2)
        let becameIdle = await awaitQueuePhase(.idle, model: model)
        XCTAssertTrue(becameIdle)
        XCTAssertTrue(planning.status.isDone)
        XCTAssertTrue(nudgeAnchor.status.isReady)
    }

    func testPriorityAndRetryAreDisabledWhileStoppingAfterCurrent() async {
        let runner = ControlledConversionRunner()
        let model = makeModel(runner: runner)
        let active = QueueTestFixture.runnable("Active")
        let firstWaiting = QueueTestFixture.runnable("First Waiting")
        let priority = QueueTestFixture.runnable("Priority")
        let failed = QueueTestFixture.runnable("Failed")
        failed.status = .failed("Test failure")
        failed.failureKind = .conversion
        model.conversions = [active, firstWaiting, priority, failed]

        model.convertAllReady()
        await runner.waitForInvocation(count: 1)
        XCTAssertTrue(model.canPrioritize([priority]))
        XCTAssertTrue(model.canRetry(failed))

        model.stopAfterCurrent()
        let originalOrder = model.conversions.map(\.id)
        let originalFailure = failed.status

        XCTAssertFalse(model.canPrioritize([priority]))
        XCTAssertFalse(model.canRetry(failed))
        model.prioritize([priority])
        model.retry(failed)

        XCTAssertEqual(model.conversions.map(\.id), originalOrder)
        XCTAssertEqual(failed.status, originalFailure)
        XCTAssertFalse(model.isInCurrentRun(failed))

        await runner.finish(1)
        let becameIdle = await awaitQueuePhase(.idle, model: model)
        let invocationCount = await runner.invocationCount()
        XCTAssertTrue(becameIdle)
        XCTAssertEqual(invocationCount, 1)
        XCTAssertTrue(firstWaiting.status.isReady)
        XCTAssertTrue(priority.status.isReady)
    }

    func testClearFinishedDuringRunPrunesSummaryAndProgressDenominator() async {
        let runner = ControlledConversionRunner()
        let model = makeModel(runner: runner)
        let finishedFirst = QueueTestFixture.runnable("Finished First")
        let activeSecond = QueueTestFixture.runnable("Active Second")
        model.conversions = [finishedFirst, activeSecond]

        model.convertAllReady()
        await runner.waitForInvocation(count: 1)
        await runner.finish(1)
        await runner.waitForInvocation(count: 2)
        await runner.sendProgress(0.4, framesDone: 12, to: 2)
        let receivedProgress = await waitUntil {
            if case .converting(let fraction, _) = activeSecond.status {
                return fraction == 0.4
            }
            return false
        }
        XCTAssertTrue(receivedProgress)

        let before = model.queueWorkSummary
        XCTAssertEqual(before.totalCount, 2)
        XCTAssertEqual(before.completedCount, 1)
        XCTAssertEqual(before.activeCount, 1)
        XCTAssertEqual(model.queueProgress, 0.7, accuracy: 0.000_001)

        model.clearFinished()
        let after = model.queueWorkSummary

        XCTAssertFalse(model.conversions.contains { $0.id == finishedFirst.id })
        XCTAssertEqual(after.totalCount, 1)
        XCTAssertEqual(after.completedCount, 0)
        XCTAssertEqual(after.activeCount, 1)
        XCTAssertEqual(model.queueProgress, 0.4, accuracy: 0.000_001)

        model.stopNow()
        await runner.waitForCancellation(of: 2)
        let becameIdle = await awaitQueuePhase(.idle, model: model)
        XCTAssertTrue(becameIdle)
    }

    private func changedExport(_ name: String) -> (Conversion, URL) {
        let conversion = QueueTestFixture.runnable(
            name,
            duration: 2,
            framesPerSecond: 10,
            width: 100,
            height: 50
        )
        let priorURL = QueueTestFixture.sourceURL("\(name) prior spatial")
        conversion.status = .done(outputURL: priorURL)
        conversion.exportedTuning = .default
        var changed = EngineTuning.default
        changed.convergence = 0.25
        conversion.tuning = changed
        XCTAssertTrue(conversion.settingsChangedSinceExport)
        return (conversion, priorURL)
    }

    private func makeModel(runner: ControlledConversionRunner) -> AppModel {
        let model = AppModel(
            conversionRunner: { request, onEvent in
                await runner.run(request, onEvent: onEvent)
            },
            systemFeedbackEnabled: false
        )
        model.outputFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakeIt3DFreshEdgeTests-\(UUID().uuidString)")
        return model
    }

    private func awaitQueuePhase(_ phase: QueuePhase, model: AppModel) async -> Bool {
        await waitUntil { model.queuePhase == phase }
    }
}
