import AVFoundation
import CoreMedia
import Foundation

/// Proof that an export is what it claims to be.
///
/// The four checks are the Phase 1 gate: visionOS and QuickTime decide a file
/// is spatial by reading the format description extensions, so this inspects
/// exactly those rather than trusting that the writer did its job.
struct VerificationReport: Sendable {

    struct Check: Sendable {
        let name: String
        let passed: Bool
        let detail: String
        var skipped: Bool = false

        var line: String {
            "\(skipped ? "SKIP" : (passed ? "PASS" : "FAIL"))  \(name): \(detail)"
        }
    }

    let outputURL: URL
    let checks: [Check]
    let producedAt: Date
    var verifiedFrameCount: Int? = nil

    var passed: Bool { checks.allSatisfy { $0.skipped || $0.passed } }

    var text: String {
        var lines = [
            "Make It 3D verification report",
            "File: \(outputURL.lastPathComponent)",
            "Date: \(ISO8601DateFormatter().string(from: producedAt))",
            ""
        ]
        lines.append(contentsOf: checks.map(\.line))
        lines.append("")
        lines.append(passed ? "RESULT: PASS" : "RESULT: FAIL")
        lines.append("")
        lines.append(
            "Final human check: AirDrop this file to the Vision Pro and open it in Photos."
        )
        return lines.joined(separator: "\n")
    }

    // MARK: Running the checks

    static func verify(
        outputURL: URL,
        sourceProbe: SourceProbe,
        writtenFrameCount: Int,
        sourceFrameCount: Int? = nil,
        tuning: EngineTuning = .default,
        timeRange: CMTimeRange? = nil
    ) async -> VerificationReport {
        var checks: [Check] = []
        var verifiedFrames: Int?

        let asset = AVURLAsset(url: outputURL)

        // 0. The system's own verdict. Reading back the extensions Make It 3D wrote
        //    only proves Make It 3D wrote them; this asks AVFoundation whether it
        //    considers the file stereo multiview, which is an answer Make It 3D has
        //    no hand in producing.
        do {
            let tracks = try await asset.loadTracks(
                withMediaCharacteristic: .containsStereoMultiviewVideo
            )
            checks.append(Check(
                name: "System recognises stereo",
                passed: !tracks.isEmpty,
                detail: tracks.isEmpty
                    ? "AVFoundation does not report a stereo multiview track"
                    : "AVFoundation reports \(tracks.count) stereo multiview video track"
            ))
        } catch {
            checks.append(Check(
                name: "System recognises stereo",
                passed: false,
                detail: error.localizedDescription
            ))
        }

        // 1. Spatial signalling. This is the same metadata QuickTime Player and
        //    visionOS Photos read to decide a file is spatial.
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw IngestError.noVideoTrack
            }
            let formats = try await track.load(.formatDescriptions)
            guard let format = formats.first else {
                throw IngestError.noVideoTrack
            }

            let hasLeft = boolExtension(format, kCMFormatDescriptionExtension_HasLeftStereoEyeView)
            let hasRight = boolExtension(format, kCMFormatDescriptionExtension_HasRightStereoEyeView)

            checks.append(Check(
                name: "Spatial signalling",
                passed: hasLeft && hasRight,
                detail: hasLeft && hasRight
                    ? "left and right stereo eye views are both flagged"
                    : "left flagged: \(hasLeft), right flagged: \(hasRight)"
            ))

            // 2. Two video layers, and the rest of the spatial metadata.
            var details: [String] = []
            if let fov = numberExtension(format, kCMFormatDescriptionExtension_HorizontalFieldOfView) {
                details.append("FOV \(fov.doubleValue / 1000) deg")
            }
            if let baseline = numberExtension(format, kCMFormatDescriptionExtension_StereoCameraBaseline) {
                details.append("baseline \(baseline.doubleValue / 1000) mm")
            }
            if let adjustment = numberExtension(
                format, kCMFormatDescriptionExtension_HorizontalDisparityAdjustment
            ) {
                details.append("disparity adjustment \(adjustment.doubleValue / 10000)")
            }
            if let projection = stringExtension(format, kCMFormatDescriptionExtension_ProjectionKind) {
                details.append("projection \(projection)")
            }

