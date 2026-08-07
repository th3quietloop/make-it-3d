import AVFoundation
import CoreMedia
import Foundation

/// Phase 1's gate at the file level: colour and depth stay frame aligned across
/// a two minute clip with zero drift.
///
/// It reads the frame index out of the picture of both tracks and compares
/// them. Nothing here trusts a timestamp to mean the frames agree, because a
/// timestamp is what a drift would still look correct in: two tracks can both
/// claim frame 900 while carrying different pictures, and only the pictures can
/// tell you.
///
/// Zero drift is the bar, so the tolerance is zero. One mismatched frame fails.
enum FrameAlignmentCheck {

    /// Two minutes at 30 fps, which is the gate the PRD names.
    static let defaultFrameCount = 3600

    static func run(
        in directory: URL,
        spec: DepthTrackSpec = DepthTrackSpec(frameCount: defaultFrameCount)
    ) async throws -> [CheckResult] {
        let clip = try SyntheticDepthClip(spec: spec)
        let url = directory.appending(path: "fixture-alignment.mov")
        let start = Date()
        _ = try await DepthTrackWriter.write(to: url, source: clip)
        let wrote = Date().timeIntervalSince(start)

        let reader = try await TrackPairReader.open(url: url)
        defer { reader.cancel() }

        var frames = 0
        var mismatched = 0
        var unreadable = 0
        var timeDrift = 0
        var firstFailure: String?

        while let pair = try reader.next() {
            let expected = spec.time(ofFrame: frames)
            if pair.colorTime != expected || pair.depthTime != expected {
                timeDrift += 1
            }

            let colorIndex = try TrackPairReader.colorIndex(of: pair.color)
            let depthIndex = try TrackPairReader.depthIndex(of: pair.depth)

            switch (colorIndex, depthIndex) {
            case let (colour?, depth?):
                let want = frames % FrameIndexStrip.cycle
                if colour != depth || colour != want {
                    mismatched += 1
                    if firstFailure == nil {
                        firstFailure = "frame \(frames): colour says \(colour), depth says \(depth), want \(want)"
                    }
                }
            default:
                unreadable += 1
                if firstFailure == nil {
                    firstFailure = "frame \(frames): the index strip could not be read"
                }
            }

            frames += 1
        }

        let minutes = Double(spec.frameCount) / Double(spec.frameRate) / 60

        return [
            CheckResult(
                name: "Alignment fixture length",
                passed: frames == spec.frameCount,
                detail: String(
                    format: "%d frames decoded of %d, %.1f minutes, written in %.1fs",
                    frames, spec.frameCount, minutes, wrote
                )
            ),
            CheckResult(
                name: "Colour and depth stay frame aligned",
                passed: mismatched == 0 && unreadable == 0 && frames == spec.frameCount,
                detail: firstFailure
                    ?? "\(frames) frames, \(mismatched) mismatched, \(unreadable) unreadable, tolerance 0"
            ),
            CheckResult(
                name: "Frame times hold",
                passed: timeDrift == 0,
                detail: "\(timeDrift) frame(s) landed off their own frame time"
            )
        ]
    }
}
