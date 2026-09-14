import XCTest
import CoreMedia
@testable import MakeIt3D

final class EngineRegressionTests: XCTestCase {
    func testOlderTuningLoadsNewEngineDefaults() throws {
        let tuning = try JSONDecoder().decode(EngineTuning.self, from: Data("{\"convergence\":0.7}".utf8))
        XCTAssertEqual(tuning.convergence, 0.7)
        XCTAssertEqual(tuning.computePreference, .automatic)
        XCTAssertEqual(tuning.edgeRefinement, 0.35)
    }

    func testUnsafeImportedTuningIsRejected() {
        for json in ["{\"previewMaxHeight\":0}", "{\"lowPercentile\":0.9,\"highPercentile\":0.1}",
                     "{\"meshVertexSpacing\":-1}", "{\"convergence\":2}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(EngineTuning.self, from: Data(json.utf8)))
        }
    }

    func testInvalidModelNeverReplacesActiveRecord() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ModelImport-\(UUID())")
        let invalid = directory.appendingPathComponent("invalid.mlmodelc")
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let active = directory.appendingPathComponent("active-perFrame.json")
        let original = Data("existing activation".utf8)
        try original.write(to: active)
        do {
            _ = try await DepthModelStore.install(from: invalid, kind: .perFrame, storageDirectory: directory)
            XCTFail("An invalid model was activated")
        } catch {
            XCTAssertEqual(try Data(contentsOf: active), original)
        }
    }

    func testRangeIsClampedAndEmptyRangesRejected() throws {
        let duration = CMTime(seconds: 10, preferredTimescale: 600)
        let request = CMTimeRange(start: CMTime(seconds: 8, preferredTimescale: 600),
                                  duration: CMTime(seconds: 5, preferredTimescale: 600))
        let range = try XCTUnwrap(Ingest.validatedRange(request, duration: duration))
        XCTAssertEqual(range.start.seconds, 8)
        XCTAssertEqual(range.duration.seconds, 2)
        XCTAssertThrowsError(try Ingest.validatedRange(CMTimeRange(start: duration, duration: .zero), duration: duration))
    }

    func testDisparityRefinementPreservesPlanesAndBoundsSharpEdges() {
        let flat = [Float](repeating: 3, count: 64)
        XCTAssertEqual(Disparity.refineEdges(flat, width: 64, height: 1, frameWidth: 64, amount: 1), flat)
        let edge = [Float](repeating: -10, count: 32) + [Float](repeating: 10, count: 32)
        let refined = Disparity.refineEdges(edge, width: 64, height: 1, frameWidth: 64, amount: 1)
        for index in 1..<refined.count {
            XCTAssertLessThanOrEqual(abs(refined[index] - refined[index - 1]), 0.60001)
        }
    }

    func testMotionEstimatorRecoversTranslationAndRejectsCut() {
        let width = 64, height = 40
        let source = (0..<(width * height)).map { index in Float((index * 17 + (index / width) * (index / width) * 13 + (index % width) * (index % width) * 7) % 97) / 97 }
        var shifted = source
        for y in 1..<height { for x in 2..<width { shifted[y * width + x] = source[(y - 1) * width + x - 2] } }
        let motion = FrameMotionEstimator.estimate(previous: source, current: shifted, width: width, height: height)
        XCTAssertEqual(motion.translation.x, 2.0 / 64, accuracy: 0.00001)
        XCTAssertEqual(motion.translation.y, 1.0 / 40, accuracy: 0.00001)
        XCTAssertGreaterThan(motion.confidence, 0.9)
        let cut = FrameMotionEstimator.estimate(previous: [Float](repeating: 0, count: source.count),
            current: [Float](repeating: 1, count: source.count), width: width, height: height)
        XCTAssertTrue(cut.sceneCut)
        XCTAssertEqual(cut.confidence, 0)
    }

    func testMotionCompensationRemovesLagForKnownCameraTranslation() {
        let width = 64, height = 40
        var first = [Float](repeating: 0, count: width * height)
        var moved = first
        for y in 0..<height {
            for x in 20..<32 { first[y * width + x] = 1 }
            for x in 22..<34 { moved[y * width + x] = 1 }
        }
        var legacyTuning = EngineTuning.default
        legacyTuning.motionRejection = 0
        let legacy = Stabilizer(tuning: legacyTuning)
        let compensated = Stabilizer(tuning: .default)
        let a = NearnessMap(values: first, width: width, height: height)
        let b = NearnessMap(values: moved, width: width, height: height)
        _ = legacy.stabilize(a); _ = compensated.stabilize(a)
        let lagged = legacy.stabilize(b)
        let aligned = compensated.stabilize(b,
            motion: FrameMotion(translation: SIMD2<Float>(2.0 / 64, 0), confidence: 1))
        XCTAssertGreaterThan(lagged.values[20 * width + 20], 0.7)
        XCTAssertEqual(aligned.values[20 * width + 20], 0, accuracy: 0.0001)
        XCTAssertEqual(aligned.values[20 * width + 33], 1, accuracy: 0.0001)
    }

    func testNonfiniteDepthDoesNotCrashHistogram() {
        let map = NearnessMap(values: [0, 1, .nan, .infinity, 2, 3, 4, 5], width: 4, height: 2)
        let result = Stabilizer(tuning: .default).normalize(map)
        XCTAssertTrue(result.values.allSatisfy(\.isFinite))
    }

    func testGeneratedMediaRegressions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EngineRegression-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = await MediaIntegrityCheck.run(in: directory)
        XCTAssertTrue(result)
    }
}
