import XCTest
import CoreMedia
@testable import MakeIt3D

@MainActor
final class UIRegressionTests: XCTestCase {
    func testRoutineMessagesCannotEvictAnUnresolvedAnalysisFailure() {
        let center = ToastCenter()
        center.failure("Couldn't analyse Beach", detail: "Source became unavailable")
        for index in 0..<10 { center.info("Added clip \(index)") }
        XCTAssertEqual(center.pendingFailureCount, 1)
        XCTAssertEqual(center.currentMessage?.title, "Couldn't analyse Beach")
        XCTAssertEqual(center.toasts.filter { $0.tone == .info }.count, 2)
        let failure = center.currentMessage!
        center.dismiss(failure.id)
        XCTAssertEqual(center.pendingFailureCount, 0)
        XCTAssertTrue(center.history.contains { $0.id == failure.id })
    }

    func testHundredShotRibbonKeepsAllBoundariesOnTheTimeScale() {
        let settings = AutoTune.Result(strength: 0.01, convergence: 0.6, predictedLoad: 0.5, confidence: 0.5)
        let shots = (0..<100).map { index in
            Shot(id: index, start: CMTime(seconds: Double(index), preferredTimescale: 600),
                 end: CMTime(seconds: Double(index + 1), preferredTimescale: 600),
                 content: .unknown, settings: settings)
        }
        let bounds = shots.map { ShotTimeline.segment($0, duration: 100, width: 600) }
        XCTAssertEqual(bounds.last!.maxX, 600, accuracy: 0.0001)
        XCTAssertEqual(bounds.reduce(0) { $0 + $1.width }, 600, accuracy: 0.0001)
        for index in 1..<bounds.count {
            XCTAssertEqual(bounds[index - 1].maxX, bounds[index].minX, accuracy: 0.0001)
            XCTAssertEqual(bounds[index].minX / 600, Double(index) / 100, accuracy: 0.0001)
        }
    }
}
