import CoreVideo
import Foundation
import Metal

/// Asks the only question the other checks cannot: are these actually two
/// different pictures?
///
/// Everything else in this folder verifies the machinery. Pairing counters say
/// the right depth frame was found. The frame index strips say the right two
/// frames were put together. The screen material status says a per eye material
/// loaded. Every one of those can read perfectly while the viewer is looking at
/// a flat picture, because a mono image is a completely valid picture and
/// nothing about it looks wrong.
///
/// That is the failure shape this project keeps producing. The stereo sign was
/// inverted and the render looked right. A colour frame was paired with a
/// neighbour's depth and the counters read 360 exact. Both times the check that
/// should have caught it was measuring the pipeline's own bookkeeping instead
/// of the pixels that came out.
///
/// So this measures pixels, on the frame that is actually playing, through the
/// real renderer, at three strengths:
///
///   At zero strength the two eyes must be identical. Disparity is zero
///   everywhere, so both eye factors multiply to nothing and both views get the
///   same overscan. Anything else means something is displacing the picture
///   that is not the dial.
///
///   At the shot's own strength they must differ, and the best fitting
///   horizontal shift between them must be a real number of pixels.
///
///   At double strength the separation must grow. A picture that differs by a
///   fixed amount whatever the dial says is not responding to the dial.
enum EyeSeparationCheck {

    struct Reading {
        /// Mean absolute difference between the eyes with no shift applied,
        /// in levels out of 255.
        let meanDifference: Double
        /// The horizontal shift, in pixels, that best lines the right eye up
        /// with the left. Positive means the right eye's content sits to the
        /// left of the left eye's, which is what near content does.
        let bestShift: Int
        /// How much better the best shift fits than no shift at all. Near zero
        /// means the shift is not really there and the number above is noise.
        let fitImprovement: Double
    }

    /// Runs against whatever frame the renderer last drew.
    ///
    /// `predictedForwardPop` and `predictedDepthBehind` come from the shot
    /// metadata and the tuning, and only set how far the shift search has to
    /// look. They are not asserted against, because a best fitting global shift
    /// lands somewhere inside a frame's whole disparity range rather than on
    /// either end of it, and pretending otherwise would be a check that fails
    /// on honest content.
    static func run(
        renderer: StereoWarpRenderer,
        queue: MTLCommandQueue,
        bridge: TextureBridge,
        tuning: StereoTuning,
        predictedForwardPop: Double,
        predictedDepthBehind: Double
    ) throws -> [CheckResult] {

        let searchRange = min(64, Int(max(predictedForwardPop, predictedDepthBehind).rounded()) + 8)

        var flat = tuning
        flat.strength = 0
        var doubled = tuning
        doubled.strength = min(tuning.strength * 2, StereoTuning.strengthRange.upperBound)

        guard let atZero = try measure(
            renderer: renderer, queue: queue, bridge: bridge,
            tuning: flat, searchRange: searchRange
        ) else {
            throw CheckAborted(
                check: "Eye separation",
                reason: "there is no frame drawn yet to measure."
            )
        }
        guard let atShot = try measure(
            renderer: renderer, queue: queue, bridge: bridge,
            tuning: tuning, searchRange: searchRange
        ), let atDouble = try measure(
            renderer: renderer, queue: queue, bridge: bridge,
            tuning: doubled, searchRange: searchRange
        ) else {
            throw CheckAborted(check: "Eye separation", reason: "a render did not complete.")
        }

        // A tenth of a level, which is below what an eight bit picture can even
        // represent. Anything above it is a real difference rather than
        // rounding in the resample.
        let identicalLimit = 0.1
        // Half a level of mean difference across the whole frame is far more
        // than a rounding error and far less than any visible stereo, so it
        // separates "the dial does nothing" from "the dial does something"
        // without asserting how much.
        let differsFloor = 0.5

        return [
            CheckResult(
                name: "At zero strength the eyes are identical",
                passed: atZero.meanDifference <= identicalLimit && atZero.bestShift == 0,
                detail: String(
                    format: "mean difference %.4f levels (limit %.1f), best shift %d px (want 0)",
                    atZero.meanDifference, identicalLimit, atZero.bestShift
                )
            ),
            CheckResult(
                name: "At the film's own strength the eyes differ",
                passed: atShot.meanDifference > differsFloor && atShot.bestShift != 0,
                detail: String(
                    format: "mean difference %.3f levels (floor %.1f), best shift %d px, fit improved %.1f%%",
                    atShot.meanDifference, differsFloor, atShot.bestShift,
                    atShot.fitImprovement * 100
                )
            ),
            CheckResult(
                name: "More strength separates the eyes further",
                passed: atDouble.meanDifference > atShot.meanDifference,
                detail: String(
                    format: "%.3f levels at %.3f%% strength against %.3f at %.3f%%",
                    atDouble.meanDifference, doubled.strength * 100,
                    atShot.meanDifference, tuning.strength * 100
                )
            )
        ]
    }

