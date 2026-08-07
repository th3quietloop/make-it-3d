import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Hands the colour frame onward and puts the depth frame that belongs to it
/// somewhere the renderer can find it.
///
/// The problem this solves: an AVPlayerItem composites its video tracks down to
/// one output, and a depth track file has two. Decoding them with two readers
/// and syncing by hand is how drift gets in, and drift is the one thing Phase 1
/// is not allowed to have.
///
/// A custom compositor removes the question. AVFoundation hands both source
/// frames to `startRequest` for the same composition time, because it is the
/// thing that decided what that time means. The colour frame is passed straight
/// through with no copy, and the depth frame is published under the composition
/// time it arrived with. Pairing is then a lookup by a key AVFoundation issued,
/// not a guess.
final class PairedFrameCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {

    enum CompositorError: LocalizedError {
        case wrongInstruction
        case missingColourFrame(CMPersistentTrackID)

        var errorDescription: String? {
            switch self {
            case .wrongInstruction:
                return "The video composition was built without a paired frame instruction."
            case .missingColourFrame(let id):
                return "The composition asked for track \(id) and got nothing back."
            }
        }
    }

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        // BGRA for both tracks.
        //
        // The depth track is grey with neutral chroma, and grey survives a
        // YCbCr to RGB conversion exactly: the three luma coefficients sum to
        // one, so a pixel with equal components comes back with the same value
        // in every channel. That means the shader can read the red channel of
        // the depth texture and get the stored level, with no second format to
        // handle and no colour matrix to get wrong. DepthLevelCheck measures
        // this rather than trusting it.
        [
            kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        // Nothing to rebuild: this compositor never allocates an output buffer,
        // because its output is one of its inputs.
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? PairedFrameInstruction else {
            request.finish(with: CompositorError.wrongInstruction)
            return
        }

        guard let color = request.sourceFrame(byTrackID: instruction.colorTrackID) else {
            request.finish(with: CompositorError.missingColourFrame(instruction.colorTrackID))
            return
        }

        if let depth = request.sourceFrame(byTrackID: instruction.depthTrackID) {
            instruction.sink.publish(depth, at: request.compositionTime)
        } else {
            instruction.sink.recordMissingDepth()
        }

        // The colour frame is handed back untouched. Track 1 is the original
        // source copied through, and the whole point of the format is that it
        // stays exactly as filmed all the way to the eye.
        request.finish(withComposedVideoFrame: color)
    }

    func cancelAllPendingVideoCompositionRequests() {
        // Requests are answered synchronously, so there is never a pending one.
    }
}

/// Carries the two track IDs and the sink into the compositor.
///
/// AVFoundation builds the compositor itself with a bare `init()`, so there is
/// no way to hand it anything at construction. A custom instruction is the
/// supported channel: it arrives on every request. It also lets
/// `requiredSourceTrackIDs` be stated outright rather than inferred from layer
/// instructions, which is what guarantees the depth track gets decoded at all.
final class PairedFrameInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {

    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let colorTrackID: CMPersistentTrackID
    let depthTrackID: CMPersistentTrackID
    let sink: DepthFrameSink

    init(
        timeRange: CMTimeRange,
        colorTrackID: CMPersistentTrackID,
        depthTrackID: CMPersistentTrackID,
        sink: DepthFrameSink
    ) {
        self.timeRange = timeRange
        self.colorTrackID = colorTrackID
        self.depthTrackID = depthTrackID
        self.sink = sink
        self.requiredSourceTrackIDs = [
            NSNumber(value: colorTrackID),
            NSNumber(value: depthTrackID)
        ]
        super.init()
    }
}

/// Depth frames waiting for the colour frames they belong to.
///
/// A small ring rather than a queue, because the compositor runs ahead of the
/// display by a few frames and a seek can make it run backwards. Eight entries
/// covers the lead comfortably and costs nothing.
///
/// The lookup insists on an exact time match first and counts every time it has
/// to settle for a near one. That counter is the point: a sink that quietly
/// returned the nearest depth frame would make a one frame drift invisible,
/// which is the failure this whole design exists to prevent.
final class DepthFrameSink: @unchecked Sendable {

    struct Match {
        let buffer: CVPixelBuffer
        let time: CMTime
        let exact: Bool
    }

    struct Statistics: Sendable, Equatable {
        var published = 0
        var exactMatches = 0
        var nearMatches = 0
        var misses = 0
        var missingDepthFrames = 0
    }

    private let lock = NSLock()
    private var times = [CMTime]()
    private var buffers = [CVPixelBuffer]()
    private var statistics = Statistics()
    private let capacity = 8

    /// How far off an exact hit a match may be and still count as this frame's
    /// depth. Half a frame at 24 fps, which no correctly paired frame ever
    /// needs and no drift of a whole frame can hide inside.
    private let tolerance = CMTime(value: 1, timescale: 48)

    func publish(_ buffer: CVPixelBuffer, at time: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        times.append(time)
        buffers.append(buffer)
        if times.count > capacity {
            times.removeFirst()
            buffers.removeFirst()
        }
        statistics.published += 1
    }

    func recordMissingDepth() {
        lock.lock()
        defer { lock.unlock() }
        statistics.missingDepthFrames += 1
    }

    func depth(at time: CMTime) -> Match? {
        lock.lock()
        defer { lock.unlock() }

        for (index, stored) in times.enumerated() where stored == time {
            statistics.exactMatches += 1
            return Match(buffer: buffers[index], time: stored, exact: true)
        }

        var bestIndex: Int?
        var bestDistance = tolerance
        for (index, stored) in times.enumerated() {
            let distance = CMTimeAbsoluteValue(CMTimeSubtract(stored, time))
            if distance <= bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        guard let bestIndex else {
            statistics.misses += 1
            return nil
        }
        statistics.nearMatches += 1
        return Match(buffer: buffers[bestIndex], time: times[bestIndex], exact: false)
    }

    var currentStatistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return statistics
    }

    /// Called on a seek, where everything held is about a moment that is no
    /// longer the moment.
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        times.removeAll(keepingCapacity: true)
        buffers.removeAll(keepingCapacity: true)
    }

    func resetStatistics() {
        lock.lock()
        defer { lock.unlock() }
        statistics = Statistics()
    }
}

/// Builds the video composition that pairs the two tracks.
enum PairedComposition {

    enum CompositionError: LocalizedError {
        case noDepthTrack

        var errorDescription: String? {
            switch self {
            case .noDepthTrack:
                return "This file has no depth track, so there is nothing to pair the picture with."
            }
        }
    }

    /// Returns the composition and the sink the renderer reads depth from.
    static func make(for file: DepthTrackFile) throws -> (AVVideoComposition, DepthFrameSink) {
        guard let depth = file.depth else { throw CompositionError.noDepthTrack }

        let sink = DepthFrameSink()
        let instruction = PairedFrameInstruction(
            timeRange: CMTimeRange(start: .zero, duration: file.duration),
            colorTrackID: file.colorTrackID,
            depthTrackID: depth.trackID,
            sink: sink
        )

        let configuration = AVVideoComposition.Configuration(
            customVideoCompositorClass: PairedFrameCompositor.self,
            frameDuration: CMTime(value: 1, timescale: CMTimeScale(file.frameRate.rounded())),
            instructions: [instruction],
            renderSize: CGSize(width: file.width, height: file.height)
        )
        return (AVVideoComposition(configuration: configuration), sink)
    }
}
