import XCTest
@testable import MakeIt3D

@MainActor
final class QueueSchedulerTests: XCTestCase {
    func testConvertSelectedRunsOnlyTheExactSelectedSnapshot() async {
        let runner = ControlledConversionRunner()
        let model = makeModel(runner: runner)
        let first = QueueTestFixture.runnable("First")
        let selected = QueueTestFixture.runnable("Selected")
        let third = QueueTestFixture.runnable("Third")
        model.conversions = [first, selected, third]
        model.selectedIDs = [selected.id]

        model.convertSelected()
        await runner.waitForInvocation(count: 1)

        XCTAssertEqual(model.currentRunScope, .selectedSnapshot)
        let startedNames = await runner.sourceNames()
        XCTAssertEqual(startedNames, ["Selected"])
        XCTAssertNil(model.queuePosition(for: first))
        XCTAssertNil(model.queuePosition(for: third))

        await runner.finish(1)
        let becameIdle = await waitUntil { model.queuePhase == .idle }
        let invocationCount = await runner.invocationCount()

        XCTAssertTrue(becameIdle)
        XCTAssertEqual(invocationCount, 1)
        XCTAssertTrue(first.status.isReady)
        XCTAssertTrue(third.status.isReady)
        XCTAssertTrue(selected.status.isDone)
    }

    func testConvertAllUsesAllReadyScopeAndCanonicalOrder() async {
        let runner = ControlledConversionRunner()
        let model = makeModel(runner: runner)
        let first = QueueTestFixture.runnable("First")
        let second = QueueTestFixture.runnable("Second")
        let third = QueueTestFixture.runnable("Third")
        model.conversions = [first, second, third]
        model.selectedIDs = [second.id]

        model.convertAllReady()
        await runner.waitForInvocation(count: 1)
        XCTAssertEqual(model.currentRunScope, .allReadyIncludingAdditions)

        await runner.finish(1)
        await runner.waitForInvocation(count: 2)
        await runner.finish(2)
        await runner.waitForInvocation(count: 3)
        await runner.finish(3)
        let becameIdle = await waitUntil { model.queuePhase == .idle }
        let startedNames = await runner.sourceNames()

        XCTAssertTrue(becameIdle)
        XCTAssertEqual(startedNames, ["First", "Second", "Third"])
        XCTAssertTrue(model.conversions.allSatisfy(\.status.isDone))
    }

    func testGroupPromotionPreservesOrderAndSelectionAndAdmitsTheGroup() async {
        let runner = ControlledConversionRunner()
        let model = makeModel(runner: runner)
        let active = QueueTestFixture.runnable("Active")
        let outsider = QueueTestFixture.runnable("Outsider")
        let groupFirst = QueueTestFixture.runnable("Group First")
        let groupSecond = QueueTestFixture.runnable("Group Second")
        model.conversions = [active, outsider, groupFirst, groupSecond]
        model.selectedIDs = [active.id]
        model.selectionID = active.id

        model.convertSelected()
        await runner.waitForInvocation(count: 1)

        model.selectedIDs = [groupFirst.id, groupSecond.id]
        model.selectionID = groupFirst.id
        model.prioritize(model.priorityCandidates(for: groupFirst))

        XCTAssertConversionOrder(model.queuedWaiting, [groupFirst, groupSecond, outsider])
        XCTAssertEqual(model.selectedIDs, [groupFirst.id, groupSecond.id])
        XCTAssertEqual(model.selectionID, groupFirst.id)
        XCTAssertEqual(model.queuePosition(for: groupFirst), .next)
        XCTAssertEqual(model.queuePosition(for: groupSecond), .numbered(2))
        XCTAssertNil(model.queuePosition(for: outsider))

        await runner.finish(1)
        await runner.waitForInvocation(count: 2)
        await runner.finish(2)
        await runner.waitForInvocation(count: 3)
        await runner.finish(3)
        let becameIdle = await waitUntil { model.queuePhase == .idle }
        let startedNames = await runner.sourceNames()

        XCTAssertTrue(becameIdle)
        XCTAssertEqual(
            startedNames,
            ["Active", "Group First", "Group Second"]
        )
        XCTAssertTrue(outsider.status.isReady)
    }

