import CoreVideo
import Foundation
import Metal
import simd

/// Synthesizes the two eye views from one video frame plus its depth frame.
///
/// Ported from the Mac app's `MakeIt3D/Engine/WarpRenderer.swift`. The mesh
/// warp, the background plate and the guided upsample are the same code doing
/// the same thing. What is different is the shape of the work, and the shape is
/// what makes a live dial possible:
///
///   `renderFrame` runs everything, and runs once per video frame. At 24 fps
///   that is 24 times a second, not 90.
///
///   `rerender` runs only the disparity mapping and the two warps, using the
///   nearness and the plate the last frame already produced. That is what the
///   dial calls, and it is why moving the dial shows up on the next display
///   frame rather than the next video frame.
///
/// The eye textures it writes are then just quads in the headset at 90 Hz. The
/// expensive work and the display rate are deliberately not the same number.
final class StereoWarpRenderer {

    // MARK: Uniform layouts, matching StereoWarp.metal exactly

    private struct WarpUniforms {
        var frameSize: SIMD2<Float>
        var eyeFactor: Float
        var overscan: Float
        var vertexStep: Float
        var stretchLimit: Float
    }

    private struct PlateUniforms {
        var backgroundLevel: Float
        var blend: Float
    }

    private struct UpsampleUniforms {
        var lowSize: SIMD2<UInt32>
        var highSize: SIMD2<UInt32>
        var spatialSigma: Float
        var lumaSigma: Float
        var depthScale: Float
        var depthOffset: Float
    }

    private struct DisparityUniforms {
        var gain: Float
        var convergence: Float
        var forwardPopScale: Float
    }

    // MARK: Stored

    let device: MTLDevice
    let frameWidth: Int
    let frameHeight: Int

    private let warpPipeline: MTLRenderPipelineState
    private let lumaPipeline: MTLComputePipelineState
    private let upsamplePipeline: MTLComputePipelineState
    private let disparityPipeline: MTLComputePipelineState
    private let plateUpdatePipeline: MTLComputePipelineState
    private let plateSeedPipeline: MTLComputePipelineState

    /// The warp mesh, in normalized source coordinates.
    private let gridBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let indexCount: Int
    /// Grid spacing in normalized source coordinates, for the stretch measure.
    private let vertexStep: Float

    private let lumaTexture: MTLTexture
    private let nearnessTexture: MTLTexture
    private let disparityTexture: MTLTexture

    /// Double buffered, because a compute pass cannot read and write the same
    /// texture. Front is the plate as it stands; back is where the update
    /// writes, and then they swap.
    private var plateFront: MTLTexture
    private var plateBack: MTLTexture
    private var plateSeeded = false

    /// The colour frame the last `renderFrame` was given, so `rerender` has
    /// something to warp when only the dial moved.
    private var currentSource: MTLTexture?

    // MARK: Setup

