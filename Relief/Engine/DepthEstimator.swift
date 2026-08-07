import CoreML
import CoreVideo
import Foundation
import Accelerate

/// A nearness map: one float per pixel, higher means closer to the viewer.
/// This is the interface contract the whole pipeline depends on, so a different
/// model can be dropped in without touching anything downstream.
struct NearnessMap: @unchecked Sendable {
    let values: [Float]
    let width: Int
    let height: Int

    subscript(x: Int, y: Int) -> Float {
        values[y * width + x]
    }
}

/// One RGB frame in, one nearness map out. The whole model contract.
protocol DepthEstimator: AnyObject {
    /// The size the model wants its input at.
    var inputSize: (width: Int, height: Int) { get }
    func nearness(from frame: CVPixelBuffer) throws -> NearnessMap
}

enum DepthEstimatorError: LocalizedError {
    case modelMissing
    case modelLoadFailed(String)
    case unexpectedModelInterface(String)
    case inferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            return "The depth model is missing. Relief can't read depth without it."
        case .modelLoadFailed(let detail):
            return "The depth model wouldn't load. \(detail)"
        case .unexpectedModelInterface(let detail):
            return "The depth model has an interface Relief doesn't recognize. \(detail)"
        case .inferenceFailed(let detail):
            return "Depth estimation failed. \(detail)"
        }
    }
}

/// Depth Anything V2 Small, running on the Neural Engine.
///
/// The model declares its own input geometry (518x392 for this package) and
/// Relief reads that at runtime rather than hardcoding it, so swapping in a
/// different depth package is a file change and nothing more.
final class CoreMLDepthEstimator: DepthEstimator {

    private let model: MLModel
    private let inputName: String
    private let outputName: String
    let inputSize: (width: Int, height: Int)

    /// A scratch buffer the frame is scaled into before each inference.
    private var scaledBuffer: CVPixelBuffer
    private let scaleContext: vImageConverter?

    static let modelResourceName = "DepthAnythingV2SmallF16"

    static func bundledModelURL() -> URL? {
        Bundle.main.url(forResource: modelResourceName, withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: modelResourceName, withExtension: "mlpackage")
    }

    init(modelURL: URL? = CoreMLDepthEstimator.bundledModelURL()) throws {
        guard let modelURL else { throw DepthEstimatorError.modelMissing }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all

        let resolvedURL: URL
        if modelURL.pathExtension == "mlpackage" {
            // An uncompiled package in the bundle gets compiled once on first
            // use. Xcode normally compiles it at build time; this covers the
            // case where it arrives as a plain resource.
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
            $0.value.type == .image
        }) else {
            throw DepthEstimatorError.unexpectedModelInterface("It takes no image input.")
        }
        guard let constraint = input.value.imageConstraint else {
            throw DepthEstimatorError.unexpectedModelInterface("Its input has no image constraint.")
        }
        guard let output = description.outputDescriptionsByName.first(where: {
            $0.value.type == .image || $0.value.type == .multiArray
        }) else {
            throw DepthEstimatorError.unexpectedModelInterface("It produces no depth output.")
        }