    func testDragReorderDoesNotExpandASelectedRun() async {
        let runner = ControlledConversionRunner()
        let model = makeModel(runner: runner)
        let selected = QueueTestFixture.runnable("Selected")
        let waiting = QueueTestFixture.runnable("Waiting")
        let dragged = QueueTestFixture.runnable("Dragged")
        model.conversions = [selected, waiting, dragged]
        model.selectedIDs = [selected.id]

        model.convertSelected()
        await runner.waitForInvocation(count: 1)
        model.reorderQueued(ids: [dragged.id], before: waiting.id)

        XCTAssertConversionOrder(model.queuedWaiting, [dragged, waiting])
        XCTAssertNil(model.queuePosition(for: dragged))

        await runner.finish(1)
        let becameIdle = await waitUntil { model.queuePhase == .idle }
        let invocationCount = await runner.invocationCount()

        XCTAssertTrue(becameIdle)
        XCTAssertEqual(invocationCount, 1)
        XCTAssertTrue(dragged.status.isReady)
        XCTAssertTrue(waiting.status.isReady)
    }

    func testRetryClearsFailureStateAndRunsASeparateAttempt() async {
        let runner = ControlledConversionRunner()
        let model = makeModel(runner: runner)
        let conversion = QueueTestFixture.runnable("Retry Me")
        let originalTuning = conversion.tuning
        model.conversions = [conversion]

        model.convertAllReady()
        await runner.waitForInvocation(count: 1)
        await runner.fail(1)
        let firstRunBecameIdle = await waitUntil { model.queuePhase == .idle }
        XCTAssertTrue(firstRunBecameIdle)
        XCTAssertEqual(conversion.failureKind, .conversion)
        guard case .failed = conversion.status else {
            return XCTFail("The first attempt should fail")
        }

        let firstRequest = await runner.request(for: 1)
        conversion.report = QueueTestFixture.report(for: firstRequest)
        conversion.startedAt = Date(timeIntervalSince1970: 10)

        model.retry(conversion)
        await runner.waitForInvocation(count: 2)

        XCTAssertEqual(model.currentRunScope, .retryGroup)
        XCTAssertNil(conversion.report)
        XCTAssertNil(conversion.failureKind)
        XCTAssertEqual(conversion.tuning, originalTuning)
        XCTAssertTrue(conversion.status.isConverting)

        await runner.finish(2)
        let retryBecameIdle = await waitUntil { model.queuePhase == .idle }
        let startedNames = await runner.sourceNames()
        XCTAssertTrue(retryBecameIdle)
        XCTAssertEqual(startedNames, ["Retry Me", "Retry Me"])
        XCTAssertTrue(conversion.status.isDone)
    }

    func testPauseAfterCurrentFinishesOneAndResumeKeepsTheRun() async {
        let runner = ControlledConversionRunner()
        let model = makeModel(runner: runner)
        let first = QueueTestFixture.runnable("First")
        let second = QueueTestFixture.runnable("Second")
        model.conversions = [first, second]

        model.convertAllReady()
        await runner.waitForInvocation(count: 1)
        model.pauseAfterCurrent()

        XCTAssertEqual(model.queuePhase, .pauseAfterCurrent)
        await runner.finish(1)
        let becamePaused = await waitUntil { model.queuePhase == .paused }
        let pausedInvocationCount = await runner.invocationCount()
        XCTAssertTrue(becamePaused)
        XCTAssertEqual(pausedInvocationCount, 1)
        XCTAssertTrue(first.status.isDone)
        XCTAssertTrue(second.status.isReady)
        XCTAssertEqual(model.queuePosition(for: second), .next)

        model.resumeQueue()
        await runner.waitForInvocation(count: 2)
        await runner.finish(2)

        let becameIdle = await waitUntil { model.queuePhase == .idle }
        let startedNames = await runner.sourceNames()
        XCTAssertTrue(becameIdle)
        XCTAssertEqual(startedNames, ["First", "Second"])
    }

