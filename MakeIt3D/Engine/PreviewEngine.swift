import AVFoundation
import CoreImage
import CoreVideo
import CoreGraphics
import Foundation

/// Existing raw values remain stable for saved sessions and keyboard commands.
enum PreviewMode: Int, CaseIterable, Identifiable, Sendable {
    case source = 1
    case depth = 2
    case stereo = 3
    case wiggle = 4

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .source: "Original"
        case .depth: "Depth map"
        case .stereo: "Red-cyan glasses"
        case .wiggle: "Compare eyes"
        }
    }
    var shortcut: Character { Character("\(rawValue)") }
}

struct PreviewImage: @unchecked Sendable {
    let left: CGImage
    let right: CGImage?
    var isPair: Bool { right != nil }
}

/// Image, time, and measurement cross the actor boundary together. A subsequent
/// seek cannot attach its measurement to an earlier image.
struct PreviewRender: @unchecked Sendable {
    let image: PreviewImage
    let actualSeconds: Double
    let isPrecise: Bool
    let frameWidth: Int
    let content: DepthContent
    let disparity: (near: Float, far: Float)?
}

actor PreviewEngine {
    struct FrameKey: Equatable, Sendable {
        let url: URL
        let timeValue: Double
        let precise: Bool
        let maximumHeight: Int
    }

    private var estimator: CoreMLDepthEstimator?
    private var renderer: WarpRenderer?
    private var rendererSize: (width: Int, height: Int)?
    private var rendererMeshSpacing: Int?
    private var cachedKey: FrameKey?
    private var cachedFrame: CVPixelBuffer?
    private var cachedRawNearness: NearnessMap?
    private var actualSeconds: Double = 0
    private var cachedGenerator: AVAssetImageGenerator?
    private var cachedGeneratorURL: URL?
    private var requestGeneration: UInt64 = 0
    private var scratchLeft: CVPixelBuffer?
    private var scratchRight: CVPixelBuffer?
    private var scratchComposite: CVPixelBuffer?
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private(set) var modelFailure: String?

    /// Original decoding requires neither a depth model nor a Metal renderer.
    /// Depth and rendering are lazy, so the first useful picture arrives before
    /// neural warmup and the original remains available if depth is unavailable.
    func makePreview(
        url: URL,
        time: CMTime,
        mode: PreviewMode,
        tuning: EngineTuning,
        precise: Bool = true,
        fullResolution: Bool = false,
        reconstructionRisk: Bool = false
    ) async throws -> PreviewRender {
        requestGeneration &+= 1
        let generation = requestGeneration
        let key = FrameKey(
            url: url, timeValue: time.seconds, precise: precise,
            maximumHeight: fullResolution ? 0 : tuning.previewMaxHeight
        )
        if !Self.canReuse(cachedKey, for: key) {
            let decoded = try await decode(url: url, time: time, maximumHeight: key.maximumHeight, precise: precise)
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            cachedFrame = decoded.frame
            actualSeconds = decoded.seconds
            cachedRawNearness = nil
            cachedKey = key
            // A still inspection is not a contiguous playback sequence. Never
            // rebuild its holes with whichever unrelated image was visited last.
            renderer?.resetBackgroundPlate()
        }
        try Task.checkCancellation()
        guard generation == requestGeneration, let frame = cachedFrame else { throw CancellationError() }
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)

        if mode == .source && !reconstructionRisk {
            return PreviewRender(
                image: PreviewImage(left: try image(from: frame), right: nil),
                actualSeconds: actualSeconds, isPrecise: cachedKey?.precise ?? precise,
                frameWidth: width, content: .unknown, disparity: nil
            )
        }

        if cachedRawNearness == nil {
            cachedRawNearness = try loadEstimator().nearness(from: frame)
        }
        guard let raw = cachedRawNearness else { throw PreviewError.noFrame }
        // Normalization is cheap and uses the current configuration; the model
        // cache survives strength, balance, and crop changes.
        let normalizer = Stabilizer(tuning: tuning)
        let nearness = normalizer.normalize(raw)
        let field = Disparity.field(from: nearness, frameWidth: width, tuning: tuning)
        try prepareRenderer(width: width, height: height, tuning: tuning)
        guard let renderer else { throw PreviewError.renderFailed }
        let preview: PreviewImage
        if reconstructionRisk {
            let destination = try scratch(.composite, width: width, height: height)
            try renderer.renderReconstructionMask(disparity: field, source: frame, into: destination)
            preview = PreviewImage(left: try image(from: destination), right: nil)
        } else {
            switch mode {
            case .source:
                preview = PreviewImage(left: try image(from: frame), right: nil)
            case .depth:
                let destination = try scratch(.composite, width: width, height: height)
                try renderer.renderDepthRamp(disparity: field, source: frame, into: destination)
                preview = PreviewImage(left: try image(from: destination), right: nil)
            case .stereo, .wiggle:
                let left = try scratch(.left, width: width, height: height)
                let right = try scratch(.right, width: width, height: height)
                // Repeated parameter/A-B renders of this exact frame must be
                // deterministic too; neither alternative seeds the other.
                renderer.resetBackgroundPlate()
                try renderer.synthesize(source: frame, disparity: field, into: left, and: right)
                if mode == .wiggle {
                    preview = PreviewImage(left: try image(from: left), right: try image(from: right))
                } else {
                    let destination = try scratch(.composite, width: width, height: height)
                    try renderer.composeAnaglyph(left: left, right: right, into: destination)
                    preview = PreviewImage(left: try image(from: destination), right: nil)
                }
            }
        }
        return PreviewRender(
            image: preview, actualSeconds: actualSeconds, isPrecise: cachedKey?.precise ?? precise,
            frameWidth: width, content: normalizer.lastContent,
            disparity: (field.maxPositive, field.maxNegative)
        )
    }

    /// A precise result can satisfy an approximate request at the same time;
    /// approximate decoding never satisfies a precise or native-size request.
    nonisolated static func canReuse(_ cached: FrameKey?, for requested: FrameKey) -> Bool {
        guard let cached else { return false }
        return cached.url == requested.url && cached.timeValue == requested.timeValue
            && cached.maximumHeight == requested.maximumHeight
            && (cached.precise || !requested.precise)
    }

    func invalidate() {
        requestGeneration &+= 1
        cachedGenerator?.cancelAllCGImageGeneration()
        cachedKey = nil
        cachedFrame = nil
        cachedRawNearness = nil
        cachedGenerator = nil
        cachedGeneratorURL = nil
        renderer?.resetBackgroundPlate()
        renderer = nil
        rendererSize = nil
        rendererMeshSpacing = nil
        scratchLeft = nil
        scratchRight = nil
        scratchComposite = nil
    }

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
        if let renderer, let rendererSize, rendererSize == (width, height), rendererMeshSpacing == tuning.meshVertexSpacing {
            renderer.updateTuning(tuning)
            return
        }
        renderer = try WarpRenderer(frameWidth: width, frameHeight: height, tuning: tuning)
        rendererSize = (width, height)
        rendererMeshSpacing = tuning.meshVertexSpacing
        scratchLeft = nil
        scratchRight = nil
        scratchComposite = nil
    }

    private enum Scratch { case left, right, composite }
    private func scratch(_ slot: Scratch, width: Int, height: Int) throws -> CVPixelBuffer {
        let existing: CVPixelBuffer?
        switch slot {
        case .left: existing = scratchLeft
        case .right: existing = scratchRight
        case .composite: existing = scratchComposite
        }
        if let existing, CVPixelBufferGetWidth(existing) == width, CVPixelBufferGetHeight(existing) == height {
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

    private func generator(for url: URL) -> AVAssetImageGenerator {
        if let cachedGenerator, cachedGeneratorURL == url { return cachedGenerator }
        cachedGenerator?.cancelAllCGImageGeneration()
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        cachedGenerator = generator
        cachedGeneratorURL = url
        return generator
    }

    private func decode(
        url: URL, time: CMTime, maximumHeight: Int, precise: Bool
    ) async throws -> (frame: CVPixelBuffer, seconds: Double) {
        let generator = generator(for: url)
        generator.cancelAllCGImageGeneration()
        let tolerance = precise ? CMTime.zero : CMTime(value: 1, timescale: 2)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        generator.maximumSize = maximumHeight > 0
            ? CGSize(width: 16384, height: maximumHeight) : .zero
        let decoded = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Transfer<(CGImage, CMTime)>, Error>) in
            generator.generateCGImageAsynchronously(for: time) { image, actual, error in
                if let image {
                    continuation.resume(returning: Transfer((image, actual)))
                } else {
                    continuation.resume(throwing: error ?? PreviewError.decodeFailed)
                }
            }
        }.value
        try Task.checkCancellation()
        let cgImage = decoded.0
        var width = cgImage.width
        var height = cgImage.height
        if maximumHeight > 0, height > maximumHeight {
            width = Int((Double(width) * Double(maximumHeight) / Double(height)).rounded())
            height = maximumHeight
        }
        width = max(2, width - width % 2)
        height = max(2, height - height % 2)
        let buffer = try WarpRenderer.makePixelBuffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { throw PreviewError.decodeFailed }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let seconds = decoded.1.seconds.isFinite ? decoded.1.seconds : time.seconds
        return (buffer, seconds)
    }

    private func image(from buffer: CVPixelBuffer) throws -> CGImage {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { throw PreviewError.renderFailed }
        return cgImage
    }
}

enum PreviewError: LocalizedError {
    case noFrame, decodeFailed, renderFailed
    var errorDescription: String? {
        switch self {
        case .noFrame: "There's no frame to preview yet."
        case .decodeFailed: "Couldn't read a frame at that point in the video."
        case .renderFailed: "Couldn't draw the preview."
        }
    }
}
