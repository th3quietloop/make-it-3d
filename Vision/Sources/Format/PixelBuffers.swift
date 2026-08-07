import CoreVideo
import Foundation

enum PixelBufferError: LocalizedError {
    case allocationFailed(Int, Int)
    case notAddressable

    var errorDescription: String? {
        switch self {
        case .allocationFailed(let width, let height):
            return "Couldn't allocate a \(width) by \(height) buffer."
        case .notAddressable:
            return "A pixel buffer would not hand back its memory."
        }
    }
}

/// Buffer allocation, in one place.
///
/// Every buffer here is IOSurface backed and Metal compatible, because
/// everything downstream either hands it to a video encoder or binds it as a
/// texture, and a buffer that cannot do both has to be copied to be useful.
enum PixelBuffers {

    static func make(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw PixelBufferError.allocationFailed(width, height)
        }
        return buffer
    }

    /// 32BGRA, which is what CoreGraphics draws into and Metal renders into.
    static func makeColor(width: Int, height: Int) throws -> CVPixelBuffer {
        try make(width: width, height: height, format: kCVPixelFormatType_32BGRA)
    }

    /// 420 full range, for depth.
    ///
    /// Full range rather than video range so level 0 stays 0 and level 255
    /// stays 255. Video range would squeeze the map into 16...235, and the two
    /// ends it rounds off are exactly the nearest and farthest points in the
    /// shot, which are the only two levels the depth contract names.
    static func makeDepth(width: Int, height: Int) throws -> CVPixelBuffer {
        try make(
            width: width, height: height,
            format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )
    }

    /// Runs `body` with the buffer locked, and unlocks whatever happens.
    static func withLock<T>(
        _ buffer: CVPixelBuffer,
        readOnly: Bool = false,
        _ body: () throws -> T
    ) rethrows -> T {
        let flags: CVPixelBufferLockFlags = readOnly ? .readOnly : []
        CVPixelBufferLockBaseAddress(buffer, flags)
        defer { CVPixelBufferUnlockBaseAddress(buffer, flags) }
        return try body()
    }
}
