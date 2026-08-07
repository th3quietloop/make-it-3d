import CoreML
import CoreVideo
import Accelerate
import Foundation

/// A depth model that reads a run of frames instead of one.
///
/// Per frame models have no way to know what the previous frame said, so their
/// output wobbles even when the picture barely moves. Make It 3D papers over that
/// with an exponential moving average, which trades flicker for lag and never
/// really fixes either. A model that sees time can just be steady.
protocol WindowedDepthEstimator: AnyObject {
    /// How many frames the model wants at once.
    var windowLength: Int { get }
    /// How many frames at the end of a window are context for the next one
    /// rather than results to use.
    var overlap: Int { get }
    var inputSize: (width: Int, height: Int) { get }

    /// One nearness map per frame in the window.
    func nearness(forWindow frames: [CVPixelBuffer]) throws -> [NearnessMap]
}

extension WindowedDepthEstimator {
    /// How far the window advances between runs.
    var stride: Int { max(windowLength - overlap, 1) }
}

/// Video Depth Anything Small, on the Neural Engine.
///
/// Converted from the Apache-2.0 PyTorch release by Tools/modelconv. The
/// upstream project ships no Core ML build and the request for one had sat
/// open since January 2025, so the conversion script in this repo is the
/// build step.
final class VideoDepthEstimator: WindowedDepthEstimator {

    private let model: MLModel
    private let inputName: String
    private let outputName: String

    let windowLength: Int
    let overlap: Int
    let inputSize: (width: Int, height: Int)

    /// Scratch for scaling frames into the model's square input.
    private var scaledBuffer: CVPixelBuffer
    /// The flat input tensor, reused so a long conversion does not allocate a
    /// hundred megabytes per window.
    private let inputArray: MLMultiArray

    static let modelResourceName = "VideoDepthAnythingSmall"

    static func bundledModelURL() -> URL? {
        Bundle.main.url(forResource: modelResourceName, withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: modelResourceName, withExtension: "mlpackage")
    }

    static var isAvailable: Bool { bundledModelURL() != nil }

    init(modelURL: URL? = VideoDepthEstimator.bundledModelURL()) throws {
        guard let modelURL else { throw DepthEstimatorError.modelMissing }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all

        let resolvedURL: URL
        if modelURL.pathExtension == "mlpackage" {
            do {
                resolvedURL = try MLModel.compileModel(at: modelURL)
            } catch {
                throw DepthEstimatorError.modelLoadFailed(error.localizedDescription)
            }
        } else {
            resolvedURL = modelURL
        }

        do {
            model = try MLModel(contentsOf: resolvedURL, configuration: configuration)
        } catch {
            throw DepthEstimatorError.modelLoadFailed(error.localizedDescription)
        }

        let description = model.modelDescription

        guard let input = description.inputDescriptionsByName.first(where: {
            $0.value.type == .multiArray
        }), let constraint = input.value.multiArrayConstraint else {
            throw DepthEstimatorError.unexpectedModelInterface(
                "It takes no multi array input."
            )
        }
        guard let output = description.outputDescriptionsByName.first(where: {
            $0.value.type == .multiArray
        }) else {
            throw DepthEstimatorError.unexpectedModelInterface("It produces no depth output.")
        }

        // Expected shape is [1, T, 3, H, W]. Read it rather than assume it, so a
        // model converted at a different window size still works.
        let shape = constraint.shape.map(\.intValue)
        guard shape.count == 5, shape[0] == 1, shape[2] == 3 else {
            throw DepthEstimatorError.unexpectedModelInterface(
                "Expected an input shaped [1, frames, 3, height, width], found \(shape)."
            )
        }

        inputName = input.key
        outputName = output.key
        windowLength = shape[1]
        inputSize = (width: shape[4], height: shape[3])
        // Matches the upstream inference settings: 32 frame windows, 10 frames
        // of look ahead context.
        overlap = max(1, windowLength * 10 / 32)

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, shape[4], shape[3], Ingest.pixelFormat,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw DepthEstimatorError.modelLoadFailed("Couldn't allocate the model input buffer.")
        }
        scaledBuffer = buffer

