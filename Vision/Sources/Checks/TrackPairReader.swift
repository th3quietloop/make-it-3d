import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Walks a depth track file's two video tracks side by side.
///
/// It deliberately does not force the two tracks into step. It pulls one sample
/// from each and hands both back exactly as they arrived, timestamps included,
/// so a check can decide whether they agree. A reader that quietly resynced
/// would make the frame alignment gate unable to fail.
final class TrackPairReader {

    struct Pair {
        let colorTime: CMTime
        let depthTime: CMTime
        let color: CVPixelBuffer
        let depth: CVPixelBuffer
    }

    private let reader: AVAssetReader
    private let colorOutput: AVAssetReaderTrackOutput
    private let depthOutput: AVAssetReaderTrackOutput

    static func open(url: URL) async throws -> TrackPairReader {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count >= 2 else {
            throw CheckAborted(
                check: "Track pair reader",
                reason: "this file has \(tracks.count) video track(s), not two."
            )
        }
        return try TrackPairReader(asset: asset, color: tracks[0], depth: tracks[1])
    }

    private init(asset: AVAsset, color: AVAssetTrack, depth: AVAssetTrack) throws {
        reader = try AVAssetReader(asset: asset)

        // Colour comes back as BGRA, which is what everything downstream reads.
        colorOutput = AVAssetReaderTrackOutput(
            track: color,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        colorOutput.alwaysCopiesSampleData = false

        // Depth comes back as full range 420 so the luma plane can be read as
        // the stored level itself. Asking for BGRA here would push the map
        // through a colour matrix and back, and the check would then be
        // measuring the round trip rather than the file.
        depthOutput = AVAssetReaderTrackOutput(
            track: depth,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
        )
        depthOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(colorOutput), reader.canAdd(depthOutput) else {
            throw CheckAborted(
                check: "Track pair reader", reason: "the video tracks could not be opened."
            )
        }
        reader.add(colorOutput)
        reader.add(depthOutput)

        guard reader.startReading() else {
            throw CheckAborted(
                check: "Track pair reader",
                reason: reader.error?.localizedDescription ?? "the reader would not start."
            )
        }
    }

    /// The next pair, or nil once either track runs out.
    func next() throws -> Pair? {
        guard let colorSample = colorOutput.copyNextSampleBuffer(),
              let depthSample = depthOutput.copyNextSampleBuffer() else {
            if reader.status == .failed {
                throw CheckAborted(
                    check: "Track pair reader",
                    reason: reader.error?.localizedDescription ?? "reading stopped."
                )
            }
            return nil
        }
        guard let color = CMSampleBufferGetImageBuffer(colorSample),
              let depth = CMSampleBufferGetImageBuffer(depthSample) else {
            return nil
        }
        return Pair(
            colorTime: CMSampleBufferGetPresentationTimeStamp(colorSample),
            depthTime: CMSampleBufferGetPresentationTimeStamp(depthSample),
            color: color,
            depth: depth
        )
    }

    func cancel() {
        reader.cancelReading()
    }

    // MARK: Reading the index strip out of a decoded pair

    /// The frame index stamped into a decoded colour frame, or nil when it is
    /// unreadable.
    static func colorIndex(of buffer: CVPixelBuffer) throws -> Int? {
        try PixelBuffers.withLock(buffer, readOnly: true) {
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            return try FrameIndexStrip.read(
                fromBGRA: base,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer)
            )
        }
    }

    /// The frame index stamped into a decoded depth frame's luma plane.
    static func depthIndex(of buffer: CVPixelBuffer) throws -> Int? {
        try PixelBuffers.withLock(buffer, readOnly: true) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
            return try FrameIndexStrip.read(
                fromLuma: base,
                bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                width: CVPixelBufferGetWidthOfPlane(buffer, 0),
                height: CVPixelBufferGetHeightOfPlane(buffer, 0)
            )
        }
    }
}
