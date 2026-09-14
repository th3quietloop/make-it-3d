import XCTest
@testable import MakeIt3D

final class PreviewInteractionTests: XCTestCase {
    func testExactAndNativePreviewCacheBoundaries() {
        let url = URL(fileURLWithPath: "/tmp/preview-a.mov")
        let proxy = PreviewEngine.FrameKey(url: url, timeValue: 12, precise: true, maximumHeight: 720)
        XCTAssertTrue(PreviewEngine.canReuse(proxy, for: .init(url: url, timeValue: 12, precise: false, maximumHeight: 720)))
        XCTAssertFalse(PreviewEngine.canReuse(proxy, for: .init(url: url, timeValue: 12, precise: true, maximumHeight: 0)), "100% inspection must decode native pixels")
        XCTAssertFalse(PreviewEngine.canReuse(proxy, for: .init(url: URL(fileURLWithPath: "/tmp/preview-b.mov"), timeValue: 12, precise: true, maximumHeight: 720)), "Same-size sources must not share decoded imagery")
        XCTAssertFalse(PreviewEngine.canReuse(proxy, for: .init(url: url, timeValue: 13, precise: true, maximumHeight: 720)))
        let approximate = PreviewEngine.FrameKey(url: url, timeValue: 12, precise: false, maximumHeight: 720)
        XCTAssertFalse(PreviewEngine.canReuse(approximate, for: proxy), "A settled playhead needs its exact frame")
    }

    func testTimeEntryUsesUnambiguousDecimalSeconds() {
        XCTAssertEqual(PreviewNavigation.seconds(from: "75.25"), 75.25)
        XCTAssertEqual(PreviewNavigation.seconds(from: "1:15.250"), 75.25)
        XCTAssertEqual(PreviewNavigation.seconds(from: "1:02:03.125"), 3723.125)
        XCTAssertEqual(PreviewNavigation.seconds(from: " 0:00.033 "), 0.033)
        for invalid in ["", "1:60", "1:99:00", "-1", "nan", "inf", ":30", "1:2:3:4"] {
            XCTAssertNil(PreviewNavigation.seconds(from: invalid), invalid)
        }
    }

    func testTimeDisplayCarriesMillisecondsAcrossBoundaries() {
        XCTAssertEqual(PreviewNavigation.timecode(59.9996), "1:00.000")
        XCTAssertEqual(PreviewNavigation.timecode(3599.9996), "1:00:00.000")
        XCTAssertEqual(PreviewNavigation.timecode(75.125), "1:15.125")
    }

    func testTimelineWindowStaysInsideSourceOrProofBounds() {
        XCTAssertEqual(PreviewTimelineWindow.range(within: 0...120, requestedSpan: 10, start: 45), 45...55)
        XCTAssertEqual(PreviewTimelineWindow.range(within: 0...120, requestedSpan: 10, start: -5), 0...10)
        XCTAssertEqual(PreviewTimelineWindow.range(within: 0...120, requestedSpan: 10, start: 118), 110...120)
        XCTAssertEqual(PreviewTimelineWindow.range(within: 40...43, requestedSpan: 2, start: 39), 40...42)
        XCTAssertEqual(PreviewTimelineWindow.range(within: 40...43, requestedSpan: 30, start: 0), 40...43)
        XCTAssertEqual(PreviewTimelineWindow.range(within: 40...43, requestedSpan: 0, start: 42), 40...43)
    }
}
