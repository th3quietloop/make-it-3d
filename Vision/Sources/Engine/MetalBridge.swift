import CoreVideo
import Foundation
import Metal

enum EngineError: LocalizedError {
    case noDevice
    case shaderLibraryMissing(String)
    case functionMissing(String)
    case pipelineFailed(String)
    case textureAllocationFailed(String)
    case bufferAllocationFailed

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "There is no Metal device here, so nothing can be drawn."
        case .shaderLibraryMissing(let detail):
            return "Make It 3D's shaders would not load. \(detail)"
        case .functionMissing(let name):
            return "The shader \"\(name)\" is missing from the library."
        case .pipelineFailed(let detail):
            return "A render pipeline wouldn't build. \(detail)"
        case .textureAllocationFailed(let detail):
            return "Couldn't allocate a texture. \(detail)"
        case .bufferAllocationFailed:
            return "Couldn't allocate the warp mesh."
        }
    }
}

/// A Metal texture that is a view onto a CVPixelBuffer.
///
/// The CVMetalTexture is held alongside the MTLTexture on purpose. The mapping
/// between the two is what keeps the underlying IOSurface bound, and letting it
/// go while a command buffer is still reading produces a texture full of
/// whatever came next. Holding the pair together until the frame is done makes
/// that impossible to get wrong by accident.
struct BridgedTexture {
    let texture: MTLTexture
    private let mapping: CVMetalTexture

    init(texture: MTLTexture, mapping: CVMetalTexture) {
        self.texture = texture
        self.mapping = mapping
    }
}

/// Turns decoded video frames into Metal textures without a copy.
final class TextureBridge {

    private let cache: CVMetalTextureCache

    init(device: MTLDevice) throws {
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw EngineError.textureAllocationFailed("The texture cache would not open (\(status)).")
        }
        self.cache = cache
    }

    /// A whole buffer as one texture. For 32BGRA frames.
    func texture(from buffer: CVPixelBuffer, format: MTLPixelFormat) throws -> BridgedTexture {
        try texture(
            from: buffer,
            plane: 0,
            format: format,
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            planar: false
        )
    }

    /// One plane of a planar buffer. For the luma plane of a 420 depth frame,
    /// which is where the depth levels actually live.
    func lumaTexture(from buffer: CVPixelBuffer) throws -> BridgedTexture {
        try texture(
            from: buffer,
            plane: 0,
            format: .r8Unorm,
            width: CVPixelBufferGetWidthOfPlane(buffer, 0),
            height: CVPixelBufferGetHeightOfPlane(buffer, 0),
            planar: true
        )
    }

    private func texture(
        from buffer: CVPixelBuffer,
        plane: Int,
        format: MTLPixelFormat,
        width: Int,
        height: Int,
        planar: Bool
    ) throws -> BridgedTexture {
        var mapping: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buffer, nil, format, width, height, plane, &mapping
        )
        guard status == kCVReturnSuccess,
              let mapping,
              let texture = CVMetalTextureGetTexture(mapping) else {
            throw EngineError.textureAllocationFailed(
                "A \(planar ? "plane of a " : "")\(width) by \(height) frame would not bind (\(status))."
            )
        }
        return BridgedTexture(texture: texture, mapping: mapping)
    }

    /// Releases mappings whose buffers have gone. Cheap, and worth doing once a
    /// frame rather than letting the cache grow across a two hour film.
    func flush() {
        CVMetalTextureCacheFlush(cache, 0)
    }
}

/// Loading the shader library, which differs by where the code is running.
enum ShaderLibrary {

    /// The library compiled into the app bundle.
    static func bundled(device: MTLDevice) throws -> MTLLibrary {
        do {
            return try device.makeDefaultLibrary(bundle: Bundle.main)
        } catch {
            throw EngineError.shaderLibraryMissing(error.localizedDescription)
        }
    }

    /// Compiled from source at run time.
    ///
    /// This is how the command line gate gets the same shaders the app uses. A
    /// tool has no bundle to hold a default.metallib, and pointing the gate at
    /// a second copy of the shader source would make it a gate on the copy.
    static func compiling(source url: URL, device: MTLDevice) throws -> MTLLibrary {
        let source: String
        do {
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw EngineError.shaderLibraryMissing(
                "\(url.lastPathComponent) would not open. \(error.localizedDescription)"
            )
        }
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw EngineError.shaderLibraryMissing(
                "\(url.lastPathComponent) would not compile. \(error.localizedDescription)"
            )
        }
    }
}
