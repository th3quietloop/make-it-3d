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
    /// Per shot settings, when Auto has run. nil means one setting for the
    /// whole file, which is what this app did before and is still what happens
    /// if you never press Auto.
    var shotPlan: ShotPlan?

    /// The tuning in force at a given moment.
    ///
    /// Without a plan this is the same value for every frame. With one, the
    /// strength and balance change at each cut, which is the entire point: a
    /// face two feet from the lens and a valley two miles away do not want the
    /// same depth, and a film cuts between them every few seconds.
    func tuning(at time: CMTime) -> EngineTuning {
        guard let shot = shotPlan?.shot(at: time) else { return tuning }
        return AutoTune.apply(shot.settings, to: tuning)
    }
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
            let stage = try await Stage(request: request)
            onEvent(.started(totalFrames: request.probe.estimatedFrameCount))

            // The video model is used when it is present and asked for, and the
            // per frame model otherwise. Falling back rather than failing means
            // an app built without the video model still converts.
            let useVideoModel = request.tuning.depthModel == .video
                && VideoDepthEstimator.isAvailable

            let cancelled: Bool
            if useVideoModel {
                cancelled = try await runWindowed(stage, request: request, onEvent: onEvent)
            } else {
                cancelled = try await runPerFrame(stage, request: request, onEvent: onEvent)
            }

            if cancelled {
                onEvent(.cancelled)
                return
            }

            try await stage.writer.finish()

            let report = await VerificationReport.verify(
                outputURL: request.outputURL,
                sourceProbe: request.probe,
                writtenFrameCount: stage.writer.frameCount
            )
            onEvent(.finished(report))

        } catch is CancellationError {
            onEvent(.cancelled)
        } catch {
            onEvent(.failed(error.localizedDescription))
        }
    }

    /// The parts every run needs, built once.
    private final class Stage {
        let renderer: WarpRenderer
        let writer: SpatialWriter
        let source: Ingest.FrameSource
        let pool: FramePool
        let request: ConversionRequest

        init(request: ConversionRequest) async throws {
            self.request = request
            renderer = try WarpRenderer(
                frameWidth: request.probe.width,
                frameHeight: request.probe.height,
                tuning: request.tuning
            )
            writer = try await SpatialWriter.open(
                outputURL: request.outputURL,
                probe: request.probe,
                tuning: request.tuning
            )
            source = try await Ingest.FrameSource.open(probe: request.probe)
            // Eye buffers come from a pool rather than being allocated once and
            // reused. The writer retains whatever it is handed and the encoder
            // reads it asynchronously, so a frame is not free to be overwritten
            // just because append returned.
            pool = try FramePool(
                width: request.probe.width, height: request.probe.height
            )
            try writer.start()
        }

        /// Turns one frame plus its depth into a written stereo pair.
        func emit(frame: Ingest.Frame, nearness: NearnessMap) throws {
            // The settings are read per frame rather than once at the top,
            // because with a shot plan they change at every cut. Without a plan
            // this returns the same value every time and costs a dictionary
            // free comparison.
            let field = Disparity.field(
                from: nearness,
                frameWidth: request.probe.width,
                tuning: request.tuning(at: frame.time)
            )
            let left = try pool.next()
            let right = try pool.next()
            try renderer.synthesize(
                source: frame.pixelBuffer, disparity: field, into: left, and: right
            )
            try writer.append(StereoPair(left: left, right: right, time: frame.time))
        }

        func abandon() {
            source.cancel()
            writer.cancel()
        }
    }

    // MARK: One frame at a time

    /// Returns true if the run was cancelled.
    private static func runPerFrame(
        _ stage: Stage,
        request: ConversionRequest,
        onEvent: @escaping @Sendable (ConversionEvent) -> Void
    ) async throws -> Bool {
        let estimator = try CoreMLDepthEstimator()
        let stabilizer = Stabilizer(tuning: request.tuning)

        var framesDone = 0
        let total = max(request.probe.estimatedFrameCount, 1)

        while let frame = try stage.source.next() {
            if Task.isCancelled {
                stage.abandon()
                return true
            }

            let raw = try estimator.nearness(from: frame.pixelBuffer)
            let stabilized = stabilizer.stabilize(raw)

            // The background plate is a memory of the current shot. Across a
            // cut that memory is worse than nothing, so it goes.
            if stabilizer.lastFrameWasSceneCut {
                stage.renderer.resetBackgroundPlate()
            }

            try stage.emit(frame: frame, nearness: stabilized)

            framesDone += 1
            onEvent(.progress(
                fraction: min(Double(framesDone) / Double(total), 1.0),
                framesDone: framesDone
            ))
        }
        return false
    }

    // MARK: A window at a time

    /// Returns true if the run was cancelled.
    ///
    /// The video model reads a run of frames, so the loop gathers a window,
    /// runs once, and writes out the leading part of it. The tail of each
    /// window is look ahead context: it gets recomputed in the next window with
    /// more to go on, so its first pass is thrown away.
    ///
    /// Each window picks its own scale for relative depth, which would show up
    /// as a jump every time the window advanced. The overlapping frames are the
    /// fix: fitting the new window onto the previous window's values for the
    /// same frames lines the two up before anything is written.
    private static func runWindowed(
        _ stage: Stage,
        request: ConversionRequest,
        onEvent: @escaping @Sendable (ConversionEvent) -> Void
    ) async throws -> Bool {
        let estimator = try VideoDepthEstimator()
        let stabilizer = Stabilizer(tuning: request.tuning)

        let windowLength = estimator.windowLength
        let stride = estimator.stride

        var window: [Ingest.Frame] = []
        var carriedMaps: [NearnessMap] = []
        var framesDone = 0
        let total = max(request.probe.estimatedFrameCount, 1)
        var reachedEnd = false

        func process(isFinal: Bool) throws -> Bool {
            guard !window.isEmpty else { return false }

            var maps = try estimator.nearness(forWindow: window.map(\.pixelBuffer))

            // Line this window up with the previous one over the frames they
            // share, so relative depth does not step at the seam.
            if !carriedMaps.isEmpty {
                let count = min(carriedMaps.count, maps.count)
                var incoming: [Float] = []
                var reference: [Float] = []
                for index in 0..<count {
                    incoming.append(contentsOf: maps[index].values)
                    reference.append(contentsOf: carriedMaps[index].values)
                }
                let fit = WindowAlignment.fit(incoming: incoming, reference: reference)
                maps = maps.map { WindowAlignment.apply($0, scale: fit.scale, shift: fit.shift) }
            }

            // How many of this window's frames are results rather than context.
            let emitCount = isFinal
                ? min(window.count, maps.count)
                : min(stride, maps.count)

            for index in 0..<emitCount {
                if Task.isCancelled { return true }

                // Normalization only, no temporal averaging: the model already
                // handled time, and smoothing on top would only add lag.
                let normalized = stabilizer.normalize(maps[index])
                if index == 0 && framesDone == 0 {
                    stage.renderer.resetBackgroundPlate()
                }
                try stage.emit(frame: window[index], nearness: normalized)

                framesDone += 1
                onEvent(.progress(
                    fraction: min(Double(framesDone) / Double(total), 1.0),
                    framesDone: framesDone
                ))
            }

            if isFinal {
                window.removeAll()
                carriedMaps.removeAll()
                return false
            }

            // Keep the overlap frames as the head of the next window, along
            // with the depth this window gave them, which is what the next
            // window gets aligned against.
            window.removeFirst(emitCount)
            carriedMaps = Array(maps[emitCount...])
            return false
        }

        while true {
            if Task.isCancelled {
                stage.abandon()
                return true
            }

            if let frame = try stage.source.next() {
                window.append(frame)
            } else {
                reachedEnd = true
            }

            if reachedEnd {
                if try process(isFinal: true) {
                    stage.abandon()
                    return true
                }
                break
            }

            if window.count == windowLength {
                if try process(isFinal: false) {
                    stage.abandon()
                    return true
                }
            }
        }
        return false
    }
}