        do {
            inputArray = try MLMultiArray(
                shape: shape.map { NSNumber(value: $0) }, dataType: .float32
            )
        } catch {
            throw DepthEstimatorError.modelLoadFailed(error.localizedDescription)
        }
    }

    // MARK: Inference

    func nearness(forWindow frames: [CVPixelBuffer]) throws -> [NearnessMap] {
        guard !frames.isEmpty else { return [] }

        try fill(inputArray, with: frames)

        let provider: MLFeatureProvider
        do {
            provider = try MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(multiArray: inputArray)]
            )
        } catch {
            throw DepthEstimatorError.inferenceFailed(error.localizedDescription)
        }

        let result: MLFeatureProvider
        do {
            result = try model.prediction(from: provider)
        } catch {
            throw DepthEstimatorError.inferenceFailed(error.localizedDescription)
        }

        guard let depth = result.featureValue(for: outputName)?.multiArrayValue else {
            throw DepthEstimatorError.inferenceFailed("The model returned no depth.")
        }

        return try unpack(depth)
    }

    /// Writes the window into the model's tensor as planar RGB in 0...1.
    ///
    /// The conversion baked the ImageNet normalization into the graph, so this
    /// only has to hand over plain colour.
    private func fill(_ array: MLMultiArray, with frames: [CVPixelBuffer]) throws {
        let width = inputSize.width
        let height = inputSize.height
        let planeStride = width * height
        let frameStride = planeStride * 3

        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)

        for index in 0..<windowLength {
            // A short final window repeats its last frame rather than feeding
            // the model black, which would drag the depth toward nothing.
            let source = frames[min(index, frames.count - 1)]
            try scale(source, into: scaledBuffer)

            CVPixelBufferLockBaseAddress(scaledBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(scaledBuffer, .readOnly) }

            guard let base = CVPixelBufferGetBaseAddress(scaledBuffer) else {
                throw DepthEstimatorError.inferenceFailed("Couldn't address the scaled frame.")
            }
            let rowBytes = CVPixelBufferGetBytesPerRow(scaledBuffer)
            let frameBase = pointer.advanced(by: index * frameStride)

            // BGRA in, planar RGB out.
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let pixel = row.advanced(by: x * 4)
                    let offset = y * width + x
                    frameBase[offset] = Float(pixel[2]) / 255.0
                    frameBase[planeStride + offset] = Float(pixel[1]) / 255.0
                    frameBase[planeStride * 2 + offset] = Float(pixel[0]) / 255.0
                }
            }
        }
    }

    /// Splits the model's [1, T, H, W] output into one map per frame.
    private func unpack(_ array: MLMultiArray) throws -> [NearnessMap] {
        let shape = array.shape.map(\.intValue)
        guard shape.count == 4 else {
            throw DepthEstimatorError.unexpectedModelInterface(
                "Expected depth shaped [1, frames, height, width], found \(shape)."
            )
        }
        let frames = shape[1]
        let height = shape[2]
        let width = shape[3]
        let count = width * height

        var maps: [NearnessMap] = []
        maps.reserveCapacity(frames)

        switch array.dataType {
        case .float32:
            let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
            for index in 0..<frames {
                var values = [Float](repeating: 0, count: count)
                values.withUnsafeMutableBufferPointer { out in
                    out.baseAddress?.update(
                        from: pointer.advanced(by: index * count), count: count
                    )
                }
                maps.append(NearnessMap(values: values, width: width, height: height))
            }
        case .float16:
            let pointer = array.dataPointer.assumingMemoryBound(to: UInt16.self)
            for index in 0..<frames {
                var values = [Float](repeating: 0, count: count)
                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: pointer.advanced(by: index * count)),
                    height: 1, width: vImagePixelCount(count), rowBytes: count * 2
                )
                values.withUnsafeMutableBufferPointer { out in
                    guard let base = out.baseAddress else { return }
                    var destination = vImage_Buffer(
                        data: base, height: 1,
                        width: vImagePixelCount(count), rowBytes: count * 4
                    )
                    _ = vImageConvert_Planar16FtoPlanarF(&source, &destination, 0)
                }
                maps.append(NearnessMap(values: values, width: width, height: height))
            }
        default:
            throw DepthEstimatorError.unexpectedModelInterface(
                "Depth data type \(array.dataType.rawValue) is unsupported."
            )
        }
        return maps
    }

    /// Non uniform scale to the model's square input, for the same reason the
    /// per frame estimator does it: a centre crop would leave the sides of a
    /// 16:9 frame with no depth at all.
    private func scale(_ source: CVPixelBuffer, into destination: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(destination, [])
        }

        guard let sourceData = CVPixelBufferGetBaseAddress(source),
              let destinationData = CVPixelBufferGetBaseAddress(destination) else {
            throw DepthEstimatorError.inferenceFailed("Couldn't address the frame buffers.")
        }

        var input = vImage_Buffer(
            data: sourceData,
            height: vImagePixelCount(CVPixelBufferGetHeight(source)),
            width: vImagePixelCount(CVPixelBufferGetWidth(source)),
            rowBytes: CVPixelBufferGetBytesPerRow(source)
        )
        var output = vImage_Buffer(
            data: destinationData,
            height: vImagePixelCount(CVPixelBufferGetHeight(destination)),
            width: vImagePixelCount(CVPixelBufferGetWidth(destination)),
            rowBytes: CVPixelBufferGetBytesPerRow(destination)
        )

        let error = vImageScale_ARGB8888(&input, &output, nil, vImage_Flags(kvImageHighQualityResampling))
        guard error == kvImageNoError else {
            throw DepthEstimatorError.inferenceFailed("Scaling the frame failed (\(error)).")
        }
    }
}

