import AVFoundation
import CoreVideo
import Foundation

/// What the pipeline reports back while it runs.
enum ConversionEvent: Sendable {
    case started(totalFrames: Int)
    case progress(fraction: Double, framesDone: Int)
    case finished(VerificationReport)
    case failed(String)
    case cancelled
}

/// Everything a conversion needs to run, frozen at the moment Convert is pressed.
struct ConversionRequest: Sendable {
    let probe: SourceProbe
    let tuning: EngineTuning
    let outputURL: URL
}

/// Runs one conversion end to end.
///
/// The whole pipeline lives inside a single task. Frames, textures, and the
/// depth model never cross an isolation boundary, which is what keeps the hot
/// path free of actor hops and keeps Swift 6 concurrency honest without
/// pretending non Sendable media types are Sendable.
enum ConversionController {

    /// Runs the conversion. Cancellation is checked at frame boundaries, so a
    /// cancel always leaves either a finished file or no file at all.
    static func run(
        _ request: ConversionRequest,
        onEvent: @escaping @Sendable (ConversionEvent) -> Void
    ) async {
        do {
            let estimator = try CoreMLDepthEstimator()
            let stabilizer = Stabilizer(tuning: request.tuning)
            let renderer = try WarpRenderer(
                frameWidth: request.probe.width,
                frameHeight: request.probe.height,
                tuning: request.tuning
            )
            let writer = try await SpatialWriter.open(
                outputURL: request.outputURL,
                probe: request.probe,
                tuning: request.tuning
            )
            let source = try await Ingest.FrameSource.open(probe: request.probe)

            try writer.start()
            onEvent(.started(totalFrames: request.probe.estimatedFrameCount))

            // Eye buffers come from a pool rather than being allocated once and
            // reused. The writer retains whatever it is handed and the encoder
            // reads it asynchronously, so a frame is not free to be overwritten
            // just because append returned.
            let pool = try FramePool(
                width: request.probe.width, height: request.probe.height
            )

            var framesDone = 0
            let total = max(request.probe.estimatedFrameCount, 1)

            while let frame = try source.next() {
                if Task.isCancelled {
                    source.cancel()
                    writer.cancel()
                    onEvent(.cancelled)
                    return
                }

                let raw = try estimator.nearness(from: frame.pixelBuffer)
                let stabilized = stabilizer.stabilize(raw)
                let field = Disparity.field(
                    from: stabilized,
                    frameWidth: request.probe.width,
                    tuning: request.tuning
                )

                let leftBuffer = try pool.next()
                let rightBuffer = try pool.next()

                try renderer.synthesize(
                    source: frame.pixelBuffer,
                    disparity: field,
                    into: leftBuffer,
                    and: rightBuffer
                )

                try writer.append(
                    StereoPair(left: leftBuffer, right: rightBuffer, time: frame.time)
                )

                framesDone += 1
                onEvent(.progress(
                    fraction: min(Double(framesDone) / Double(total), 1.0),
                    framesDone: framesDone
                ))
            }

            try await writer.finish()

            let report = await VerificationReport.verify(
                outputURL: request.outputURL,
                sourceProbe: request.probe,
                writtenFrameCount: writer.frameCount
            )
            onEvent(.finished(report))

        } catch is CancellationError {
            onEvent(.cancelled)
        } catch {
            onEvent(.failed(error.localizedDescription))
        }
    }
}
