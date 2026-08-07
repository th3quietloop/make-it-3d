import CoreVideo
import Foundation

/// A frame's index, written into the picture as a binary strip.
///
/// This is how frame alignment gets measured instead of eyeballed. The same
/// index is stamped into the colour frame and into the depth frame, in the same
/// place proportionally, so a check can decode both and assert they are equal.
/// If the two tracks ever drift by a single frame, the numbers stop matching
/// and say so.
///
/// It is in the picture rather than in metadata on purpose. Metadata rides
/// along untouched; pixels go through the encoder, the decoder, the composition
/// and the sampler, which is the whole path that could get it wrong.
enum FrameIndexStrip {

    /// 12 bits covers 4096 frames, which at 30 fps is a little over two
    /// minutes: exactly the length the frame alignment gate runs for.
    static let bitCount = 12
    static let cycle = 1 << bitCount

    /// The strip occupies this fraction of the frame, so it lands in the same
    /// place on the colour raster and on the half resolution depth raster.
    private static let widthFraction = 12.0 / 120.0
    private static let heightFraction = 1.0 / 108.0

    /// Cell geometry for a raster of a given size.
    struct Geometry {
        let cellWidth: Int
        let cellHeight: Int

        var stripWidth: Int { cellWidth * bitCount }

        /// The centre of one cell, which is what a decoder samples. Sampling
        /// the centre rather than an edge is what makes this survive a lossy
        /// encoder: the middle of a 8 pixel block of flat black or flat white
        /// comes back black or white.
        func centre(ofBit bit: Int) -> (x: Int, y: Int) {
            (x: bit * cellWidth + cellWidth / 2, y: cellHeight / 2)
        }
    }

    /// Fails rather than silently producing a one pixel strip nobody can read.
    static func geometry(width: Int, height: Int) throws -> Geometry {
        let cellWidth = Int((Double(width) * widthFraction / Double(bitCount)).rounded(.down))
        let cellHeight = Int((Double(height) * heightFraction).rounded(.down))
        guard cellWidth >= 4, cellHeight >= 2 else {
            throw StripError.frameTooSmall(width: width, height: height)
        }
        return Geometry(cellWidth: cellWidth, cellHeight: cellHeight)
    }

    enum StripError: LocalizedError {
        case frameTooSmall(width: Int, height: Int)

        var errorDescription: String? {
            switch self {
            case .frameTooSmall(let width, let height):
                return """
                    A \(width) by \(height) frame is too small to carry a readable \
                    frame index strip.
                    """
            }
        }
    }

    /// The bit pattern for a frame index, most significant bit at the left.
    static func bits(for index: Int) -> [Bool] {
        let wrapped = index % cycle
        return (0..<bitCount).map { bit in
            let shift = bitCount - 1 - bit
            return (wrapped >> shift) & 1 == 1
        }
    }

    /// Turns a decoded bit pattern back into an index.
    static func index(from bits: [Bool]) -> Int {
        bits.reduce(0) { $0 << 1 | ($1 ? 1 : 0) }
    }

    /// Stamps the index into a locked 32BGRA raster.
    static func stamp(
        index: Int,
        intoBGRA base: UnsafeMutableRawPointer,
        bytesPerRow: Int,
        width: Int,
        height: Int
    ) throws {
        let geometry = try geometry(width: width, height: height)
        let pattern = bits(for: index)

        for y in 0..<min(geometry.cellHeight, height) {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for bit in 0..<bitCount {
                let value: UInt8 = pattern[bit] ? 255 : 0
                let start = bit * geometry.cellWidth
                for x in start..<min(start + geometry.cellWidth, width) {
                    let pixel = row.advanced(by: x * 4)
                    pixel[0] = value
                    pixel[1] = value
                    pixel[2] = value
                    pixel[3] = 255
                }
            }
        }
    }

    /// Stamps the index into a locked single plane 8 bit luma raster.
    static func stamp(
        index: Int,
        intoLuma base: UnsafeMutableRawPointer,
        bytesPerRow: Int,
        width: Int,
        height: Int
    ) throws {
        let geometry = try geometry(width: width, height: height)
        let pattern = bits(for: index)

        for y in 0..<min(geometry.cellHeight, height) {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for bit in 0..<bitCount {
                let value: UInt8 = pattern[bit] ? 255 : 0
                let start = bit * geometry.cellWidth
                for x in start..<min(start + geometry.cellWidth, width) {
                    row[x] = value
                }
            }
        }
    }

    /// Reads the index back out of a locked 32BGRA raster.
    ///
    /// Returns nil when a cell lands in the middle, which means the strip was
    /// not written or the frame was resampled badly enough that the reading
    /// cannot be trusted. A wrong answer would be worse than no answer here,
    /// because this is the thing that decides whether alignment holds.
    static func read(
        fromBGRA base: UnsafeRawPointer,
        bytesPerRow: Int,
        width: Int,
        height: Int
    ) throws -> Int? {
        let geometry = try geometry(width: width, height: height)
        var pattern = [Bool]()
        pattern.reserveCapacity(bitCount)

        for bit in 0..<bitCount {
            let centre = geometry.centre(ofBit: bit)
            guard centre.x < width, centre.y < height else { return nil }
            let row = base.advanced(by: centre.y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            let green = Int(row[centre.x * 4 + 1])
            guard green < 64 || green > 191 else { return nil }
            pattern.append(green > 127)
        }
        return index(from: pattern)
    }

    /// Reads the index back out of a locked single plane 8 bit luma raster.
    static func read(
        fromLuma base: UnsafeRawPointer,
        bytesPerRow: Int,
        width: Int,
        height: Int
    ) throws -> Int? {
        let geometry = try geometry(width: width, height: height)
        var pattern = [Bool]()
        pattern.reserveCapacity(bitCount)

        for bit in 0..<bitCount {
            let centre = geometry.centre(ofBit: bit)
            guard centre.x < width, centre.y < height else { return nil }
            let row = base.advanced(by: centre.y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            let level = Int(row[centre.x])
            guard level < 64 || level > 191 else { return nil }
            pattern.append(level > 127)
        }
        return index(from: pattern)
    }
}
