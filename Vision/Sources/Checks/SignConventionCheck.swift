import CoreVideo
import Foundation
import Metal

/// Verifies that near content pops toward the viewer rather than sinking behind
/// the screen, by measuring rendered pixels.
///
/// Carried across from the Mac app's `MakeIt3D/TestKit/SignConventionCheck.swift`,
/// for the reason that made it necessary there: the Mac had the stereo sign
/// inverted for a while and the rendered output still looked right. A picture
/// with the eyes swapped is still a picture. The only thing that catches it is
/// a number.
///
/// The geometry being asserted: for an object nearer than the screen plane, the
/// ray from the left eye through the object meets the screen to the RIGHT of
/// centre, and the ray from the right eye meets it to the LEFT. That is crossed
/// disparity, so the left eye's copy sits further right than the right eye's.
/// Content behind the screen plane is the reverse.
///
/// The depth is deliberately uniform across the frame. A near box on a far
/// background reads like a better test and is not measurable: at a hard depth
/// discontinuity the warp mesh overlaps on one edge of the box and gaps on the
/// other, so the box changes shape and its centroid stops being a clean record
/// of how far it moved. A uniform field shifts the whole frame rigidly, so the
/// measured shift is exactly the disparity and nothing else. Running it twice,
/// once near and once far, still proves ordering as well as sign.
enum SignConventionCheck {

    private static let width = 640
    private static let height = 360
    /// Sub pixel noise must not read as a result in either direction.
    private static let threshold = 0.5

    static func run(library: MTLLibrary, device: MTLDevice, tuning: StereoTuning = .default) throws -> [CheckResult] {
        // Nearness 0.9 sits well in front of the 0.45 convergence point, 0.1
        // well behind it.
        let near = try measureSeparation(nearness: 0.9, library: library, device: device, tuning: tuning)
        let far = try measureSeparation(nearness: 0.1, library: library, device: device, tuning: tuning)

        let nearPops = near.separation > threshold
        let farRecedes = far.separation < -threshold
        let passed = nearPops && farRecedes

        let diagnosis: String
        if passed {
            diagnosis = "near content pops toward the viewer and far content sits behind the screen"
        } else if near.separation < -threshold && far.separation > threshold {
            diagnosis = "ordering is inverted: flip invertDisparitySign in StereoTuning"
        } else if abs(near.separation) <= threshold && abs(far.separation) <= threshold {
            diagnosis = "no measurable separation, so the warp is not displacing anything"
        } else {
            diagnosis = "near and far are not separating in opposite directions"
        }

        return [
            CheckResult(
                name: "Near content pops forward",
                passed: nearPops,
                detail: String(
                    format: "separation %+.2f px, want above %+.1f. left centroid %.2f, right %.2f",
                    near.separation, threshold, near.left, near.right
                )
            ),
            CheckResult(
                name: "Far content sits behind",
                passed: farRecedes,
                detail: String(
                    format: "separation %+.2f px, want below %+.1f. left centroid %.2f, right %.2f",
                    far.separation, -threshold, far.left, far.right
                )
            ),
            CheckResult(
                name: "Stereo sign convention",
                passed: passed,
                detail: diagnosis
            )
        ]
    }

    private struct Measurement {
        let separation: Double
        let left: Double
        let right: Double
    }

