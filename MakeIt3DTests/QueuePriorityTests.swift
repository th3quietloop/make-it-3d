import XCTest
@testable import MakeIt3D

@MainActor
final class QueuePriorityTests: XCTestCase {
    func testWaitingVideoMovesToFrontWithoutChangingSelection() {
        let model = AppModel()
        let first = ready("First")
        let second = ready("Second")
        let priority = ready("Priority")
        model.conversions = [first, second, priority]
        model.selectionID = second.id
        model.selectedIDs = [second.id, priority.id]

        model.moveToTopOfQueue(priority)

        XCTAssertEqual(model.conversions.map(\.id), [priority.id, first.id, second.id])
        XCTAssertEqual(model.selectionID, second.id)
        XCTAssertEqual(model.selectedIDs, [second.id, priority.id])
    }

    func testActiveConversionStaysVisuallyFirstAndPriorityBecomesNext() {
        let model = AppModel()
        let waiting = ready("Waiting")
        let active = ready("Active")
        active.status = .converting(fraction: 0.25, framesDone: 10)
        let priority = ready("Priority")
        model.conversions = [waiting, active, priority]

        model.moveToTopOfQueue(priority)

        XCTAssertEqual(model.upNext.map(\.id), [active.id, priority.id, waiting.id])
        XCTAssertEqual(model.readyToConvert.map(\.id), [priority.id, waiting.id])
    }

    func testFirstWaitingVideoCannotMoveAgain() {
        let model = AppModel()
        let first = ready("First")
        let second = ready("Second")
        model.conversions = [first, second]

        XCTAssertFalse(model.canMoveToTopOfQueue(first))
        model.moveToTopOfQueue(first)

        XCTAssertEqual(model.conversions.map(\.id), [first.id, second.id])
    }

    func testOnlyReadyVideosCanMove() {
        let model = AppModel()
        let probing = Conversion(sourceURL: sourceURL("Probing"))
        let active = ready("Active")
        active.status = .converting(fraction: 0, framesDone: 0)
        let finished = ready("Finished")
        finished.status = .done(outputURL: sourceURL("Finished spatial"))
        let failed = ready("Failed")
        failed.status = .failed("Test failure")
        model.conversions = [probing, active, finished, failed]

        XCTAssertFalse(model.canMoveToTopOfQueue(probing))
        XCTAssertFalse(model.canMoveToTopOfQueue(active))
        XCTAssertFalse(model.canMoveToTopOfQueue(finished))
        XCTAssertFalse(model.canMoveToTopOfQueue(failed))
    }

    func testPromotionKeepsFinishedRowsStable() {
        let model = AppModel()
        let finishedFirst = ready("Finished First")
        finishedFirst.status = .done(outputURL: sourceURL("Finished First spatial"))
        let waitingFirst = ready("Waiting First")
        let finishedSecond = ready("Finished Second")
        finishedSecond.status = .done(outputURL: sourceURL("Finished Second spatial"))
        let priority = ready("Priority")
        model.conversions = [finishedFirst, waitingFirst, finishedSecond, priority]

        model.moveToTopOfQueue(priority)

        XCTAssertEqual(model.finished.map(\.id), [finishedFirst.id, finishedSecond.id])
        XCTAssertEqual(model.upNext.map(\.id), [priority.id, waitingFirst.id])
    }

    func testRepeatedPromotionsProduceLastPromotedFirst() {
        let model = AppModel()
        let first = ready("First")
        let second = ready("Second")
        let third = ready("Third")
        let fourth = ready("Fourth")
        model.conversions = [first, second, third, fourth]

        model.moveToTopOfQueue(third)
        model.moveToTopOfQueue(fourth)

        XCTAssertEqual(
            model.readyToConvert.map(\.id),
            [fourth.id, third.id, first.id, second.id]
        )
    }

    func testPromotionOfClickedSelectedRowMovesEligibleSelectionGroup() {
        let model = AppModel()
        let first = ready("First")
        let second = ready("Second")
        let clicked = ready("Clicked")
        let otherSelected = ready("Other Selected")
        model.conversions = [first, second, clicked, otherSelected]
        model.selectionID = clicked.id
        model.selectedIDs = [clicked.id, otherSelected.id]

        let candidates = model.priorityCandidates(for: clicked)
        model.prioritize(candidates)

        XCTAssertEqual(
            model.readyToConvert.map(\.id),
            [clicked.id, otherSelected.id, first.id, second.id]
        )
        XCTAssertEqual(model.selectedIDs, [clicked.id, otherSelected.id])
        XCTAssertEqual(model.selectionID, clicked.id)
    }

    private func ready(_ name: String) -> Conversion {
        let conversion = Conversion(sourceURL: sourceURL(name))
        conversion.status = .ready
        return conversion
    }

    private func sourceURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name).mov")
    }
}
