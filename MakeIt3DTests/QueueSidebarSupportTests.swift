import Observation
import XCTest
@testable import MakeIt3D

@MainActor
final class QueueSidebarSupportTests: XCTestCase {
    func testRowEligibilityObservesProbingRowsBecomingRunnable() {
        let model = AppModel(systemFeedbackEnabled: false)
        let preparing = QueueTestFixture.conversion("Preparing", status: .probing)
        let ready = QueueTestFixture.conversion("Ready")
        model.conversions = [preparing, ready]

        let invalidated = expectation(description: "Position snapshot invalidated")
        withObservationTracking {
            XCTAssertFalse(preparing.canMoveInQueue)
            XCTAssertNil(model.queuePosition(for: preparing))
            XCTAssertEqual(model.queuePosition(for: ready), .next)
        } onChange: {
            invalidated.fulfill()
        }

        preparing.status = .ready

        XCTAssertEqual(XCTWaiter.wait(for: [invalidated], timeout: 1), .completed)
        XCTAssertTrue(preparing.canMoveInQueue)
        XCTAssertEqual(model.queuePosition(for: preparing), .next)
        XCTAssertEqual(model.queuePosition(for: ready), .numbered(2))
    }
}
