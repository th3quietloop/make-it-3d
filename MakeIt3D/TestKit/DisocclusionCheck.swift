import CoreVideo
import Foundation

/// Proves the disocclusion filling leaves no holes.
///
/// Discarding stretched fragments is only safe if something is underneath them.
/// If the background plate pass ever fails to cover the frame, the discard
/// turns a smear into a black gash, which is a far worse artifact than the one
/// it replaced. This renders the hardest case for the warp, a hard depth edge
/// with a large disparity jump, and counts how many output pixels came out as
/// nothing at all.
enum DisocclusionCheck {

    struct Result: Sendable {
        let holePixels: Int
        let totalPixels: Int
        let passed: Bool
        let detail: String

        var line: String {
            "\(passed ? "PASS" : "FAIL")  Disocclusion filling: \(detail)"
        }
    }

    static func run(tuning: EngineTuning = .default) throws -> Result {
        let width = 640
        let height = 360

        // A textured frame, so a hole reads as black rather than blending in
        // with a flat colour.
        let source = try WarpRenderer.makePixelBuffer(width: width, height: height)
        try paintCheckerboard(source, width: width, height: height)

        // The worst case: a near slab against a far background, with the jump
        // falling in the middle of the frame. Deep strength widens the gap.
        var hardTuning = tuning
        hardTuning.strength = .deep
        hardTuning.customDisparityPercent = nil

        let mapWidth = 160
        let mapHeight = 90
        var values = [Float](repeating: 0.05, count: mapWidth * mapHeight)
        for y in 0..<mapHeight {
            for x in (mapWidth / 3)..<(2 * mapWidth / 3) {
                values[y * mapWidth + x] = 0.95
            }
        }
        let nearness = NearnessMap(values: values, width: mapWidth, height: mapHeight)
        let field = Disparity.field(from: nearness, frameWidth: width, tuning: hardTuning)

        let renderer = try WarpRenderer(
            frameWidth: width, frameHeight: height, tuning: hardTuning
        )
        let left = try WarpRenderer.makePixelBuffer(width: width, height: height)
        let right = try WarpRenderer.makePixelBuffer(width: width, height: height)
        try renderer.synthesize(source: source, disparity: field, into: left, and: right)

        // The right eye is the one that carries the disparity, so it is where
        // the gaps open.
        let holes = countBlackPixels(right, width: width, height: height)
        let total = width * height
        let fraction = Double(holes) / Double(total)

        // A handful of pixels along the extreme edge is tolerable; the overscan
        // crop covers those. Anything more means the plate is not covering.
        let passed = fraction < 0.002

        return Result(
            holePixels: holes,
            totalPixels: total,
            passed: passed,
            detail: String(
                format: "%d of %d pixels unfilled (%.3f%%) at a hard depth edge, %@",
                holes, total, fraction * 100,
                passed ? "within tolerance" : "the background plate is not covering the gaps"
            )
        )
    }

    // MARK: Helpers

    /// A checkerboard: every cell is bright, so a genuine hole is unmistakable.
    private static func paintCheckerboard(
        _ buffer: CVPixelBuffer, width: Int, height: Int
    ) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)

        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let cell = ((x / 16) + (y / 16)) % 2 == 0
                let value: UInt8 = cell ? 200 : 120
                let pixel = row.advanced(by: x * 4)
                pixel[0] = value
                pixel[1] = value
                pixel[2] = value
                pixel[3] = 255
            }
        }
    }

    /// Counts pixels that came out as nothing. The source is never darker than
    /// 120, so anything near zero is a gap the render failed to fill.
    private static func countBlackPixels(
        _ buffer: CVPixelBuffer, width: Int, height: Int
    ) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)

        var holes = 0
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width where row[x * 4 + 1] < 30 {
                holes += 1
            }
        }
        return holes
    }
}
