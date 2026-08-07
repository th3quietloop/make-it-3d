import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Phase 0's gate: a file on disk that AVAssetReader opens, with three tracks
/// and parseable JSON.
///
/// It goes further than the gate asks, because the cheap extra assertions are
/// the ones that catch a format drift between this app and the Mac app: the
/// depth track's size against the halving rule, the shots against the duration
/// they claim to cover, and the depth levels against what was written. The
/// format is the interface between two people who cannot see each other's work,
/// so it is worth over-measuring.
enum FormatCheck {

    /// Writes a fixture into `directory` and measures everything about it.
    static func run(in directory: URL, spec: DepthTrackSpec = DepthTrackSpec()) async throws -> [CheckResult] {
        var results = [CheckResult]()

        let clip = try SyntheticDepthClip(spec: spec)
        let url = directory.appending(path: "fixture-format.mov")
        _ = try await DepthTrackWriter.write(to: url, source: clip)

        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw CheckAborted(check: "Format", reason: "the fixture was not written.")
        }
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false)
        )
        let size = (attributes?[.size] as? Int) ?? 0
        results.append(.pass("Fixture written", "\(url.lastPathComponent), \(size) bytes"))

        // MARK: Tracks

        let asset = AVURLAsset(url: url)
        let allTracks = try await asset.load(.tracks)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let metadataTracks = try await asset.loadTracks(withMediaType: .metadata)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        let expectedTrackCount = 3 + (spec.includeTone ? 1 : 0)
        results.append(CheckResult(
            name: "Track count",
            passed: allTracks.count == expectedTrackCount
                && videoTracks.count == 2
                && metadataTracks.count == 1
                && audioTracks.count == (spec.includeTone ? 1 : 0),
            detail: """
                \(allTracks.count) tracks, want \(expectedTrackCount). \
                video \(videoTracks.count) want 2, \
                metadata \(metadataTracks.count) want 1, \
                audio \(audioTracks.count) want \(spec.includeTone ? 1 : 0)
                """
        ))

        // MARK: The reader's own view

        let file = try await DepthTrackReader.open(url: url)
        results.append(CheckResult(
            name: "Depth track found",
            passed: file.hasDepthTrack,
            detail: file.hasDepthTrack
                ? "the reader sees a depth track and the dial is live"
                : "the reader found no depth track: \(file.dialDisabledReason ?? "no reason given")"
        ))

        let marked = try await DepthTrackReader.isMarked(asset: asset)
        results.append(CheckResult(
            name: "Marker present",
            passed: marked,
            detail: marked
                ? "\(DepthTrack.markerKey) = \(DepthTrack.formatVersion)"
                : "\(DepthTrack.markerKey) is missing, so a player has to probe every track"
        ))

        let expectedDepth = DepthTrack.depthSize(forSourceWidth: spec.width, height: spec.height)
        let depthMatches = file.depth?.width == expectedDepth.width
            && file.depth?.height == expectedDepth.height
        results.append(CheckResult(
            name: "Depth resolution",
            passed: depthMatches && file.width == spec.width && file.height == spec.height,
            detail: """
                colour \(file.width)x\(file.height) want \(spec.width)x\(spec.height), \
                depth \(file.depth.map { "\($0.width)x\($0.height)" } ?? "none") \
                want \(expectedDepth.width)x\(expectedDepth.height)
                """
        ))

        // MARK: Shots

        let shots = file.depth?.shots ?? []
        let expectedShots = clip.shots
        results.append(CheckResult(
            name: "Shot metadata parses",
            passed: !shots.isEmpty && shots.count == expectedShots.count,
            detail: "\(shots.count) shots read, \(expectedShots.count) written"
        ))

        results.append(shotValuesResult(read: shots, written: expectedShots))
        results.append(shotCoverageResult(shots: shots, duration: spec.duration))

        // MARK: Frames

        results.append(contentsOf: try await frameResults(url: url, clip: clip))

        return results
    }

    // MARK: Shot comparisons

    /// Every field of every shot, compared to what was written.
    ///
    /// Doubles go through JSON, so they are compared with a tolerance rather
    /// than for equality. The tolerance is tight enough that a real disagreement
    /// cannot hide inside it.
    private static func shotValuesResult(read: [Shot], written: [Shot]) -> CheckResult {
        guard read.count == written.count else {
            return .fail("Shot values", "\(read.count) read against \(written.count) written")
        }
        let tolerance = 1e-9
        var worst = 0.0
        var worstField = "none"

        for (index, pair) in zip(read, written).enumerated() {
            let (got, want) = pair
            if got.metadata.version != want.metadata.version {
                return .fail("Shot values", "shot \(index) version \(got.metadata.version), want \(want.metadata.version)")
            }
            if got.metadata.shot != want.metadata.shot {
                return .fail("Shot values", "shot \(index) numbered \(got.metadata.shot), want \(want.metadata.shot)")
            }
            let fields: [(String, Double, Double)] = [
                ("depthScale", got.metadata.depthScale, want.metadata.depthScale),
                ("depthOffset", got.metadata.depthOffset, want.metadata.depthOffset),
                ("suggestedStrength", got.metadata.suggestedStrength, want.metadata.suggestedStrength),
                ("suggestedConvergence", got.metadata.suggestedConvergence, want.metadata.suggestedConvergence),
                ("comfortLoad", got.metadata.comfortLoad, want.metadata.comfortLoad)
            ]
            for (name, gotValue, wantValue) in fields where abs(gotValue - wantValue) > worst {
                worst = abs(gotValue - wantValue)
                worstField = "\(name) on shot \(index)"
            }
        }

        return CheckResult(
            name: "Shot values",
            passed: worst <= tolerance,
            detail: String(format: "largest disagreement %.3g (%@), tolerance %.0e", worst, worstField, tolerance)
        )
    }

    /// The shots must tile the duration: no gap, no overlap, no shortfall.
    private static func shotCoverageResult(shots: [Shot], duration: CMTime) -> CheckResult {
        guard let first = shots.first, let last = shots.last else {
            return .fail("Shot coverage", "there are no shots to cover anything")
        }
        var gaps = 0
        for (previous, next) in zip(shots, shots.dropFirst()) where previous.timeRange.end != next.timeRange.start {
            gaps += 1
        }
        let startsAtZero = first.timeRange.start == .zero
        let endsAtDuration = last.timeRange.end == duration
        return CheckResult(
            name: "Shot coverage",
            passed: gaps == 0 && startsAtZero && endsAtDuration,
            detail: """
                \(gaps) gap(s), starts at \(first.timeRange.start.seconds)s \
                (want 0), ends at \(last.timeRange.end.seconds)s \
                (want \(duration.seconds))
                """
        )
    }

    // MARK: Frame comparisons

    /// Decodes every frame and compares it against what the generator produced.
    ///
    /// Two things are being measured. The frame counts, because a depth track
    /// that runs one frame short is a depth track that drifts. And the depth
    /// levels, because full range luma survives an HEVC round trip in theory
    /// and this is the part where theory meets an encoder.
    private static func frameResults(url: URL, clip: SyntheticDepthClip) async throws -> [CheckResult] {
        let reader = try await TrackPairReader.open(url: url)
        defer { reader.cancel() }

        var frames = 0
        var mismatchedIndices = 0
        var unreadableStrips = 0
        var timeDisagreements = 0
        var sampledFrames = 0
        var totalAbsoluteError = 0.0
        var comparedPixels = 0
        var worstError = 0

        while let pair = try reader.next() {
            let expectedTime = clip.spec.time(ofFrame: frames)
            if pair.colorTime != expectedTime || pair.depthTime != expectedTime {
                timeDisagreements += 1
            }

            let colorIndex = try TrackPairReader.colorIndex(of: pair.color)
            let depthIndex = try TrackPairReader.depthIndex(of: pair.depth)
            switch (colorIndex, depthIndex) {
            case let (colour?, depth?):
                if colour != depth || colour != frames % FrameIndexStrip.cycle {
                    mismatchedIndices += 1
                }
            default:
                unreadableStrips += 1
            }

            // Levels are compared on a handful of frames rather than all of
            // them: it is a full raster comparison and the answer does not
            // change from frame to frame within a shot.
            if frames % 17 == 0 {
                let written = try clip.depthFrame(at: frames)
                let comparison = compareLuma(decoded: pair.depth, written: written)
                totalAbsoluteError += comparison.totalError
                comparedPixels += comparison.pixels
                worstError = max(worstError, comparison.worst)
                sampledFrames += 1
            }

            frames += 1
        }

        var results = [CheckResult]()

        results.append(CheckResult(
            name: "Frame count",
            passed: frames == clip.spec.frameCount,
            detail: "\(frames) paired frames decoded, want \(clip.spec.frameCount)"
        ))

        results.append(CheckResult(
            name: "Frame timestamps",
            passed: timeDisagreements == 0,
            detail: "\(timeDisagreements) frame(s) where colour or depth did not land on its own frame time"
        ))

        results.append(CheckResult(
            name: "Frame index strips",
            passed: mismatchedIndices == 0 && unreadableStrips == 0,
            detail: """
                \(mismatchedIndices) mismatched, \(unreadableStrips) unreadable, \
                across \(frames) frames
                """
        ))

        let meanError = comparedPixels > 0 ? totalAbsoluteError / Double(comparedPixels) : .infinity
        results.append(CheckResult(
            name: "Depth levels survive the encoder",
            // Two levels of mean error out of 255 is a quarter of a percent of
            // the depth range, which the warp cannot express as even one pixel
            // of disparity at any strength this app offers.
            passed: meanError <= 2.0 && worstError <= 24,
            detail: String(
                format: "mean %.3f levels (limit 2.0), worst %d levels (limit 24), over %d frames",
                meanError, worstError, sampledFrames
            )
        ))

        return results
    }

    /// Mean and worst absolute difference between two luma planes.
    ///
    /// The frame index strip's rows are skipped. They are hard black and white
    /// edges by design, which is exactly what a lossy encoder rings around, and
    /// including them would measure the strip rather than the depth.
    private static func compareLuma(
        decoded: CVPixelBuffer, written: CVPixelBuffer
    ) -> (totalError: Double, pixels: Int, worst: Int) {
        PixelBuffers.withLock(decoded, readOnly: true) {
            PixelBuffers.withLock(written, readOnly: true) {
                guard let a = CVPixelBufferGetBaseAddressOfPlane(decoded, 0),
                      let b = CVPixelBufferGetBaseAddressOfPlane(written, 0) else {
                    return (.infinity, 0, Int.max)
                }
                let width = min(
                    CVPixelBufferGetWidthOfPlane(decoded, 0),
                    CVPixelBufferGetWidthOfPlane(written, 0)
                )
                let height = min(
                    CVPixelBufferGetHeightOfPlane(decoded, 0),
                    CVPixelBufferGetHeightOfPlane(written, 0)
                )
                let strideA = CVPixelBufferGetBytesPerRowOfPlane(decoded, 0)
                let strideB = CVPixelBufferGetBytesPerRowOfPlane(written, 0)

                let skip = (try? FrameIndexStrip.geometry(width: width, height: height).cellHeight) ?? 0
                var total = 0.0
                var worst = 0
                var counted = 0

                for y in skip..<height {
                    let rowA = a.advanced(by: y * strideA).assumingMemoryBound(to: UInt8.self)
                    let rowB = b.advanced(by: y * strideB).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width {
                        let error = abs(Int(rowA[x]) - Int(rowB[x]))
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