    // MARK: Rendering a readable pair

    /// Renders the current frame's eye pair into buffers the CPU can read.
    ///
    /// This goes through `rerender`, which is the same call the depth dial
    /// makes, using the source frame and the nearness the last drawn frame
    /// produced. It writes into its own buffers, so the picture on screen is
    /// untouched.
    private static func measure(
        renderer: StereoWarpRenderer,
        queue: MTLCommandQueue,
        bridge: TextureBridge,
        tuning: StereoTuning,
        searchRange: Int
    ) throws -> Reading? {
        let width = renderer.frameWidth
        let height = renderer.frameHeight

        let leftBuffer = try PixelBuffers.makeColor(width: width, height: height)
        let rightBuffer = try PixelBuffers.makeColor(width: width, height: height)
        let left = try bridge.texture(from: leftBuffer, format: StereoWarpRenderer.eyeFormat)
        let right = try bridge.texture(from: rightBuffer, format: StereoWarpRenderer.eyeFormat)

        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw EngineError.pipelineFailed("No command buffer for the eye separation check.")
        }
        let rendered = renderer.rerender(
            commandBuffer: commandBuffer,
            tuning: tuning,
            left: left.texture,
            right: right.texture
        )
        guard rendered else { return nil }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw EngineError.pipelineFailed(error.localizedDescription)
        }

        return compare(
            left: leftBuffer, right: rightBuffer,
            width: width, height: height, searchRange: searchRange
        )
    }

    /// Mean absolute difference, and the horizontal shift that fits best.
    ///
    /// The shift is found by sliding the right eye against the left and taking
    /// the offset with the lowest sum of absolute differences. It is a blunt
    /// instrument on purpose: a frame has a whole range of disparities in it,
    /// so the best global shift is a summary rather than a measurement of any
    /// one object. What it is good for is telling a real displacement from
    /// none at all, which is the question being asked.
    private static func compare(
        left: CVPixelBuffer,
        right: CVPixelBuffer,
        width: Int,
        height: Int,
        searchRange: Int
    ) -> Reading {
        PixelBuffers.withLock(left, readOnly: true) {
            PixelBuffers.withLock(right, readOnly: true) {
                guard let leftBase = CVPixelBufferGetBaseAddress(left),
                      let rightBase = CVPixelBufferGetBaseAddress(right) else {
                    return Reading(meanDifference: 0, bestShift: 0, fitImprovement: 0)
                }
                let leftStride = CVPixelBufferGetBytesPerRow(left)
                let rightStride = CVPixelBufferGetBytesPerRow(right)

                // The middle band only. The overscan crop does its own thing at
                // the top and bottom edges, and every other row is plenty for a
                // measurement this blunt.
                let firstRow = height / 3
                let lastRow = height * 2 / 3
                // Inset horizontally so a shift never runs off the picture and
                // starts comparing against the clear colour.
                let firstColumn = searchRange + 1
                let lastColumn = width - searchRange - 1
                guard lastColumn > firstColumn else {
                    return Reading(meanDifference: 0, bestShift: 0, fitImprovement: 0)
                }

                var bestShift = 0
                var bestScore = Double.greatestFiniteMagnitude
                var scoreAtZero = 0.0

                for shift in -searchRange...searchRange {
                    var total = 0.0
                    var counted = 0
                    for y in stride(from: firstRow, to: lastRow, by: 2) {
                        let leftRow = leftBase.advanced(by: y * leftStride)
                            .assumingMemoryBound(to: UInt8.self)
                        let rightRow = rightBase.advanced(by: y * rightStride)
                            .assumingMemoryBound(to: UInt8.self)
                        for x in stride(from: firstColumn, to: lastColumn, by: 2) {
                            // Green, which carries most of the luma and needs no
                            // matrix to be a fair stand in for brightness.
                            let a = Int(leftRow[x * 4 + 1])
                            let b = Int(rightRow[(x + shift) * 4 + 1])
                            total += Double(abs(a - b))
                            counted += 1
                        }
                    }
                    let score = counted > 0 ? total / Double(counted) : .greatestFiniteMagnitude
                    if shift == 0 { scoreAtZero = score }
                    if score < bestScore {
                        bestScore = score
                        bestShift = shift
                    }
                }

                let improvement = scoreAtZero > 0 ? (scoreAtZero - bestScore) / scoreAtZero : 0
                return Reading(
                    meanDifference: scoreAtZero,
                    bestShift: bestShift,
                    fitImprovement: improvement
                )
            }
        }
    }
}