    init(
        device: MTLDevice,
        library: MTLLibrary,
        frameWidth: Int,
        frameHeight: Int,
        meshVertexSpacing: Int
    ) throws {
        self.device = device
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight

        func computePipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw EngineError.functionMissing(name)
            }
            do {
                return try device.makeComputePipelineState(function: function)
            } catch {
                throw EngineError.pipelineFailed("\(name): \(error.localizedDescription)")
            }
        }

        lumaPipeline = try computePipeline("extractLuma")
        upsamplePipeline = try computePipeline("upsampleNearness")
        disparityPipeline = try computePipeline("nearnessToDisparity")
        plateUpdatePipeline = try computePipeline("updateBackgroundPlate")
        plateSeedPipeline = try computePipeline("seedBackgroundPlate")

        guard let vertexFunction = library.makeFunction(name: "warpVertex") else {
            throw EngineError.functionMissing("warpVertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "warpFragment") else {
            throw EngineError.functionMissing("warpFragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = Self.eyeFormat
        do {
            warpPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw EngineError.pipelineFailed(error.localizedDescription)
        }

        // MARK: Mesh

        let spacing = max(1, meshVertexSpacing)
        let columns = max(2, frameWidth / spacing + 1)
        let rows = max(2, frameHeight / spacing + 1)

        var positions = [SIMD2<Float>]()
        positions.reserveCapacity(columns * rows)
        for row in 0..<rows {
            let v = Float(row) / Float(rows - 1)
            for column in 0..<columns {
                let u = Float(column) / Float(columns - 1)
                positions.append(SIMD2<Float>(u, v))
            }
        }

        var indices = [UInt32]()
        indices.reserveCapacity((columns - 1) * (rows - 1) * 6)
        for row in 0..<(rows - 1) {
            for column in 0..<(columns - 1) {
                let topLeft = UInt32(row * columns + column)
                let topRight = topLeft + 1
                let bottomLeft = UInt32((row + 1) * columns + column)
                let bottomRight = bottomLeft + 1
                indices.append(contentsOf: [topLeft, bottomLeft, topRight])
                indices.append(contentsOf: [topRight, bottomLeft, bottomRight])
            }
        }

        guard let gridBuffer = device.makeBuffer(
            bytes: positions,
            length: MemoryLayout<SIMD2<Float>>.stride * positions.count,
            options: .storageModeShared
        ), let indexBuffer = device.makeBuffer(
            bytes: indices,
            length: MemoryLayout<UInt32>.stride * indices.count,
            options: .storageModeShared
        ) else {
            throw EngineError.bufferAllocationFailed
        }
        self.gridBuffer = gridBuffer
        self.indexBuffer = indexBuffer
        self.indexCount = indices.count
        self.vertexStep = 1.0 / Float(max(columns - 1, 1))

        // MARK: Working textures

        func makeTexture(_ format: MTLPixelFormat, usage: MTLTextureUsage) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: frameWidth, height: frameHeight, mipmapped: false
            )
            descriptor.usage = usage
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw EngineError.textureAllocationFailed(
                    "\(frameWidth) by \(frameHeight), format \(format.rawValue)."
                )
            }
            return texture
        }

        lumaTexture = try makeTexture(.r32Float, usage: [.shaderRead, .shaderWrite])
        nearnessTexture = try makeTexture(.r32Float, usage: [.shaderRead, .shaderWrite])
        disparityTexture = try makeTexture(.r32Float, usage: [.shaderRead, .shaderWrite])
        // The plate is linear, not sRGB, because a compute shader writes to it
        // and writing to an sRGB texture from compute is not something every
        // GPU allows. Everything it holds arrives already linearized by the
        // sampler and leaves through the warp's sRGB render target, so the
        // round trip stays correct.
        plateFront = try makeTexture(.bgra8Unorm, usage: [.shaderRead, .shaderWrite])
        plateBack = try makeTexture(.bgra8Unorm, usage: [.shaderRead, .shaderWrite])
    }

    /// What both eye textures must be, and what the warp pipeline is built for.
    ///
    /// sRGB, and it matters. Decoded video arrives gamma encoded, and a
    /// renderer that treats those bytes as linear light hands RealityKit a
    /// picture that is far too bright: mid grey lands somewhere near white and
    /// the whole film looks washed out. Binding the source as sRGB makes the
    /// sampler linearize on read, and an sRGB render target re-encodes on
    /// write, so the numbers that come out are the numbers that went in and
    /// RealityKit knows what they mean.
    ///
    /// Depth deliberately does not get this treatment. Depth levels are data,
    /// not light, and bending them through a transfer curve would bend the
    /// depth mapping with them.
    static let eyeFormat: MTLPixelFormat = .bgra8Unorm_srgb
    /// The format the colour frame is bound as, matching the eye format so the
    /// linearize on read and encode on write cancel exactly.
    static let sourceFormat: MTLPixelFormat = .bgra8Unorm_srgb
    /// The format the depth frame is bound as. Linear, because it is a
    /// measurement rather than a picture.
    static let depthFormat: MTLPixelFormat = .bgra8Unorm

    /// Allocates an eye texture of the right size and format.
    func makeEyeTexture() throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.eyeFormat, width: frameWidth, height: frameHeight, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw EngineError.textureAllocationFailed("An eye view at \(frameWidth) by \(frameHeight).")
        }
        return texture
    }

    // MARK: Rendering

    /// Everything, for one new video frame.
    ///
    /// `startsNewShot` throws away the accumulated background. The plate is a
    /// memory of one shot, and carrying it across a cut paints one scene's
    /// background into another's gaps. The Mac had to guess at cuts from the
    /// depth itself; here the shot boundaries are in the file, so this is exact.
    func renderFrame(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        depth: MTLTexture,
        shot: ShotMetadata,
        startsNewShot: Bool,
        tuning: StereoTuning,
        left: MTLTexture,
        right: MTLTexture
    ) {
        currentSource = source
        if startsNewShot { plateSeeded = false }

        encodeLuma(commandBuffer, source: source)
        encodeUpsample(commandBuffer, depth: depth, shot: shot, tuning: tuning)
        encodeDisparity(commandBuffer, tuning: tuning)

        if tuning.fillDisocclusions {
            encodePlate(commandBuffer, source: source, shot: shot, tuning: tuning)
        }

        encodeEyes(commandBuffer, source: source, tuning: tuning, left: left, right: right)
    }

    /// The dial moved, but the picture did not.
    ///
    /// Returns false when there is no frame to re-render yet, which is the one
    /// honest answer before the first frame has arrived.
    @discardableResult
    func rerender(
        commandBuffer: MTLCommandBuffer,
        tuning: StereoTuning,
        left: MTLTexture,
        right: MTLTexture
    ) -> Bool {
        guard let source = currentSource else { return false }
        encodeDisparity(commandBuffer, tuning: tuning)
        encodeEyes(commandBuffer, source: source, tuning: tuning, left: left, right: right)
        return true
    }

    /// Forgets the accumulated background. Called on a seek, where the next
    /// frame has nothing to do with the last one drawn.
    func resetBackgroundPlate() {
        plateSeeded = false
    }

    // MARK: Passes

    private func encodeLuma(_ commandBuffer: MTLCommandBuffer, source: MTLTexture) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(lumaPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(lumaTexture, index: 1)
        dispatch(encoder, pipeline: lumaPipeline, width: frameWidth, height: frameHeight)
        encoder.endEncoding()
    }

    private func encodeUpsample(
        _ commandBuffer: MTLCommandBuffer,
        depth: MTLTexture,
        shot: ShotMetadata,
        tuning: StereoTuning
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        var uniforms = UpsampleUniforms(
            lowSize: SIMD2<UInt32>(UInt32(depth.width), UInt32(depth.height)),
            highSize: SIMD2<UInt32>(UInt32(frameWidth), UInt32(frameHeight)),
            spatialSigma: Float(tuning.bilateralSpatialSigma),
            lumaSigma: Float(tuning.bilateralLumaSigma),
            depthScale: Float(shot.depthScale),
            depthOffset: Float(shot.depthOffset)
        )
        encoder.setComputePipelineState(upsamplePipeline)
        encoder.setTexture(depth, index: 0)
        encoder.setTexture(lumaTexture, index: 1)
        encoder.setTexture(nearnessTexture, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<UpsampleUniforms>.stride, index: 0)
        dispatch(encoder, pipeline: upsamplePipeline, width: frameWidth, height: frameHeight)
        encoder.endEncoding()
    }

    private func encodeDisparity(_ commandBuffer: MTLCommandBuffer, tuning: StereoTuning) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        var uniforms = DisparityUniforms(
            gain: Float(tuning.strength * Double(frameWidth)),
            convergence: Float(tuning.convergence),
            forwardPopScale: Float(tuning.forwardPopScale)
        )
        encoder.setComputePipelineState(disparityPipeline)
        encoder.setTexture(nearnessTexture, index: 0)
        encoder.setTexture(disparityTexture, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<DisparityUniforms>.stride, index: 0)
        dispatch(encoder, pipeline: disparityPipeline, width: frameWidth, height: frameHeight)
        encoder.endEncoding()
    }

    private func encodePlate(
        _ commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        shot: ShotMetadata,
        tuning: StereoTuning
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        let isSeeding = !plateSeeded

        if isSeeding {
            // First frame of a shot: the plate is simply the frame. Worst case
            // a gap gets filled with the frame's own content at that spot,
            // which is no worse than the smear it replaces.
            encoder.setComputePipelineState(plateSeedPipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(plateFront, index: 1)
            dispatch(encoder, pipeline: plateSeedPipeline, width: frameWidth, height: frameHeight)
            plateSeeded = true
        } else {
            // The background threshold scales with how much depth this shot
            // has, so a flat scene and a deep one both keep a sensible slice.
            let deepest = -tuning.depthPixels(shot: shot, frameWidth: frameWidth)
            var uniforms = PlateUniforms(
                backgroundLevel: Float(deepest * tuning.backgroundLevelFraction),
                blend: Float(tuning.backgroundPlateBlend)
            )
            encoder.setComputePipelineState(plateUpdatePipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(disparityTexture, index: 1)
            encoder.setTexture(plateFront, index: 2)
            encoder.setTexture(plateBack, index: 3)
            encoder.setBytes(&uniforms, length: MemoryLayout<PlateUniforms>.stride, index: 0)
            dispatch(encoder, pipeline: plateUpdatePipeline, width: frameWidth, height: frameHeight)
        }

        encoder.endEncoding()
        if !isSeeding { swap(&plateFront, &plateBack) }
    }

    private func encodeEyes(
        _ commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        tuning: StereoTuning,
        left: MTLTexture,
        right: MTLTexture
    ) {
        encodeEye(commandBuffer, source: source, destination: left, eye: .left, tuning: tuning)
        encodeEye(commandBuffer, source: source, destination: right, eye: .right, tuning: tuning)
    }

    /// Renders one eye.
    ///
    /// Two passes when disocclusion filling is on. The first lays down the
    /// background plate warped to this eye, which fills the frame with the best
    /// guess at what is behind everything. The second draws the real frame on
    /// top and discards anything the mesh stretched past the limit, so the
    /// plate shows through exactly in the gaps and nowhere else.
    ///
    /// A deliberate divergence from the Mac here, and it is worth naming. On
    /// the Mac, `leftEyeUntouched` blits the source into the left eye and skips
    /// the warp entirely, which also skips the overscan the right eye gets. The
    /// two eyes then differ in scale by the overscan factor. On a monitor that
    /// is a curiosity. On a face it is a vertical size mismatch between the
    /// eyes, which is a known way to make someone's eyes ache in ten minutes.
    /// Here the left eye goes through the same warp with an eye factor of zero,
    /// so it carries no disparity, exactly as intended, and lands on precisely
    /// the same framing as the right.
    private func encodeEye(
        _ commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        destination: MTLTexture,
        eye: StereoTuning.Eye,
        tuning: StereoTuning
    ) {
        guard tuning.fillDisocclusions, plateSeeded else {
            encodeWarp(
                commandBuffer, source: source, destination: destination,
                eye: eye, tuning: tuning, clear: true
            )
            return
        }
        // No stretch limit on the plate pass: it is the fallback layer and has
        // to cover the whole frame.
        encodeWarp(
            commandBuffer, source: plateFront, destination: destination,
            eye: eye, tuning: tuning, clear: true, stretchLimit: .greatestFiniteMagnitude
        )
        encodeWarp(
            commandBuffer, source: source, destination: destination,
            eye: eye, tuning: tuning, clear: false, stretchLimit: Float(tuning.stretchLimit)
        )
    }

    private func encodeWarp(
        _ commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        destination: MTLTexture,
        eye: StereoTuning.Eye,
        tuning: StereoTuning,
        clear: Bool,
        stretchLimit: Float = .greatestFiniteMagnitude
    ) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination
        descriptor.colorAttachments[0].loadAction = clear ? .clear : .load
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        var uniforms = WarpUniforms(
            frameSize: SIMD2<Float>(Float(frameWidth), Float(frameHeight)),
            eyeFactor: tuning.synthesis.factor(for: eye)
                * (tuning.invertDisparitySign ? -1 : 1),
            overscan: Float(tuning.overscan),
            vertexStep: vertexStep,
            stretchLimit: stretchLimit
        )

        encoder.setRenderPipelineState(warpPipeline)
        encoder.setVertexBuffer(gridBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<WarpUniforms>.stride, index: 1)
        encoder.setVertexTexture(disparityTexture, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WarpUniforms>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: indexCount,
            indexType: .uint32,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )
        encoder.endEncoding()
    }

    // MARK: Helpers

    private func dispatch(
        _ encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let threadgroupWidth = min(pipeline.threadExecutionWidth, width)
        let threadgroupHeight = min(
            max(pipeline.maxTotalThreadsPerThreadgroup / max(threadgroupWidth, 1), 1),
            height
        )
        let threadsPerThreadgroup = MTLSize(
            width: max(threadgroupWidth, 1), height: max(threadgroupHeight, 1), depth: 1
        )
        let threadgroups = MTLSize(
            width: (width + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
            height: (height + threadsPerThreadgroup.height - 1) / threadsPerThreadgroup.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
    }
}
