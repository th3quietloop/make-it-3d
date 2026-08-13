import XCTest
@testable import MakeIt3D

@MainActor
final class QueueOrderingAndSummaryTests: XCTestCase {
    func testReorderMovesOnlyReadySlotsAndPreservesSelection() {
        let model = AppModel(systemFeedbackEnabled: false)
        let first = QueueTestFixture.conversion("First")
        let failed = QueueTestFixture.conversion("Failed", status: .failed("Test failure"))
        let second = QueueTestFixture.conversion("Second")
        let probing = QueueTestFixture.conversion("Probing", status: .probing)
        let third = QueueTestFixture.conversion("Third")
        model.conversions = [first, failed, second, probing, third]
        model.selectionID = second.id
        model.selectedIDs = [second.id, third.id]

        model.reorderQueued(ids: [third.id], before: first.id, announce: false)

        XCTAssertConversionOrder(model.queuedWaiting, [third, first, second])
        XCTAssertConversionOrder(model.conversions, [third, failed, first, probing, second])
        XCTAssertEqual(model.selectionID, second.id)
        XCTAssertEqual(model.selectedIDs, [second.id, third.id])
    }

    func testQueuePositionsCountOnlyRunnableWaitingRows() {
        let model = AppModel(systemFeedbackEnabled: false)
        let failed = QueueTestFixture.conversion("Failed", status: .failed("Test failure"))
        let first = QueueTestFixture.conversion("First")
        let active = QueueTestFixture.conversion(
            "Active",
            status: .converting(fraction: 0.5, framesDone: 15)
        )
        let finished = QueueTestFixture.conversion(
            "Finished",
            status: .done(outputURL: QueueTestFixture.sourceURL("Finished spatial"))
        )
        let second = QueueTestFixture.conversion("Second")
        model.conversions = [failed, first, active, finished, second]

        XCTAssertEqual(model.queuePosition(for: first), .next)
        XCTAssertEqual(model.queuePosition(for: second), .numbered(2))
        XCTAssertNil(model.queuePosition(for: failed))
        XCTAssertNil(model.queuePosition(for: active))
        XCTAssertNil(model.queuePosition(for: finished))
        XCTAssertEqual(model.nextWaitingConversion?.id, first.id)
    }

    func testQueueSummaryCombinesKnownEstimatesAndMarksUnknownWork() throws {
        let model = AppModel(systemFeedbackEnabled: false)
        let first = QueueTestFixture.runnable(
            "First",
            duration: 2,
            framesPerSecond: 10,
            width: 100,
            height: 50
        )
        let second = QueueTestFixture.runnable(
            "Second",
            duration: 3,
            framesPerSecond: 20,
            width: 200,
            height: 100
        )
        let preparing = QueueTestFixture.conversion("Preparing", status: .probing)
        let failed = QueueTestFixture.conversion("Failed", status: .failed("Test failure"))
        model.conversions = [first, second, preparing, failed]

        let firstProbe = try XCTUnwrap(first.probe)
        let secondProbe = try XCTUnwrap(second.probe)
        let expectedBytes = outputBytes(firstProbe) + outputBytes(secondProbe)
        let expectedSeconds = Double(firstProbe.estimatedFrameCount)
            / first.tuning.depthModel.measuredFramesPerSecond
            + Double(secondProbe.estimatedFrameCount)
            / second.tuning.depthModel.measuredFramesPerSecond
        let summary = model.queueWorkSummary

        XCTAssertEqual(summary.totalCount, 4)
        XCTAssertEqual(summary.waitingCount, 2)
        XCTAssertEqual(summary.preparingCount, 1)
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(summary.activeCount, 0)
        XCTAssertEqual(summary.completedCount, 0)
        XCTAssertEqual(summary.skippedCount, 0)
        XCTAssertEqual(summary.unknownTimeCount, 1)
        XCTAssertEqual(summary.unknownSizeCount, 1)
        XCTAssertEqual(summary.knownRemainingSeconds, expectedSeconds, accuracy: 0.000_001)
        XCTAssertEqual(summary.knownOutputBytes, expectedBytes)

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        XCTAssertEqual(
            model.queueOutputEstimateText,
            "About \(formatter.string(fromByteCount: expectedBytes))+ output"
        )
        XCTAssertEqual(
            model.queueSummaryText,
            "4 videos • about \(AppModel.humanDuration(expectedSeconds))+"
        )
    }

    func testChangedSettingsExportCountsAsWaitingWithTimeAndOutputEstimate() throws {
        let model = AppModel(systemFeedbackEnabled: false)
        let conversion = QueueTestFixture.runnable(
            "Changed Export",
            duration: 2,
            framesPerSecond: 10,
            width: 100,
            height: 50
        )
        conversion.status = .done(
            outputURL: QueueTestFixture.sourceURL("Changed Export prior spatial")
        )
        conversion.exportedTuning = .default
        var changed = EngineTuning.default
        changed.convergence = 0.25
        conversion.tuning = changed
        model.conversions = [conversion]

        let probe = try XCTUnwrap(conversion.probe)
        let expectedBytes = outputBytes(probe)
        let expectedSeconds = Double(probe.estimatedFrameCount)
            / conversion.tuning.depthModel.measuredFramesPerSecond
        let summary = model.queueWorkSummary

        XCTAssertTrue(conversion.settingsChangedSinceExport)
        XCTAssertEqual(summary.totalCount, 1)
        XCTAssertEqual(summary.waitingCount, 1)
        XCTAssertEqual(summary.completedCount, 0)
        XCTAssertEqual(summary.failedCount, 0)
        XCTAssertEqual(summary.unknownTimeCount, 0)
        XCTAssertEqual(summary.unknownSizeCount, 0)
        XCTAssertEqual(summary.knownRemainingSeconds, expectedSeconds, accuracy: 0.000_001)
        XCTAssertEqual(summary.knownOutputBytes, expectedBytes)

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        XCTAssertEqual(
            model.queueSummaryText,
            "1 video • about \(AppModel.humanDuration(expectedSeconds))"
        )
        XCTAssertEqual(
            model.queueOutputEstimateText,
            "About \(formatter.string(fromByteCount: expectedBytes)) output"
        )
    }

    private func outputBytes(_ probe: SourceProbe) -> Int64 {
        Int64(
            Double(probe.width * probe.height)
                * probe.nominalFrameRate
                * 0.15
                / 8
                * probe.duration.seconds
        )
    }
}