        inputName = input.key
        outputName = output.key
        inputSize = (constraint.pixelsWide, constraint.pixelsHigh)

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            constraint.pixelsWide,
            constraint.pixelsHigh,
            Ingest.pixelFormat,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw DepthEstimatorError.modelLoadFailed("Couldn't allocate the model input buffer.")
        }
        scaledBuffer = buffer
        scaleContext = nil
    }

    func nearness(from frame: CVPixelBuffer) throws -> NearnessMap {
        try scale(frame, into: scaledBuffer)

        let provider: MLFeatureProvider
        do {
            provider = try MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(pixelBuffer: scaledBuffer)]
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

        guard let value = result.featureValue(for: outputName) else {
            throw DepthEstimatorError.inferenceFailed("The model returned no depth.")
        }

        if let buffer = value.imageBufferValue {
            return try Self.nearnessMap(fromFloatBuffer: buffer)
        }
        if let array = value.multiArrayValue {
            return try Self.nearnessMap(fromArray: array)
        }
        throw DepthEstimatorError.inferenceFailed("The depth output was not an image or array.")
    }

    // MARK: Input scaling

    /// Scales the frame to the model's declared input size, filling it exactly.
    ///
    /// This is a non uniform scale rather than a centre crop on purpose. A crop
    /// would leave the left and right edges of a 16:9 frame with no depth at
    /// all, which shows up as a hard artifact after the warp. Depth Anything
    /// tolerates modest aspect distortion, and every source pixel getting a
    /// depth value matters more here than preserving the aspect into the model.
    private func scale(_ source: CVPixelBuffer, into destination: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(destination, [])
        }

        guard let srcData = CVPixelBufferGetBaseAddress(source),
              let dstData = CVPixelBufferGetBaseAddress(destination) else {
            throw DepthEstimatorError.inferenceFailed("Couldn't address the frame buffers.")
        }

        var src = vImage_Buffer(
            data: srcData,
            height: vImagePixelCount(CVPixelBufferGetHeight(source)),
            width: vImagePixelCount(CVPixelBufferGetWidth(source)),
            rowBytes: CVPixelBufferGetBytesPerRow(source)
        )
        var dst = vImage_Buffer(
            data: dstData,
            height: vImagePixelCount(CVPixelBufferGetHeight(destination)),
            width: vImagePixelCount(CVPixelBufferGetWidth(destination)),
            rowBytes: CVPixelBufferGetBytesPerRow(destination)
        )

        let error = vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
        guard error == kvImageNoError else {
            throw DepthEstimatorError.inferenceFailed("Scaling the frame failed (\(error)).")
        }
    }

    // MARK: Output unpacking

    /// The model emits a one component float image. Higher is closer.
    ///
    /// The component width is read from the pixel format rather than assumed.
    /// This package emits 16 bit half floats, and reading those as 32 bit
    /// floats does not fail loudly: it consumes two rows of source for every
    /// row of output, so the depth map comes out looking like the frame
    /// repeated side by side, at plausible looking values. Both the preview and
    /// the export were fed that.
    private static func nearnessMap(fromFloatBuffer buffer: CVPixelBuffer) throws -> NearnessMap {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)

        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw DepthEstimatorError.inferenceFailed("Couldn't address the depth output.")
        }

        var values = [Float](repeating: 0, count: width * height)

        switch format {
        case kCVPixelFormatType_OneComponent32Float:
            values.withUnsafeMutableBufferPointer { out in
                guard let outBase = out.baseAddress else { return }
                for y in 0..<height {
                    let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                    outBase.advanced(by: y * width).update(from: row, count: width)
                }
            }

        case kCVPixelFormatType_OneComponent16Half:
            var source = vImage_Buffer(
                data: base,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: rowBytes
            )
            var error = kvImageNoError
            values.withUnsafeMutableBufferPointer { out in
                guard let outBase = out.baseAddress else { return }
                var destination = vImage_Buffer(
                    data: outBase,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * MemoryLayout<Float>.size
                )
                error = vImageConvert_Planar16FtoPlanarF(&source, &destination, 0)
            }
            guard error == kvImageNoError else {
                throw DepthEstimatorError.inferenceFailed(
                    "Couldn't convert the half float depth output (\(error))."
                )
            }

        default:
            throw DepthEstimatorError.unexpectedModelInterface(
                "Depth pixel format \(format) is unsupported."
            )
        }

        return NearnessMap(values: values, width: width, height: height)
    }

    private static func nearnessMap(fromArray array: MLMultiArray) throws -> NearnessMap {
        // Accept both [H, W] and [1, H, W] shapes.
        let shape = array.shape.map(\.intValue)
        let width: Int
        let height: Int
        switch shape.count {
        case 2:
            height = shape[0]; width = shape[1]
        case 3:
            height = shape[1]; width = shape[2]
        case 4:
            height = shape[2]; width = shape[3]
        default:
            throw DepthEstimatorError.unexpectedModelInterface("Depth shape \(shape) is unsupported.")
        }

        var values = [Float](repeating: 0, count: width * height)
        let count = width * height

        switch array.dataType {
        case .float32:
            let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
            values.withUnsafeMutableBufferPointer { out in
                out.baseAddress?.update(from: pointer, count: count)
            }
        case .double:
            let pointer = array.dataPointer.assumingMemoryBound(to: Double.self)
            for i in 0..<count { values[i] = Float(pointer[i]) }
        case .float16:
            let pointer = array.dataPointer.assumingMemoryBound(to: UInt16.self)
            var source = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: pointer),
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
        default:
            throw DepthEstimatorError.unexpectedModelInterface(
                "Depth data type \(array.dataType.rawValue) is unsupported."
            )
        }

        return NearnessMap(values: values, width: width, height: height)
    }
}
