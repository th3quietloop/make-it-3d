import AVFoundation
import XCTest
@testable import MakeIt3D

/// Small, media-free fixtures for queue model tests.
///
/// These construct the state the scheduler sees without probing a real file or
/// starting Core ML. Keeping them in the test target makes ordering and summary
/// tests fast enough to run on every build.
@MainActor
enum QueueTestFixture {
    static func conversion(
        _ name: String,
        status: Conversion.Status = .ready
    ) -> Conversion {
        let conversion = Conversion(sourceURL: sourceURL(name))
        conversion.status = status
        return conversion
    }

    static func probe(
        _ name: String = "Source",
        duration: Double = 10,
        framesPerSecond: Double = 30,
        width: Int = 1_920,
        height: Int = 1_080,
        hasAudio: Bool = false
    ) -> SourceProbe {
        SourceProbe(
            url: sourceURL(name),
            duration: CMTime(seconds: duration, preferredTimescale: 600),
            nominalFrameRate: framesPerSecond,
            width: width,
            height: height,
            hasAudio: hasAudio,
            estimatedFrameCount: max(1, Int((duration * framesPerSecond).rounded()))
        )
    }

    static func runnable(
        _ name: String,
        duration: Double = 1,
        framesPerSecond: Double = 30,
        width: Int = 320,
        height: Int = 180
    ) -> Conversion {
        let conversion = conversion(name)
        conversion.probe = probe(
            name,
            duration: duration,
            framesPerSecond: framesPerSecond,
            width: width,
            height: height
        )
        return conversion
    }

    nonisolated static func report(for request: ConversionRequest) -> VerificationReport {
        VerificationReport(
            outputURL: request.outputURL,
            checks: [],
            producedAt: Date(timeIntervalSince1970: 0)
        )
    }

    static func sourceURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/MakeIt3DTests/\(name).mov")
    }
}

@MainActor
func waitUntil(
    attempts: Int = 400,
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

func waitForInvocationCount(
    _ expectedCount: Int,
    from runner: ControlledConversionRunner,
    attempts: Int = 400
) async -> Bool {
    for _ in 0..<attempts {
        if await runner.invocationCount() >= expectedCount { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await runner.invocationCount() >= expectedCount
}

@MainActor
func XCTAssertConversionOrder(
    _ actual: [Conversion],
    _ expected: [Conversion],
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(
        actual.map(\.id),
        expected.map(\.id),
        message(),
        file: file,
        line: line
    )
}
