import AVFoundation
import CoreImage
import CoreVideo
import CoreGraphics
import Foundation

/// What the stage is showing.
enum PreviewMode: Int, CaseIterable, Identifiable, Sendable {
    case source = 1
    case depth = 2
    case stereo = 3
    case wiggle = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .source: return "Source"
        case .depth: return "Depth"
        // Named for what you see, not for the technique. "Wiggle" is the
        // most useful mode in the app and told a first time user nothing.
        case .stereo: return "3D"
        case .wiggle: return "Compare eyes"
        }
    }

    var shortcut: Character {
        Character("\(rawValue)")
    }
}

/// A rendered preview, ready for the stage.
struct PreviewImage: @unchecked Sendable {
    /// What Wiggle alternates between. For every other mode, `right` is nil.
    let left: CGImage
    let right: CGImage?

    var isPair: Bool { right != nil }
}

/// Renders the stage.
///
/// The point of this type is the cache. Running the depth model on a frame
/// costs tens of milliseconds; changing the strength preset should cost almost
/// nothing. So the model output for the visible frame is held, and a parameter
/// change re-runs only the disparity mapping and the warp. The model never runs
/// again until the playhead or the file moves.
actor PreviewEngine {

    private struct FrameKey: Equatable {
        let url: URL
        let timeValue: Double
        let precise: Bool
    }

    private var estimator: CoreMLDepthEstimator?
    private var stabilizer: Stabilizer?
    private var renderer: WarpRenderer?
    private var rendererSize: (width: Int, height: Int)?

    private var cachedKey: FrameKey?
    private var cachedFrame: CVPixelBuffer?
    private var cachedNearness: NearnessMap?

    private var cachedGenerator: AVAssetImageGenerator?
    private var cachedGeneratorURL: URL?

    private var scratchLeft: CVPixelBuffer?
    private var scratchRight: CVPixelBuffer?
    private var scratchComposite: CVPixelBuffer?

    private let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Set when the model could not be loaded, so the UI can say so once
    /// instead of failing on every scrub.
    private(set) var modelFailure: String?

    // MARK: Frame preparation

    /// Decodes the frame at `time`, runs the depth model on it, and caches
    /// both. Cheap to call repeatedly with the same arguments.
    func prepare(
        url: URL,
        time: CMTime,
        tuning: EngineTuning,
        precise: Bool = true
    ) async throws {
        let key = FrameKey(url: url, timeValue: time.seconds, precise: precise)
        if key == cachedKey, cachedNearness != nil { return }
        // A precise request is already satisfied by a precise render of the
        // same frame, but never by the fast one.
        if !precise,
           let cachedKey,
           cachedKey.url == url, cachedKey.timeValue == time.seconds,
           cachedNearness != nil {
            return
        }

        let frame = try await decode(url: url, time: time, tuning: tuning, precise: precise)

        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        try prepareRenderer(width: width, height: height, tuning: tuning)

        let estimator = try loadEstimator()

        // The preview skips the temporal smoothing, so a scrub is a fair look
        // at this frame rather than a blend with wherever the playhead happened
        // to be before. It does not skip normalization: without it the model's
        // raw inverse depth sits on an arbitrary scale and the whole frame
        // lands on one side of the screen plane.
        let stabilizer = self.stabilizer ?? Stabilizer(tuning: tuning)
        self.stabilizer = stabilizer
        let nearness = stabilizer.normalize(try estimator.nearness(from: frame))

        cachedKey = key
        cachedFrame = frame
        cachedNearness = nearness
    }

    /// Drops the cache. Called when the model or the file changes underneath.
    func invalidate() {
        cachedKey = nil
        cachedFrame = nil
        cachedNearness = nil
        cachedGenerator = nil
        cachedGeneratorURL = nil
    }

    // MARK: Rendering

    /// Renders the cached frame in the requested mode. Runs no model work, so
    /// this is what a slider drag calls.
    func render(mode: PreviewMode, tuning: EngineTuning) throws -> PreviewImage {
        guard let frame = cachedFrame, let nearness = cachedNearness, let renderer else {
            throw PreviewError.noFrame
        }

        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)

        switch mode {
        case .source:
            return PreviewImage(left: try image(from: frame), right: nil)

        case .depth:
            let field = Disparity.field(from: nearness, frameWidth: width, tuning: tuning)
            let destination = try scratch(.composite, width: width, height: height)
            try renderer.renderDepthRamp(disparity: field, source: frame, into: destination)
            return PreviewImage(left: try image(from: destination), right: nil)

        case .stereo:
            let (left, right) = try synthesize(frame: frame, nearness: nearness, tuning: tuning)
            let destination = try scratch(.composite, width: width, height: height)
            try renderer.composeAnaglyph(left: left, right: right, into: destination)
            return PreviewImage(left: try image(from: destination), right: nil)

        case .wiggle:
            let (left, right) = try synthesize(frame: frame, nearness: nearness, tuning: tuning)
            return PreviewImage(left: try image(from: left), right: try image(from: right))
        }
    }

    private func synthesize(
        frame: CVPixelBuffer,
        nearness: NearnessMap,
        tuning: EngineTuning
    ) throws -> (CVPixelBuffer, CVPixelBuffer) {
        guard let renderer else { throw PreviewError.noFrame }
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)

        let field = Disparity.field(from: nearness, frameWidth: width, tuning: tuning)
        let left = try scratch(.left, width: width, height: height)
        let right = try scratch(.right, width: width, height: height)
        try renderer.synthesize(source: frame, disparity: field, into: left, and: right)
        return (left, right)
    }

    /// Width of the frame the preview is currently working at, which the depth
    /// verdict needs in order to express disparity as a fraction of the picture
    /// rather than a raw pixel count.
    var frameWidth: Int? {
        guard let cachedFrame else { return nil }
        return CVPixelBufferGetWidth(cachedFrame)
    }

    /// The disparity range of the visible frame, for the inspector readout.
    func disparityRange(tuning: EngineTuning) -> (near: Float, far: Float)? {
        guard let nearness = cachedNearness, let frame = cachedFrame else { return nil }
        let field = Disparity.field(
            from: nearness, frameWidth: CVPixelBufferGetWidth(frame), tuning: tuning
        )
        return (field.maxPositive, field.maxNegative)
    }

    /// What the model saw in the visible frame, before normalization. The
    /// disparity range above describes the settings; this describes the shot.
    var depthContent: DepthContent { stabilizer?.lastContent ?? .unknown }

    // MARK: Plumbing

    private func loadEstimator() throws -> CoreMLDepthEstimator {
        if let estimator { return estimator }
        do {
            let loaded = try CoreMLDepthEstimator()
            estimator = loaded
            modelFailure = nil
            return loaded
        } catch {
            modelFailure = error.localizedDescription
            throw error
        }
    }

    private func prepareRenderer(width: Int, height: Int, tuning: EngineTuning) throws {
        if let rendererSize, rendererSize == (width, height), renderer != nil { return }
        renderer = try WarpRenderer(frameWidth: width, frameHeight: height, tuning: tuning)
        rendererSize = (width, height)
        scratchLeft = nil
        scratchRight = nil
        scratchComposite = nil
    }

    private enum Scratch {
        case left, right, composite
    }

    /// Reuses one buffer per slot across renders, so dragging a slider does not
    /// allocate a frame sized buffer on every tick.
    private func scratch(_ slot: Scratch, width: Int, height: Int) throws -> CVPixelBuffer {
        let existing: CVPixelBuffer?
        switch slot {
        case .left: existing = scratchLeft
        case .right: existing = scratchRight
        case .composite: existing = scratchComposite
        }

        if let existing,
           CVPixelBufferGetWidth(existing) == width,
           CVPixelBufferGetHeight(existing) == height {
            return existing
        }

        let buffer = try WarpRenderer.makePixelBuffer(width: width, height: height)
        switch slot {
        case .left: scratchLeft = buffer
        case .right: scratchRight = buffer
        case .composite: scratchComposite = buffer
        }
        return buffer
    }

    /// The generator, kept alive per file.
    ///
    /// Building a fresh AVURLAsset and generator on every scrub tick meant
    /// re-opening and re-parsing the movie for each frame, which is most of why
    /// scrubbing a long file felt underwater.
    private func generator(for url: URL) -> AVAssetImageGenerator {
        if let cachedGenerator, cachedGeneratorURL == url { return cachedGenerator }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        cachedGenerator = generator
        cachedGeneratorURL = url
        return generator
    }

    /// Pulls one frame at `time`, scaled down if the source is taller than the
    /// preview budget. Export always runs at full resolution; the preview trades
    /// pixels for the responsiveness the judgment loop needs.
    ///
    /// `precise` is the difference between a scrub in flight and a scrub that
    /// has landed. A zero tolerance seek has to decode forward from the previous
    /// keyframe, which on long GOP H.264 is hundreds of milliseconds. While the
    /// playhead is moving, the nearest sync sample is the right answer, because
    /// the user is hunting for a moment, not inspecting one. The exact frame
    /// arrives a beat after they stop.
    private func decode(
        url: URL,
        time: CMTime,
        tuning: EngineTuning,
        precise: Bool
    ) async throws -> CVPixelBuffer {
        let generator = generator(for: url)
        let tolerance = precise ? CMTime.zero : CMTime(value: 1, timescale: 2)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        // The completion handler form, not the async property. Awaiting
        // `generator.image(at:)` from inside the actor would send the generator
        // across an isolation boundary, and it is deliberately actor confined.
        let cgImage = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Transfer<CGImage>, Error>) in
            generator.generateCGImageAsynchronously(for: time) { image, _, error in
                if let image {
                    continuation.resume(returning: Transfer(image))
                } else {
                    continuation.resume(throwing: error ?? PreviewError.decodeFailed)
                }
            }
        }.value

        var width = cgImage.width
        var height = cgImage.height
        if height > tuning.previewMaxHeight {
            let scale = Double(tuning.previewMaxHeight) / Double(height)
            width = Int((Double(width) * scale).rounded())
            height = tuning.previewMaxHeight
        }
        // The warp mesh and the model both want even dimensions.
        width -= width % 2
        height -= height % 2

        let buffer = try WarpRenderer.makePixelBuffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            throw PreviewError.decodeFailed
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func image(from buffer: CVPixelBuffer) throws -> CGImage {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw PreviewError.renderFailed
        }
        return cgImage
    }
}

enum PreviewError: LocalizedError {
    case noFrame
    case decodeFailed
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .noFrame:
            return "There's no frame to preview yet."
        case .decodeFailed:
            return "Couldn't read a frame at that point in the movie."
        case .renderFailed:
            return "Couldn't draw the preview."
        }
    }
}
