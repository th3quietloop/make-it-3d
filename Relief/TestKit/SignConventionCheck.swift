import CoreVideo
import Foundation
import Accelerate

/// Verifies that near objects pop toward the viewer rather than sinking behind
/// the screen.
///
/// This does not run the depth model. It injects a nearness map it already
/// knows the answer to, pushes it through the real Disparity and WarpRenderer
/// code, and measures which way the marker actually moved in each eye. Using
/// the real synthesis path is the point; removing the model from the loop is
/// what makes the result a fact rather than an impression.
///
/// The geometry it is asserting: for an object nearer than the screen plane,
/// the ray from the left eye through the object meets the screen to the RIGHT
/// of centre, and the ray from the right eye meets it to the LEFT. That is
/// crossed disparity, and it means the left eye's copy sits further right than
/// the right eye's copy. Content behind the screen plane is the reverse.
///
/// The nearness field is deliberately uniform across the frame. An earlier
/// version put a near box on a far background, which reads like a better test
/// but is not measurable: at a hard depth discontinuity the warp mesh overlaps
/// on one edge of the box and gaps on the other, so the box changes shape and
/// its centroid stops being a clean record of how far it moved. A uniform field
/// shifts the whole frame rigidly, so the measured shift is exactly the
/// disparity and nothing else. Running it twice, once near and once far, still
/// proves ordering as well as sign.
enum SignConventionCheck {

    struct Result: Sendable {
        let nearSeparation: Double
        let farSeparation: Double
        let passed: Bool
        let detail: String

        var line: String {
            "\(passed ? "PASS" : "FAIL")  Stereo sign convention: \(detail)"
        }
    }

    /// Runs the check at the given tuning.
    static func run(tuning: EngineTuning = .default) throws -> Result {
        // Nearness 0.9 sits well in front of the 0.45 convergence point, 0.1
        // well behind it.
        let near = try measureSeparation(nearness: 0.9, tuning: tuning)
        let far = try measureSeparation(nearness: 0.1, tuning: tuning)

        // Sub pixel noise should not read as a result in either direction.
        let threshold = 0.5
        let nearPops = near > threshold
        let farRecedes = far < -threshold
        let passed = nearPops && farRecedes

        let diagnosis: String
        if passed {
            diagnosis = "near content pops toward the viewer and far content sits behind the screen"
        } else if near < -threshold && far > threshold {
            diagnosis = "ordering is inverted: flip invertDisparitySign in EngineTuning"
        } else if abs(near) <= threshold && abs(far) <= threshold {
            diagnosis = "no measurable separation, so the warp is not displacing anything"
        } else {
            diagnosis = "near and far are not separating in opposite directions"
        }

        return Result(
            nearSeparation: near,
            farSeparation: far,
            passed: passed,
            detail: String(
                format: "near separation %+.2f px (want positive), far separation %+.2f px (want negative). %@",
                near, far, diagnosis
            )
        )
    }

    /// Renders both eyes for a frame at one uniform nearness and returns
    /// leftCentroid minus rightCentroid, in pixels.
    private static func measureSeparation(nearness value: Float, tuning: EngineTuning) throws -> Double {
        let width = 640
        let height = 360

        // A narrow bright bar on a dark field. Narrow so its centroid is a
        // sharp number, and away from the frame edges so the overscan crop
        // never clips it.
        let source = try WarpRenderer.makePixelBuffer(width: width, height: height)
        try paint(source, width: width, height: height, box: (x: width / 2 - 20, width: 40))

        let mapWidth = 160
        let mapHeight = 90
        let values = [Float](repeating: value, count: mapWidth * mapHeight)
        let map = NearnessMap(values: values, width: mapWidth, height: mapHeight)

        let field = Disparity.field(from: map, frameWidth: width, tuning: tuning)

        let renderer = try WarpRenderer(frameWidth: width, frameHeight: height, tuning: tuning)
        let left = try WarpRenderer.makePixelBuffer(width: width, height: height)
        let right = try WarpRenderer.makePixelBuffer(width: width, height: height)
        try renderer.synthesize(source: source, disparity: field, into: left, and: right)

        let leftCentroid = brightCentroidX(left, width: width, height: height)
        let rightCentroid = brightCentroidX(right, width: width, height: height)

        print(String(
            format: "  nearness %.2f: disparity %+.3f px, left %.2f, right %.2f",
            value,
            value > Float(tuning.convergence) ? field.maxPositive : field.maxNegative,
            leftCentroid, rightCentroid
        ))

        return leftCentroid - rightCentroid
    }

    // MARK: Helpers

    private static func paint(
        _ buffer: CVPixelBuffer, width: Int, height: Int, box: (x: Int, width: Int)
    ) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)

        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let isBox = x >= box.x && x < box.x + box.width
                let value: UInt8 = isBox ? 240 : 40
                let pixel = row.advanced(by: x * 4)
                pixel[0] = value  // B
                pixel[1] = value  // G
                pixel[2] = value  // R
                pixel[3] = 255
            }
        }
    }

    /// Intensity weighted centroid of the bright pixels, which is where the box
    /// ended up after the warp.
    private static func brightCentroidX(_ buffer: CVPixelBuffer, width: Int, height: Int) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)

        var weightedSum = 0.0
        var weightTotal = 0.0

        // Sample the middle band only, away from the top and bottom edges where
        // the overscan crop is doing its own thing.
        let start = height / 3
        let end = height * 2 / 3

        for y in start..<end {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let value = Double(row[x * 4 + 1])
                // Only the box is bright; the background sits near 40.
                guard value > 140 else { continue }
                weightedSum += Double(x) * value
                weightTotal += value
            }
        }

        return weightTotal > 0 ? weightedSum / weightTotal : 0
    }
}
