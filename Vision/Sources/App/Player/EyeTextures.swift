import Foundation
import Metal
import RealityKit

/// The two textures the headset actually looks at.
///
/// A `LowLevelTexture` is the one thing in RealityKit that lets Metal write
/// straight into a texture the renderer is already showing, with no upload and
/// no copy. `replace(using:)` hands back the MTLTexture to render into for the
/// life of one command buffer, and the entity picks up the result when that
/// buffer completes.
///
/// Main actor throughout, and not as a formality. RealityKit traps if a
/// texture or a material is built off the main actor, and the trap is a crash
/// rather than a warning.
@MainActor
final class EyeTextures {

    let width: Int
    let height: Int

    private let leftTexture: LowLevelTexture
    private let rightTexture: LowLevelTexture

    let left: TextureResource
    let right: TextureResource

    init(width: Int, height: Int) throws {
        self.width = width
        self.height = height

        var descriptor = LowLevelTexture.Descriptor()
        descriptor.textureType = .type2D
        descriptor.pixelFormat = StereoWarpRenderer.eyeFormat
        descriptor.width = width
        descriptor.height = height
        descriptor.mipmapLevelCount = 1
        descriptor.textureUsage = [.shaderRead, .renderTarget]

        leftTexture = try LowLevelTexture(descriptor: descriptor)
        rightTexture = try LowLevelTexture(descriptor: descriptor)
        left = try TextureResource(from: leftTexture)
        right = try TextureResource(from: rightTexture)
    }

    /// The pair of writable textures for one command buffer.
    ///
    /// Both are taken from the same command buffer on purpose. Taking them from
    /// two would let one eye update a frame before the other, which is a
    /// stereo pair torn in time, and the eyes notice that long before anyone
    /// can name what is wrong.
    func writable(using commandBuffer: MTLCommandBuffer) -> (left: MTLTexture, right: MTLTexture) {
        (left: leftTexture.replace(using: commandBuffer),
         right: rightTexture.replace(using: commandBuffer))
    }
}