    func testStopAfterCurrentFinishesOneAndClearsTheRun() async {
        let runner = ControlledConversionRunner()
        let model = makeModel(runner: runner)
        let first = QueueTestFixture.runnable("First")
        let second = QueueTestFixture.runnable("Second")
        model.conversions = [first, second]

        model.convertAllReady()
        await runner.waitForInvocation(count: 1)
        model.stopAfterCurrent()

        XCTAssertEqual(model.queuePhase, .stopAfterCurrent)
        await runner.finish(1)
        let becameIdle = await waitUntil { model.queuePhase == .idle }
        let invocationCount = await runner.invocationCount()
        XCTAssertTrue(becameIdle)

        XCTAssertEqual(invocationCount, 1)
        XCTAssertTrue(first.status.isDone)
        XCTAssertTrue(second.status.isReady)
        XCTAssertNil(model.currentRunScope)
    }

    func testStopNowCancelsWorkerAndIgnoresLateFinish() async {
        let runner = ControlledConversionRunner()
        let model = makeModel(runner: runner)
        let first = QueueTestFixture.runnable("First")
        let second = QueueTestFixture.runnable("Second")
        model.conversions = [first, second]

        model.convertAllReady()
        await runner.waitForInvocation(count: 1)
        await runner.sendProgress(0.5, framesDone: 15, to: 1)
        let receivedProgress = await waitUntil {
            if case .converting(let fraction, _) = first.status { return fraction == 0.5 }
            return false
        }
        XCTAssertTrue(receivedProgress)

        model.stopNow()
        await runner.waitForCancellation(of: 1)
        let becameIdle = await waitUntil { model.queuePhase == .idle }
        let receivedCancellation = await runner.receivedCancellation(for: 1)
        let invocationCount = await runner.invocationCount()

        XCTAssertTrue(becameIdle)
        XCTAssertTrue(receivedCancellation)
        XCTAssertEqual(invocationCount, 1)
        XCTAssertTrue(first.status.isReady)
        XCTAssertNil(first.report)
        XCTAssertTrue(second.status.isReady)

        await runner.sendLateFinish(1)
        try? await Task.sleep(for: .milliseconds(30))
        let finalInvocationCount = await runner.invocationCount()

        XCTAssertTrue(first.status.isReady)
        XCTAssertNil(first.report)
        XCTAssertEqual(finalInvocationCount, 1)
    }

    func testSkipWaitingAndActiveRowsContinuesWithEligibleWork() async {
        let runner = ControlledConversionRunner()
        let model = makeModel(runner: runner)
        let active = QueueTestFixture.runnable("Active")
        let next = QueueTestFixture.runnable("Next")
        let waitingToSkip = QueueTestFixture.runnable("Waiting to Skip")
        model.conversions = [active, next, waitingToSkip]

        model.convertAllReady()
        await runner.waitForInvocation(count: 1)

        model.skip(waitingToSkip)
        XCTAssertFalse(model.canSkip(waitingToSkip))
        XCTAssertTrue(waitingToSkip.status.isReady)
        XCTAssertNil(model.queuePosition(for: waitingToSkip))
        XCTAssertEqual(model.queueWorkSummary.skippedCount, 1)

        model.skip(active)
        await runner.waitForCancellation(of: 1)
        await runner.waitForInvocation(count: 2)
        let receivedCancellation = await runner.receivedCancellation(for: 1)
        let secondRequest = await runner.request(for: 2)

        XCTAssertTrue(active.status.isReady)
        XCTAssertTrue(receivedCancellation)
        XCTAssertEqual(secondRequest.probe.url, next.probe?.url)

        await runner.finish(2)
        let becameIdle = await waitUntil { model.queuePhase == .idle }
        let startedNames = await runner.sourceNames()

        XCTAssertTrue(becameIdle)
        XCTAssertEqual(startedNames, ["Active", "Next"])
        XCTAssertTrue(active.status.isReady)
        XCTAssertTrue(waitingToSkip.status.isReady)
        XCTAssertTrue(next.status.isDone)
    }

    private func makeModel(runner: ControlledConversionRunner) -> AppModel {
        let model = AppModel(
            conversionRunner: { request, onEvent in
                await runner.run(request, onEvent: onEvent)
            },
            systemFeedbackEnabled: false
        )
        model.outputFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakeIt3DQueueTests-\(UUID().uuidString)")
        return model
    }
}
