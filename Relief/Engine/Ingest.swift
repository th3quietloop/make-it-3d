import AVFoundation
import CoreVideo
import CoreGraphics
import Foundation
import VideoToolbox

/// What Relief learns about a file before it will offer to convert it.
struct SourceProbe: Sendable, Equatable {
    let url: URL
    let duration: CMTime
    let nominalFrameRate: Double
    let width: Int
    let height: Int
    let hasAudio: Bool
    /// Best effort frame count, from duration times frame rate.
    let estimatedFrameCount: Int

    var displayDuration: String {
        Timecode.string(from: duration.seconds)
    }

    var displayDimensions: String {
        "\(width) x \(height)"
    }
}

enum IngestError: LocalizedError {
    case noVideoTrack
    case unreadable(URL)
    case readerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack, .unreadable:
            // Plain language, per the design file's microcopy.
            return "Couldn't read this file. Relief speaks H.264, HEVC, and ProRes."
        case .readerFailed(let detail):
            return "Couldn't read this file. \(detail)"
        }
    }
}

/// Reads a source movie: probes it, makes a thumbnail, and hands frames to the
/// pipeline as an async stream with backpressure.
struct Ingest {

    /// Pixel format the whole pipeline speaks. BGRA matches what the depth
    /// model wants as input and what Metal renders into.
    static let pixelFormat = kCVPixelFormatType_32BGRA

    // MARK: Probing

    static func probe(url: URL) async throws -> SourceProbe {
        let asset = AVURLAsset(url: url)

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw IngestError.noVideoTrack
        }

        let duration = try await asset.load(.duration)
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rate = try await track.load(.nominalFrameRate)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        // A rotated track reports its pre transform size, so apply the
        // transform to get the size the viewer will actually see.
        let displaySize = naturalSize.applying(transform)
        let width = Int(abs(displaySize.width).rounded())
        let height = Int(abs(displaySize.height).rounded())

        guard width > 0, height > 0 else { throw IngestError.unreadable(url) }

        let fps = rate > 0 ? Double(rate) : 30.0
        let frames = max(1, Int((duration.seconds * fps).rounded()))

        return SourceProbe(
            url: url,
            duration: duration,
            nominalFrameRate: fps,
            width: width,
            height: height,
            hasAudio: !audioTracks.isEmpty,
            estimatedFrameCount: frames
        )
    }

    // MARK: Thumbnails

    /// A single frame as a CGImage, for the queue row thumbnail and for the
    /// stage when the preview is seeking.
    static func image(at time: CMTime, url: URL, maxSize: CGFloat) async throws -> Transfer<CGImage> {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSize, height: maxSize)
        // Land on the requested frame, not the nearest sync sample.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let (cgImage, _) = try await generator.image(at: time)
        return Transfer(cgImage)
    }

    // MARK: Frame streaming

    /// A decoded source frame on its way into the pipeline.
    struct Frame: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let time: CMTime
        let index: Int
    }

    /// Opens a reader over the video track. The caller pulls frames one at a
    /// time, which is the backpressure: the reader only decodes as fast as the
    /// depth model consumes, so memory stays flat on a feature length file.
    ///
    /// Reading goes through a video composition rather than a plain track
    /// output so that a rotated source (a phone clip carrying a 90 degree
    /// preferred transform) arrives already upright and at its display size.
    /// A plain track output would hand back the unrotated buffer and every
    /// stage after this would be working on a sideways frame.
    final class FrameSource {
        private let reader: AVAssetReader
        private let output: AVAssetReaderOutput
        private var index = 0

        let probe: SourceProbe

        static func open(probe: SourceProbe) async throws -> FrameSource {
            let asset = AVURLAsset(url: probe.url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard !tracks.isEmpty else { throw IngestError.noVideoTrack }
            let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
            composition.renderSize = CGSize(width: probe.width, height: probe.height)
            return try FrameSource(probe: probe, asset: asset, tracks: tracks, composition: composition)
        }

        private init(
            probe: SourceProbe,
            asset: AVURLAsset,
            tracks: [AVAssetTrack],
            composition: AVMutableVideoComposition
        ) throws {
            self.probe = probe
            do {
                reader = try AVAssetReader(asset: asset)
            } catch {
                throw IngestError.readerFailed(error.localizedDescription)
            }

            let compositionOutput = AVAssetReaderVideoCompositionOutput(
                videoTracks: tracks,
                videoSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                    kCVPixelBufferMetalCompatibilityKey as String: true
                ]
            )
            compositionOutput.videoComposition = composition
            compositionOutput.alwaysCopiesSampleData = false
            output = compositionOutput

            guard reader.canAdd(compositionOutput) else {
                throw IngestError.readerFailed("The video track could not be opened for reading.")
            }
            reader.add(compositionOutput)

            guard reader.startReading() else {
                throw IngestError.readerFailed(
                    reader.error?.localizedDescription ?? "The reader would not start."
                )
            }
        }

        /// Pulls the next decoded frame, or nil at end of stream.
        func next() throws -> Frame? {
            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .failed {
                    throw IngestError.readerFailed(
                        reader.error?.localizedDescription ?? "Reading stopped unexpectedly."
                    )
                }
                return nil
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
                // A sample with no image buffer is not fatal; skip it.
                return try next()
            }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            let frame = Frame(pixelBuffer: buffer, time: time, index: index)
            index += 1
            return frame
        }

        func cancel() {
            reader.cancelReading()
        }
    }
}

/// Shared timecode formatting so no view invents its own.
enum Timecode {
    static func string(from seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// Frame accurate readout for the scrubber.
    static func precise(seconds: Double, fps: Double) -> String {
        guard seconds.isFinite, seconds >= 0, fps > 0 else { return "0:00.00" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        let frames = Int(((seconds - Double(total)) * fps).rounded())
        return String(format: "%d:%02d.%02d", m, s, frames)
    }
}