            let layerIDs = layerCount(format)
            checks.append(Check(
                name: "Video layers",
                passed: layerIDs >= 2,
                detail: layerIDs >= 2
                    ? "\(layerIDs) layers. \(details.joined(separator: ", "))"
                    : "expected 2 layers, found \(layerIDs)"
            ))
        } catch {
            checks.append(Check(
                name: "Spatial signalling",
                passed: false,
                detail: "couldn't read the output video track: \(error.localizedDescription)"
            ))
            checks.append(Check(name: "Video layers", passed: false, detail: "not readable"))
        }

        // Count decoded samples, never duration × nominal FPS: phone recordings
        // may be variable-rate and audio may outlast the picture.
        do {
            let expected: Int
            if let sourceFrameCount { expected = sourceFrameCount } else {
                expected = try await decodedFrameCount(url: sourceProbe.url, timeRange: timeRange)
            }
            let decodedOutput = try await decodedFrameCount(url: outputURL)
            verifiedFrames = decodedOutput
            checks.append(Check(
                name: "Frame parity",
                passed: expected > 0 && decodedOutput == expected && writtenFrameCount == expected,
                detail: "source decoded \(expected), appended \(writtenFrameCount), output decoded \(decodedOutput)"
            ))
        } catch {
            checks.append(Check(name: "Frame parity", passed: false, detail: error.localizedDescription))
        }

        // Preserve each overlapping audio track, including its timing and language.
        do {
            let source = AVURLAsset(url: sourceProbe.url)
            let sourceTracks = sourceProbe.hasAudio ? try await source.loadTracks(withMediaType: .audio) : []
            let outputTracks = try await asset.loadTracks(withMediaType: .audio)
            var expected: [(duration: Double, start: Double, language: String?)] = []
            for track in sourceTracks {
                var range = try await track.load(.timeRange)
                if let timeRange {
                    range = CMTimeRangeGetIntersection(range, otherRange: timeRange)
                }
                guard range.isValid, !range.isEmpty else { continue }
                let language = try await track.load(.languageCode)
                expected.append((range.duration.seconds,
                                 range.start.seconds - (timeRange?.start.seconds ?? 0), language))
            }
            var problems: [String] = []
            if expected.count != outputTracks.count {
                problems.append("expected \(expected.count) audio tracks, found \(outputTracks.count)")
            }
            for index in 0..<min(expected.count, outputTracks.count) {
                let range = try await outputTracks[index].load(.timeRange)
                let language = try await outputTracks[index].load(.languageCode)
                let reference = expected[index]
                // Allow codec packet/edit-list rounding, not missing track tails.
                if abs(range.duration.seconds - reference.duration) > 0.1 {
                    problems.append(String(format: "track %d duration %.3fs, expected %.3fs",
                                           index + 1, range.duration.seconds, reference.duration))
                }
                if abs(range.start.seconds - reference.start) > 0.1 {
                    problems.append("track \(index + 1) starts at the wrong time")
                }
                if let expectedLanguage = reference.language, expectedLanguage != "und",
                   expectedLanguage != language {
                    problems.append("track \(index + 1) language was not preserved")
                }
            }
            checks.append(Check(
                name: "Audio passthrough", passed: problems.isEmpty,
                detail: problems.isEmpty
                    ? "\(expected.count) audio tracks; duration, timing and language preserved"
                    : problems.joined(separator: "; ")
            ))
        } catch {
            checks.append(Check(name: "Audio passthrough", passed: false, detail: error.localizedDescription))
        }

        // 5. A second opinion from outside this codebase.
        if let external = SpatialCLI.verify(outputURL, tuning: tuning) {
            checks.append(external)
        }

        return VerificationReport(outputURL: outputURL, checks: checks, producedAt: Date(), verifiedFrameCount: verifiedFrames)
    }

    private static func decodedFrameCount(url: URL, timeRange: CMTimeRange? = nil) async throws -> Int {
        let probe = try await Ingest.probe(url: url)
        let frames = try await Ingest.FrameSource.open(probe: probe, timeRange: timeRange)
        defer { frames.cancel() }
        while try frames.next() != nil { try Task.checkCancellation() }
        return frames.decodedFrameCount
    }

    // MARK: Extension readers

    private static func extensions(_ format: CMFormatDescription) -> [CFString: Any] {
        (CMFormatDescriptionGetExtensions(format) as? [CFString: Any]) ?? [:]
    }

    private static func boolExtension(_ format: CMFormatDescription, _ key: CFString) -> Bool {
        (extensions(format)[key] as? NSNumber)?.boolValue ?? false
    }

    private static func numberExtension(_ format: CMFormatDescription, _ key: CFString) -> NSNumber? {
        extensions(format)[key] as? NSNumber
    }

    private static func stringExtension(_ format: CMFormatDescription, _ key: CFString) -> String? {
        extensions(format)[key] as? String
    }

    /// MV-HEVC layer count, read from the format description. Falls back to
    /// inferring two layers from the stereo eye flags when the encoder does not
    /// republish the layer ID list on the output description.
    private static func layerCount(_ format: CMFormatDescription) -> Int {
        let all = extensions(format)
        if let ids = all["MVHEVCVideoLayerIDs" as CFString] as? [Any] {
            return ids.count
        }
        let hasLeft = boolExtension(format, kCMFormatDescriptionExtension_HasLeftStereoEyeView)
        let hasRight = boolExtension(format, kCMFormatDescriptionExtension_HasRightStereoEyeView)
        return (hasLeft ? 1 : 0) + (hasRight ? 1 : 0)
    }
}