    /// Renders both eyes at one uniform nearness and returns the left centroid
    /// minus the right centroid, in pixels.
    private static func measureSeparation(
        nearness: Double,
        library: MTLLibrary,
        device: MTLDevice,
        tuning: StereoTuning
    ) throws -> Measurement {
        guard let queue = device.makeCommandQueue() else { throw EngineError.noDevice }
        let bridge = try TextureBridge(device: device)

        // A narrow bright bar on a dark field. Narrow so its centroid is a
        // sharp number, and away from the frame edges so the overscan crop
        // never clips it.
        let sourceBuffer = try PixelBuffers.makeColor(width: width, height: height)
        try paintBar(sourceBuffer)

        // Depth at half resolution, per the format, uniformly at the nearness
        // being tested. The shot maps stored 0...255 straight onto 0...1
        // nearness, so the level is the nearness.
        let depthWidth = DepthTrack.depthDimension(for: width)
        let depthHeight = DepthTrack.depthDimension(for: height)
        let depthBuffer = try PixelBuffers.makeDepth(width: depthWidth, height: depthHeight)
        try fillDepth(depthBuffer, level: UInt8((nearness * 255).rounded()))

        let shot = ShotMetadata(
            shot: 0,
            depthScale: 1.0,
            depthOffset: 0.0,
            suggestedStrength: tuning.strength,
            suggestedConvergence: tuning.convergence,
            comfortLoad: 0
        )

        let leftBuffer = try PixelBuffers.makeColor(width: width, height: height)
        let rightBuffer = try PixelBuffers.makeColor(width: width, height: height)

        // Bound in exactly the formats the player binds, so the check measures
        // the pipeline the film goes through rather than a linear stand in.
        let source = try bridge.texture(from: sourceBuffer, format: StereoWarpRenderer.sourceFormat)
        let depth = try bridge.lumaTexture(from: depthBuffer)
        let left = try bridge.texture(from: leftBuffer, format: StereoWarpRenderer.eyeFormat)
        let right = try bridge.texture(from: rightBuffer, format: StereoWarpRenderer.eyeFormat)

        let renderer = try StereoWarpRenderer(
            device: device,
            library: library,
            frameWidth: width,
            frameHeight: height,
            meshVertexSpacing: tuning.meshVertexSpacing
        )

        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw EngineError.pipelineFailed("No command buffer for the sign check.")
        }
        renderer.renderFrame(
            commandBuffer: commandBuffer,
            source: source.texture,
            depth: depth.texture,
            shot: shot,
            startsNewShot: true,
            tuning: tuning,
            left: left.texture,
            right: right.texture
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw EngineError.pipelineFailed(error.localizedDescription)
        }

        let leftCentroid = brightCentroidX(leftBuffer)
        let rightCentroid = brightCentroidX(rightBuffer)
        return Measurement(
            separation: leftCentroid - rightCentroid,
            left: leftCentroid,
            right: rightCentroid
        )
    }

    // MARK: Painting and measuring

    private static func paintBar(_ buffer: CVPixelBuffer) throws {
        try PixelBuffers.withLock(buffer) {
            guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                throw PixelBufferError.notAddressable
            }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let barStart = width / 2 - 20
            let barEnd = barStart + 40

            for y in 0..<height {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let value: UInt8 = (x >= barStart && x < barEnd) ? 240 : 40
                    let pixel = row.advanced(by: x * 4)
                    pixel[0] = value
                    pixel[1] = value
                    pixel[2] = value
                    pixel[3] = 255
                }
            }
        }
    }

    private static func fillDepth(_ buffer: CVPixelBuffer, level: UInt8) throws {
        try PixelBuffers.withLock(buffer) {
            guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                  let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
                throw PixelBufferError.notAddressable
            }
            let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)

            for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, 0) {
                let row = luma.advanced(by: y * lumaStride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<CVPixelBufferGetWidthOfPlane(buffer, 0) { row[x] = level }
            }
            for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
                let row = chroma.advanced(by: y * chromaStride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<(CVPixelBufferGetWidthOfPlane(buffer, 1) * 2) { row[x] = 128 }
            }
        }
    }

    /// Intensity weighted centroid of the bright pixels, which is where the bar
    /// ended up after the warp.
    private static func brightCentroidX(_ buffer: CVPixelBuffer) -> Double {
        PixelBuffers.withLock(buffer, readOnly: true) {
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

            var weightedSum = 0.0
            var weightTotal = 0.0

            // The middle band only, away from the top and bottom edges where
            // the overscan crop is doing its own thing.
            for y in (height / 3)..<(height * 2 / 3) {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let value = Double(row[x * 4 + 1])
                    // Only the bar is bright; the background sits near 40.
                    guard value > 140 else { continue }
                    weightedSum += Double(x) * value
                    weightTotal += value
                }
            }

            return weightTotal > 0 ? weightedSum / weightTotal : 0
        }
    }
}
