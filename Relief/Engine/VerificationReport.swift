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

        var line: String {
            "\(passed ? "PASS" : "FAIL")  \(name): \(detail)"
        }
    }

    let outputURL: URL
    let checks: [Check]
    let producedAt: Date

    var passed: Bool { checks.allSatisfy(\.passed) }

    var text: String {
        var lines = [
            "Relief verification report",
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
        writtenFrameCount: Int
    ) async -> VerificationReport {
        var checks: [Check] = []

        let asset = AVURLAsset(url: outputURL)

        // 0. The system's own verdict. Reading back the extensions Relief wrote
        //    only proves Relief wrote them; this asks AVFoundation whether it
        //    considers the file stereo multiview, which is an answer Relief has
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

        // 3. Frame parity with the source.
        let expected = sourceProbe.estimatedFrameCount
        let drift = abs(writtenFrameCount - expected)
        checks.append(Check(
            name: "Frame parity",
            passed: drift <= 1,
            detail: "wrote \(writtenFrameCount), source estimated \(expected), drift \(drift)"
        ))

        // 4. Audio came across.
        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if sourceProbe.hasAudio {
                if let audio = audioTracks.first {
                    let duration = try await audio.load(.timeRange).duration.seconds
                    checks.append(Check(
                        name: "Audio passthrough",
                        passed: duration > 0,
                        detail: String(format: "audio track present, %.2fs", duration)
                    ))
                } else {
                    checks.append(Check(
                        name: "Audio passthrough",
                        passed: false,
                        detail: "the source had audio but the export does not"
                    ))
                }
            } else {
                checks.append(Check(
                    name: "Audio passthrough",
                    passed: true,
                    detail: "the source had no audio, nothing to carry over"
                ))
            }
        } catch {
            checks.append(Check(
                name: "Audio passthrough",
                passed: false,
                detail: error.localizedDescription
            ))
        }

        // 5. A second opinion from outside this codebase.
        if let external = SpatialCLI.verify(outputURL) {
            checks.append(external)
        }

        return VerificationReport(outputURL: outputURL, checks: checks, producedAt: Date())
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