/// Lines successive windows up with each other.
///
/// The model predicts relative depth, so each window is free to pick its own
/// scale and offset. Left alone, that shows up as a visible jump every time the
/// window advances. Fitting the new window's overlapping frames onto the
/// previous window's values for the same frames removes it.
enum WindowAlignment {

    /// Least squares fit of `scale` and `shift` such that
    /// `scale * incoming + shift` best matches `reference`.
    static func fit(incoming: [Float], reference: [Float]) -> (scale: Float, shift: Float) {
        precondition(incoming.count == reference.count)
        let count = incoming.count
        guard count > 0 else { return (1, 0) }

        var sumX: Float = 0, sumY: Float = 0, sumXX: Float = 0, sumXY: Float = 0
        vDSP_sve(incoming, 1, &sumX, vDSP_Length(count))
        vDSP_sve(reference, 1, &sumY, vDSP_Length(count))
        vDSP_svesq(incoming, 1, &sumXX, vDSP_Length(count))
        vDSP_dotpr(incoming, 1, reference, 1, &sumXY, vDSP_Length(count))

        let n = Float(count)
        let denominator = n * sumXX - sumX * sumX
        // A window with no variation gives nothing to fit against, so leave it.
        guard abs(denominator) > 1e-6 else { return (1, 0) }

        let scale = (n * sumXY - sumX * sumY) / denominator
        let shift = (sumY - scale * sumX) / n
        return (scale, shift)
    }

    static func apply(_ map: NearnessMap, scale: Float, shift: Float) -> NearnessMap {
        var values = map.values
        var multiplier = scale
        var offset = shift
        vDSP_vsmsa(values, 1, &multiplier, &offset, &values, 1, vDSP_Length(values.count))
        return NearnessMap(values: values, width: map.width, height: map.height)
    }
}
