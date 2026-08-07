import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Runs the real compositor and asks whether the frames it paired belong
/// together.
///
/// This is the other half of Phase 1's gate. FrameAlignmentCheck proves the
/// file has the two tracks in step; this proves the thing that reads the file
/// keeps them in step. It drives `PairedFrameCompositor` through an asset
/// reader rather than a player, so it runs headless and deterministically,
/// while exercising exactly the code the headset will run.
///
/// It also measures what the colour path does to the depth levels. The
/// compositor asks for BGRA on both tracks, which means the depth map takes a
/// trip through a YCbCr to RGB conversion on its way in. Grey should survive
/// that untouched. "Should" is not a measurement, so here is one.
enum CompositorPairingCheck {

    static func run(
        in directory: URL,
        spec: DepthTrackSpec = DepthTrackSpec(frameCount: 300)
    ) async throws -> [CheckResult] {
        let clip = try SyntheticDepthClip(spec: spec)
        let url = directory.appending(path: "fixture-pairing.mov")
        _ = try await DepthTrackWriter.write(to: url, source: clip)

        let file = try await DepthTrackReader.open(url: url)
        let (composition, sink) = try PairedComposition.make(for: file)

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: tracks,
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw CheckAborted(check: "Compositor pairing", reason: "the composition was rejected.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw CheckAborted(
                check: "Compositor pairing",
                reason: reader.error?.localizedDescription ?? "the reader would not start."
            )
        }

        var frames = 0
        var pairedFrames = 0
        var mismatched = 0
        var unpaired = 0
        var unreadable = 0
        var firstFailure: String?

        var levelSamples = 0
        var levelTotalError = 0.0
        var levelPixels = 0
        var levelWorst = 0

        while let sample = output.copyNextSampleBuffer() {
            guard let color = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)

            guard let match = sink.depth(at: time) else {
                unpaired += 1
                if firstFailure == nil {
                    firstFailure = "frame \(frames) at \(time.seconds)s had no depth frame to pair with"
                }
                frames += 1
                continue
            }
            pairedFrames += 1

            let colorIndex = try TrackPairReader.colorIndex(of: color)
            let depthIndex = try depthIndexFromBGRA(match.buffer)

            switch (colorIndex, depthIndex) {
            case let (colour?, depth?):
                if colour != depth {
                    mismatched += 1
                    if firstFailure == nil {
                        firstFailure = """
                            frame \(frames): the compositor paired colour frame \(colour) \
                            with depth frame \(depth)
                            """
                    }
                }
            default:
                unreadable += 1
            }

            if frames % 23 == 0 {
                let written = try clip.depthFrame(at: frames)
                let comparison = compareDepth(bgra: match.buffer, luma: written)
                levelTotalError += comparison.total
                levelPixels += comparison.pixels
                levelWorst = max(levelWorst, comparison.worst)
                levelSamples += 1
            }

            frames += 1
        }

        if reader.status == .failed {
            throw CheckAborted(
                check: "Compositor pairing",
                reason: reader.error?.localizedDescription ?? "reading stopped."
            )
        }

        let statistics = sink.currentStatistics
        let meanError = levelPixels > 0 ? levelTotalError / Double(levelPixels) : .infinity

        return [
            CheckResult(
                name: "Compositor delivers every frame",
                passed: frames == spec.frameCount && pairedFrames == spec.frameCount,
                detail: """
                    \(frames) composed frames of \(spec.frameCount), \
                    \(pairedFrames) paired, \(unpaired) unpaired
                    """
            ),
            CheckResult(
                name: "Compositor pairs the right frames",
                passed: mismatched == 0 && unreadable == 0 && unpaired == 0,
                detail: firstFailure
                    ?? "\(pairedFrames) pairs, \(mismatched) mismatched, \(unreadable) unreadable"
            ),
            CheckResult(
                name: "Pairing is exact, not approximate",
                // A near match means the sink could not find the frame's own
                // depth and settled for a neighbour. That is the shape a drift
                // would take, so it is a failure even when the pictures agree.
                passed: statistics.nearMatches == 0 && statistics.misses == 0
                    && statistics.missingDepthFrames == 0,
                detail: """
                    \(statistics.exactMatches) exact, \(statistics.nearMatches) near, \
                    \(statistics.misses) missed, \(statistics.missingDepthFrames) frames \
                    where the depth track gave nothing
                    """
            ),
            CheckResult(
                name: "Depth levels survive the colour path",
                passed: meanError <= 2.0 && levelWorst <= 24,
                detail: String(
                    format: "mean %.3f levels (limit 2.0), worst %d levels (limit 24), over %d frames",
                    meanError, levelWorst, levelSamples
                )
            )
        ]
    }

    /// The frame index out of a depth frame that arrived as BGRA.
    private static func depthIndexFromBGRA(_ buffer: CVPixelBuffer) throws -> Int? {
        try PixelBuffers.withLock(buffer, readOnly: true) { () throws -> Int? in
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            return try FrameIndexStrip.read(
                fromBGRA: base,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer)
            )
        }
    }

    /// Compares a decoded BGRA depth frame's red channel against the luma plane
    /// that was written. The strip rows are skipped: they are hard black and
    /// white edges by design and a lossy encoder rings around them.
    private static func compareDepth(
        bgra: CVPixelBuffer, luma: CVPixelBuffer
    ) -> (total: Double, pixels: Int, worst: Int) {
        PixelBuffers.withLock(bgra, readOnly: true) {
            PixelBuffers.withLock(luma, readOnly: true) {
                guard let a = CVPixelBufferGetBaseAddress(bgra),
                      let b = CVPixelBufferGetBaseAddressOfPlane(luma, 0) else {
                    return (.infinity, 0, Int.max)
                }
                let width = min(CVPixelBufferGetWidth(bgra), CVPixelBufferGetWidthOfPlane(luma, 0))
                let height = min(CVPixelBufferGetHeight(bgra), CVPixelBufferGetHeightOfPlane(luma, 0))
                let strideA = CVPixelBufferGetBytesPerRow(bgra)
                let strideB = CVPixelBufferGetBytesPerRowOfPlane(luma, 0)
                let skip = (try? FrameIndexStrip.geometry(width: width, height: height).cellHeight) ?? 0

                var total = 0.0
                var worst = 0
                var counted = 0
                for y in skip..<height {
                    let rowA = a.advanced(by: y * strideA).assumingMemoryBound(to: UInt8.self)
                    let rowB = b.advanced(by: y * strideB).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width {
                        // BGRA in memory, so the red channel is byte 2.
                        let error = abs(Int(rowA[x * 4 + 2]) - Int(rowB[x]))
                        total += Double(error)
                        worst = max(worst, error)
                        counted += 1
                    }
                }
                return (total, counted, worst)
            }
        }
    }
}
