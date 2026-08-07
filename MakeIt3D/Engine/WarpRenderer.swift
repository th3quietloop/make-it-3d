import Metal
import MetalKit
import CoreVideo
import CoreGraphics
import simd
import Foundation

enum WarpError: LocalizedError {
    case noDevice
    case shaderLibraryMissing
    case pipelineFailed(String)
    case textureAllocationFailed
    case bufferAllocationFailed

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "No Metal device is available on this Mac."
        case .shaderLibraryMissing:
            return "Make It 3D's shaders are missing from the app bundle."
        case .pipelineFailed(let detail):
            return "A render pipeline wouldn't build. \(detail)"
        case .textureAllocationFailed:
            return "Couldn't allocate a texture for the warp."
        case .bufferAllocationFailed:
            return "Couldn't allocate the warp mesh."
        }
    }
}

/// Synthesizes the left and right eye views from one frame plus its disparity
/// field, on the GPU.
///
/// One instance is owned by one pipeline (a conversion, or the preview) and is
/// never shared across tasks.
final class WarpRenderer {

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
    }

    private struct RampUniforms {
        var nearColour: SIMD3<Float>
        var farColour: SIMD3<Float>
        var minDisparity: Float
        var maxDisparity: Float
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let warpPipeline: MTLRenderPipelineState
    private let upsamplePipeline: MTLComputePipelineState
    private let lumaPipeline: MTLComputePipelineState
    private let rampPipeline: MTLComputePipelineState
    private let anaglyphPipeline: MTLComputePipelineState
    private let plateUpdatePipeline: MTLComputePipelineState
    private let plateSeedPipeline: MTLComputePipelineState

    private let tuning: EngineTuning
    private let frameWidth: Int
    private let frameHeight: Int

    /// The warp mesh, in normalized source coordinates.
    private let gridBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let indexCount: Int
    /// Grid spacing in normalized source coordinates, for the stretch measure.
    private let vertexStep: Float

    private let textureCache: CVMetalTextureCache

    // Reused across frames so a long conversion does not thrash the allocator.
    private var lowDisparityTexture: MTLTexture
    private var highDisparityTexture: MTLTexture
    private var lumaTexture: MTLTexture

    /// Double buffered, because a compute pass cannot read and write the same
    /// texture. Front is the plate as it stands; back is where the update
    /// writes, and then they swap.
    private var plateFront: MTLTexture
    private var plateBack: MTLTexture
    private var plateSeeded = false

    init(frameWidth: Int, frameHeight: Int, tuning: EngineTuning) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw WarpError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw WarpError.noDevice }

        self.device = device
        self.queue = queue
        self.tuning = tuning
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight

        guard let library = try? device.makeDefaultLibrary(bundle: Bundle.main) else {
            throw WarpError.shaderLibraryMissing
        }

        func computePipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw WarpError.pipelineFailed("\(name) is missing.")
            }
            do {
                return try device.makeComputePipelineState(function: function)
            } catch {
                throw WarpError.pipelineFailed(error.localizedDescription)
            }
        }

        upsamplePipeline = try computePipeline("jointBilateralUpsample")
        lumaPipeline = try computePipeline("extractLuma")
        rampPipeline = try computePipeline("depthRamp")
        anaglyphPipeline = try computePipeline("anaglyph")
        plateUpdatePipeline = try computePipeline("updateBackgroundPlate")
        plateSeedPipeline = try computePipeline("seedBackgroundPlate")

        guard let vertexFunction = library.makeFunction(name: "warpVertex"),
              let fragmentFunction = library.makeFunction(name: "warpFragment") else {
            throw WarpError.pipelineFailed("The warp shaders are missing.")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            warpPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw WarpError.pipelineFailed(error.localizedDescription)
        }

        // MARK: Mesh

        let spacing = max(1, tuning.meshVertexSpacing)
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
            throw WarpError.bufferAllocationFailed
        }
        self.gridBuffer = gridBuffer
        self.indexBuffer = indexBuffer
        self.indexCount = indices.count
        self.vertexStep = 1.0 / Float(max(columns - 1, 1))

        // MARK: Textures

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let cache else { throw WarpError.textureAllocationFailed }
        textureCache = cache

        func makeTexture(width: Int, height: Int, format: MTLPixelFormat, usage: MTLTextureUsage) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false
            )
            descriptor.usage = usage
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw WarpError.textureAllocationFailed
            }
            return texture
        }

        // Sized on first use against the real disparity map; start at frame
        // size so the allocation exists and gets replaced only if the model
        // resolution differs.
        lowDisparityTexture = try makeTexture(
            width: 1, height: 1, format: .r32Float, usage: [.shaderRead, .shaderWrite]
        )
        highDisparityTexture = try makeTexture(
            width: frameWidth, height: frameHeight, format: .r32Float,
            usage: [.shaderRead, .shaderWrite]
        )
        lumaTexture = try makeTexture(
            width: frameWidth, height: frameHeight, format: .r32Float,
            usage: [.shaderRead, .shaderWrite]
        )
        plateFront = try makeTexture(
            width: frameWidth, height: frameHeight, format: .bgra8Unorm,
            usage: [.shaderRead, .shaderWrite, .renderTarget]
        )
        plateBack = try makeTexture(
            width: frameWidth, height: frameHeight, format: .bgra8Unorm,
            usage: [.shaderRead, .shaderWrite, .renderTarget]
        )
    }

    // MARK: Synthesis

    /// Renders both eye views for one frame.
    ///
    /// `destinationLeft` and `destinationRight` are caller owned pixel buffers,
    /// normally vended by the writer's pool so the result can be appended
    /// without another copy.
    func synthesize(
        source: CVPixelBuffer,
        disparity: Disparity.Field,
        into destinationLeft: CVPixelBuffer,
        and destinationRight: CVPixelBuffer
    ) throws {
        let sourceTexture = try texture(from: source, format: .bgra8Unorm)
        let leftTexture = try texture(from: destinationLeft, format: .bgra8Unorm)
        let rightTexture = try texture(from: destinationRight, format: .bgra8Unorm)

        try prepareDisparity(disparity, sourceTexture: sourceTexture)

        if tuning.fillDisocclusions {
            try updateBackgroundPlate(source: sourceTexture, disparity: disparity)
        }

        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw WarpError.pipelineFailed("No command buffer.")
        }

        if tuning.synthesis == .leftEyeUntouched {
            // A blit, not a warp. The left eye is the source frame, so copying
            // it is both exactly correct and half the GPU work of rendering it.
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: sourceTexture, to: leftTexture)
                blit.endEncoding()
            }
        } else {
            encodeEye(commandBuffer, source: sourceTexture, destination: leftTexture, eye: .left)
        }

        encodeEye(commandBuffer, source: sourceTexture, destination: rightTexture, eye: .right)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw WarpError.pipelineFailed(error.localizedDescription)
        }
    }

    /// Uploads the disparity field and runs the guided upsample to frame size.
    private func prepareDisparity(_ field: Disparity.Field, sourceTexture: MTLTexture) throws {
        if lowDisparityTexture.width != field.width || lowDisparityTexture.height != field.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r32Float, width: field.width, height: field.height, mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            // Shared, not managed: this texture is written by the CPU every
            // frame and read by the GPU immediately after, and unified memory
            // means there is no second copy to keep in sync.
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw WarpError.textureAllocationFailed
            }
            lowDisparityTexture = texture
        }

        field.values.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            lowDisparityTexture.replace(
                region: MTLRegionMake2D(0, 0, field.width, field.height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: field.width * MemoryLayout<Float>.size
            )
        }

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw WarpError.pipelineFailed("No compute encoder.")
        }

        // Luma guide.
        encoder.setComputePipelineState(lumaPipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(lumaTexture, index: 1)
        dispatch(encoder, pipeline: lumaPipeline, width: frameWidth, height: frameHeight)

        // Guided upsample to frame resolution.
        var uniforms = UpsampleUniforms(
            lowSize: SIMD2<UInt32>(UInt32(field.width), UInt32(field.height)),
            highSize: SIMD2<UInt32>(UInt32(frameWidth), UInt32(frameHeight)),
            spatialSigma: Float(tuning.bilateralSpatialSigma),
            lumaSigma: Float(tuning.bilateralLumaSigma)
        )
        encoder.setComputePipelineState(upsamplePipeline)
        encoder.setTexture(lowDisparityTexture, index: 0)
        encoder.setTexture(lumaTexture, index: 1)
        encoder.setTexture(highDisparityTexture, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<UpsampleUniforms>.stride, index: 0)
        dispatch(encoder, pipeline: upsamplePipeline, width: frameWidth, height: frameHeight)

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw WarpError.pipelineFailed(error.localizedDescription)
        }
    }

    /// Throws away the accumulated background.
    ///
    /// Called on a scene cut. The plate is a memory of this shot, and carrying
    /// it across a cut would paint one scene's background into another's gaps.
    func resetBackgroundPlate() {
        plateSeeded = false
    }

    /// Folds this frame's background into the plate.
    private func updateBackgroundPlate(source: MTLTexture, disparity: Disparity.Field) throws {
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw WarpError.pipelineFailed("No compute encoder for the background plate.")
        }

        // Seeding writes straight into the front buffer, so only an update has
        // a back buffer to swap in afterwards.
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
            // Background threshold scales with how much depth this shot has, so
            // a flat scene and a deep one both keep a sensible slice.
            var uniforms = PlateUniforms(
                backgroundLevel: disparity.maxNegative * Float(tuning.backgroundLevelFraction),
                blend: Float(tuning.backgroundPlateBlend)
            )
            encoder.setComputePipelineState(plateUpdatePipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(highDisparityTexture, index: 1)
            encoder.setTexture(plateFront, index: 2)
            encoder.setTexture(plateBack, index: 3)
            encoder.setBytes(&uniforms, length: MemoryLayout<PlateUniforms>.stride, index: 0)
            dispatch(encoder, pipeline: plateUpdatePipeline, width: frameWidth, height: frameHeight)
        }

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw WarpError.pipelineFailed(error.localizedDescription)
        }
        if !isSeeding { swap(&plateFront, &plateBack) }
    }

    /// Renders one eye.
    ///
    /// Two passes when disocclusion filling is on. The first lays down the
    /// background plate warped to this eye, which fills the frame with the best
    /// guess at what is behind everything. The second draws the real frame on
    /// top and discards anything the mesh stretched past the limit, so the
    /// plate shows through exactly in the gaps and nowhere else.
    private func encodeEye(
        _ commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        destination: MTLTexture,
        eye: Disparity.Eye
    ) {
        guard tuning.fillDisocclusions, plateSeeded else {
            encodeWarp(commandBuffer, source: source, destination: destination, eye: eye, clear: true)
            return
        }
        // No stretch limit on the plate pass: it is the fallback layer and has
        // to cover the whole frame.
        encodeWarp(
            commandBuffer, source: plateFront, destination: destination,
            eye: eye, clear: true, stretchLimit: .greatestFiniteMagnitude
        )
        encodeWarp(
            commandBuffer, source: source, destination: destination,
            eye: eye, clear: false, stretchLimit: Float(tuning.stretchLimit)
        )
    }

    private func encodeWarp(
        _ commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        destination: MTLTexture,
        eye: Disparity.Eye,
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
            eyeFactor: eye.sampleFactor(for: tuning.synthesis)
                * (tuning.invertDisparitySign ? -1 : 1),
            overscan: Float(tuning.overscan),
            vertexStep: vertexStep,
            stretchLimit: stretchLimit
        )

        encoder.setRenderPipelineState(warpPipeline)
        encoder.setVertexBuffer(gridBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<WarpUniforms>.stride, index: 1)
        encoder.setVertexTexture(highDisparityTexture, index: 0)
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

    // MARK: Preview renderings

    /// The depth map as the silver ramp, for the Depth preview mode.
    func renderDepthRamp(disparity: Disparity.Field, source: CVPixelBuffer, into destination: CVPixelBuffer) throws {
        let sourceTexture = try texture(from: source, format: .bgra8Unorm)
        let destinationTexture = try texture(from: destination, format: .bgra8Unorm)
        try prepareDisparity(disparity, sourceTexture: sourceTexture)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw WarpError.pipelineFailed("No compute encoder.")
        }

        let near = Tokens.DepthRamp.near
        let far = Tokens.DepthRamp.far
        // The ramp spans the disparity actually present in this frame, so the
        // map always uses its full range rather than washing out on a shallow
        // scene.
        var uniforms = RampUniforms(
            nearColour: SIMD3<Float>(Float(near.r), Float(near.g), Float(near.b)),
            farColour: SIMD3<Float>(Float(far.r), Float(far.g), Float(far.b)),
            minDisparity: disparity.maxNegative,
            maxDisparity: disparity.maxPositive
        )

        encoder.setComputePipelineState(rampPipeline)
        encoder.setTexture(highDisparityTexture, index: 0)
        encoder.setTexture(destinationTexture, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<RampUniforms>.stride, index: 0)
        dispatch(encoder, pipeline: rampPipeline, width: frameWidth, height: frameHeight)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// Half colour anaglyph, for the Stereo preview mode.
    func composeAnaglyph(
        left: CVPixelBuffer,
        right: CVPixelBuffer,
        into destination: CVPixelBuffer
    ) throws {
        let leftTexture = try texture(from: left, format: .bgra8Unorm)
        let rightTexture = try texture(from: right, format: .bgra8Unorm)
        let destinationTexture = try texture(from: destination, format: .bgra8Unorm)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw WarpError.pipelineFailed("No compute encoder.")
        }
        encoder.setComputePipelineState(anaglyphPipeline)
        encoder.setTexture(leftTexture, index: 0)
        encoder.setTexture(rightTexture, index: 1)
        encoder.setTexture(destinationTexture, index: 2)
        dispatch(encoder, pipeline: anaglyphPipeline, width: frameWidth, height: frameHeight)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
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

    private func texture(from buffer: CVPixelBuffer, format: MTLPixelFormat) throws -> MTLTexture {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            buffer,
            nil,
            format,
            CVPixelBufferGetWidth(buffer),
            CVPixelBufferGetHeight(buffer),
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw WarpError.textureAllocationFailed
        }
        return texture
    }

    /// Allocates a frame sized BGRA buffer backed by an IOSurface so Metal can
    /// render straight into it.
    static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, Ingest.pixelFormat,
            attributes as CFDictionary, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw WarpError.textureAllocationFailed
        }
        return buffer
    }
}

/// Recycles frame buffers for the conversion pipeline.
///
/// The pipeline cannot simply reuse one pair of buffers for every frame. The
/// tagged buffer group handed to the writer retains its pixel buffers and the
/// encoder reads them asynchronously, so writing the next frame into the same
/// memory both corrupts the frame in flight and wedges the writer: it keeps
/// holding buffers, the input stays above its high water level, and
/// isReadyForMoreMediaData never comes back true.
///
/// A CVPixelBufferPool is the right shape for this. It hands out a fresh buffer
/// each frame and takes it back automatically once the encoder drops its last
/// reference, so buffers are recycled without ever being reused early.
final class FramePool {
    private let pool: CVPixelBufferPool

    init(width: Int, height: Int) throws {
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: Ingest.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault, nil, attributes as CFDictionary, &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw WarpError.textureAllocationFailed
        }
        self.pool = pool
    }

    func next() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw WarpError.textureAllocationFailed
        }
        return buffer
    }
}
