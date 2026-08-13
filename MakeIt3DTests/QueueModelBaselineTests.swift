import XCTest
@testable import MakeIt3D

/// Fast contracts around the queue's current derived state.
///
/// Scheduler transition tests live separately behind the injected conversion
/// runner. These tests keep the model's inexpensive derived-state contracts
/// visible and fast.
@MainActor
final class QueueModelBaselineTests: XCTestCase {
    func testQueueSectionsPreserveStableOrderAndPinActiveWork() {
        let model = AppModel()
        let finishedFirst = QueueTestFixture.conversion(
            "Finished First",
            status: .done(outputURL: QueueTestFixture.sourceURL("Finished First spatial"))
        )
        let waiting = QueueTestFixture.conversion("Waiting")
        let failed = QueueTestFixture.conversion("Failed", status: .failed("Test failure"))
        let active = QueueTestFixture.conversion(
            "Active",
            status: .converting(fraction: 0.4, framesDone: 40)
        )
        let probing = QueueTestFixture.conversion("Probing", status: .probing)
        let finishedSecond = QueueTestFixture.conversion(
            "Finished Second",
            status: .done(outputURL: QueueTestFixture.sourceURL("Finished Second spatial"))
        )
        model.conversions = [finishedFirst, waiting, failed, active, probing, finishedSecond]

        XCTAssertConversionOrder(model.finished, [finishedFirst, finishedSecond])
        XCTAssertConversionOrder(model.upNext, [active, waiting, failed, probing])
        XCTAssertConversionOrder(model.readyToConvert, [waiting])
    }

    func testSelectedReadyPreservesQueueOrderRatherThanSetInsertionOrder() {
        let model = AppModel()
        let first = QueueTestFixture.conversion("First")
        let second = QueueTestFixture.conversion("Second")
        let third = QueueTestFixture.conversion("Third")
        model.conversions = [first, second, third]
        model.selectedIDs = [third.id, first.id]

        XCTAssertConversionOrder(model.selectedConversions, [first, third])
        XCTAssertConversionOrder(model.selectedReady, [first, third])
        XCTAssertTrue(model.hasUnselectedWork)
    }

    func testSelectedReadyExcludesRowsThatCannotCurrentlyRun() {
        let model = AppModel()
        let ready = QueueTestFixture.conversion("Ready")
        let probing = QueueTestFixture.conversion("Probing", status: .probing)
        let failed = QueueTestFixture.conversion("Failed", status: .failed("Test failure"))
        let active = QueueTestFixture.conversion(
            "Active",
            status: .converting(fraction: 0.2, framesDone: 20)
        )
        model.conversions = [ready, probing, failed, active]
        model.selectedIDs = Set(model.conversions.map(\.id))

        XCTAssertConversionOrder(model.selectedReady, [ready])
        XCTAssertFalse(model.hasUnselectedWork)
    }

    func testNewReadyVideoAppearsAtEndOfConvertAllCandidates() {
        let model = AppModel()
        let first = QueueTestFixture.conversion("First")
        let second = QueueTestFixture.conversion("Second")
        let addedLater = QueueTestFixture.conversion("Added Later")
        model.conversions = [first, second]

        XCTAssertConversionOrder(model.readyToConvert, [first, second])

        model.conversions.append(addedLater)

        XCTAssertConversionOrder(model.readyToConvert, [first, second, addedLater])
    }

    func testFailedVideoRemainsVisibleOutsideReadyCandidates() {
        let model = AppModel()
        let failed = QueueTestFixture.conversion("Failed", status: .failed("Test failure"))
        model.conversions = [failed]
        model.selectedIDs = [failed.id]

        XCTAssertConversionOrder(model.upNext, [failed])
        XCTAssertTrue(model.readyToConvert.isEmpty)
        XCTAssertTrue(model.selectedReady.isEmpty)
        XCTAssertTrue(model.canRetry(failed))
    }

    func testFinishedVideoWithChangedSettingsIsAReconversionCandidate() {
        let model = AppModel()
        let finished = QueueTestFixture.conversion(
            "Finished",
            status: .done(outputURL: QueueTestFixture.sourceURL("Finished spatial"))
        )
        finished.exportedTuning = .default
        var changedTuning = EngineTuning.default
        changedTuning.convergence = 0.25
        finished.tuning = changedTuning
        model.conversions = [finished]

        XCTAssertTrue(finished.settingsChangedSinceExport)
        XCTAssertConversionOrder(model.readyToConvert, [finished])
        XCTAssertConversionOrder(model.upNext, [finished])
        XCTAssertTrue(model.finished.isEmpty)
    }

    func testQueueProgressComesFromActiveVideoNotFocusedVideo() {
        let model = AppModel()
        let focused = QueueTestFixture.conversion("Focused")
        let active = QueueTestFixture.conversion(
            "Active",
            status: .converting(fraction: 0.42, framesDone: 42)
        )
        model.conversions = [focused, active]
        model.selectionID = focused.id

        XCTAssertEqual(model.activeConversion?.id, active.id)
        XCTAssertEqual(model.queueProgress, 0.42, accuracy: 0.000_001)
    }

    func testOutputEstimateMatchesTheWriterBitrateRule() {
        let probe = QueueTestFixture.probe(
            duration: 10,
            framesPerSecond: 30,
            width: 1_920,
            height: 1_080
        )
        let expectedBytes = Int64(
            Double(probe.width * probe.height)
                * probe.nominalFrameRate
                * 0.15
                / 8
                * probe.duration.seconds
        )
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        XCTAssertEqual(
            AppModel.estimatedSize(for: probe),
            formatter.string(fromByteCount: expectedBytes)
        )
    }
}
