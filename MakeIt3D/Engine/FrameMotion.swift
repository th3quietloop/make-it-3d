import CoreVideo
import Foundation
import simd

/// A conservative camera-translation estimate. Low confidence deliberately
/// disables historical reconstruction; it is not a full optical-flow field.
struct FrameMotion: Sendable {
    var translation: SIMD2<Float> = .zero
    var confidence: Float = 0
    var sceneCut = false
    var difference: Float = 0
    static let stationary = FrameMotion(confidence: 1)
}

final class FrameMotionEstimator {
    private let width = 64
    private let height = 40
    private var previous: [Float]?

    func reset() { previous = nil }

    func analyze(_ buffer: CVPixelBuffer) -> FrameMotion {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return FrameMotion() }
        let sourceWidth = CVPixelBufferGetWidth(buffer)
        let sourceHeight = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var luma = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let sy = min(sourceHeight - 1, (2 * y + 1) * sourceHeight / (2 * height))
            let row = base.advanced(by: sy * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let sx = min(sourceWidth - 1, (2 * x + 1) * sourceWidth / (2 * width))
                let offset = sx * 4
                luma[y * width + x] = (Float(row[offset + 2]) * 0.2126
                    + Float(row[offset + 1]) * 0.7152 + Float(row[offset]) * 0.0722) / 255
            }
        }
        defer { previous = luma }
        guard let previous else { return FrameMotion() }
        return Self.estimate(previous: previous, current: luma, width: width, height: height)
    }

    static func estimate(previous: [Float], current: [Float], width: Int, height: Int) -> FrameMotion {
        guard width > 12, height > 12, previous.count == width * height,
              current.count == previous.count else { return FrameMotion() }
        let margin = 5
        var best: Float = .greatestFiniteMagnitude
        var zero: Float = .greatestFiniteMagnitude
        var bestShift = SIMD2<Int>(0, 0)
        for dy in -4...4 {
            for dx in -4...4 {
                var error: Float = 0
                var count: Float = 0
                for y in margin..<(height - margin) {
                    for x in margin..<(width - margin) {
                        error += abs(current[y * width + x] - previous[(y - dy) * width + x - dx])
                        count += 1
                    }
                }
                let score = error / max(count, 1)
                if dx == 0, dy == 0 { zero = score }
                // Penalize unnecessary movement in textureless/ambiguous frames.
                let penalty = Float(abs(dx) + abs(dy)) * 0.0005
                if score + penalty < best {
                    best = score + penalty
                    bestShift = SIMD2<Int>(dx, dy)
                }
            }
        }
        let confidence = max(0, min(1, 1 - best / 0.12))
        return FrameMotion(
            translation: SIMD2<Float>(Float(bestShift.x) / Float(width), Float(bestShift.y) / Float(height)),
            confidence: confidence,
            sceneCut: best > 0.22 && zero > 0.25,
            difference: best
        )
    }
}
