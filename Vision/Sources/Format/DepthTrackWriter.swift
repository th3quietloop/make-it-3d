import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

enum DepthTrackWriterError: LocalizedError {
    case setupFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .setupFailed(let detail): return "Couldn't start writing the depth track file. \(detail)"
        case .writeFailed(let detail): return "Writing the depth track file stopped. \(detail)"
        }
    }
}

/// Everything the writer needs to know before it opens a file.
struct DepthTrackSpec: Sendable, Equatable {
    var width: Int
    var height: Int
    var frameRate: Int
    var frameCount: Int
    /// A tone on an audio track, so the interleaving of four inputs is
    /// exercised rather than assumed. Off for the format gate, which asserts
    /// exactly three tracks.
    var includeTone: Bool

    var depthWidth: Int { DepthTrack.depthDimension(for: width) }
    var depthHeight: Int { DepthTrack.depthDimension(for: height) }

    var duration: CMTime {
        CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(frameRate))
    }

    func time(ofFrame index: Int) -> CMTime {
        CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate))
    }

    init(
        width: Int = 1920,
        height: Int = 1080,
        frameRate: Int = 30,
        frameCount: Int = 150,
        includeTone: Bool = false
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.frameCount = frameCount
        self.includeTone = includeTone
    }
}

/// Supplies the frames a depth track file is made of.
///
/// Both video tracks are pumped on their own serial queue, so a conformer must
/// be safe to call from two queues at once. The way to be safe is to be pure:
/// derive everything from the frame index and share no mutable state. The
/// synthetic source does exactly that.
protocol DepthTrackFrameSource: Sendable {
    var spec: DepthTrackSpec { get }
    /// The shots, in order, covering the whole duration with no gaps.
    var shots: [Shot] { get }
    /// Full resolution colour, 32BGRA.
    func colorFrame(at index: Int) throws -> CVPixelBuffer
    /// Half resolution depth as luminance, 420 full range with the depth in
    /// the luma plane.
    func depthFrame(at index: Int) throws -> CVPixelBuffer
    /// Mono 16 bit PCM for the tone track, or nil when the spec has no tone.
    func toneChunk() throws -> CMSampleBuffer?
}

/// Writes a conforming depth track `.mov`.
///
/// Four inputs at once is where this gets interesting. AVAssetWriter
/// interleaves tracks and will not let one input run far ahead of another: past
/// a certain lead, `isReadyForMoreMediaData` goes false and stays false until
/// the others catch up. Hand written polling loops deadlock on that. Every
/// track here is pumped by `requestMediaDataWhenReady`, which hands the
/// schedule back to AVFoundation and removes the whole class of stall.
enum DepthTrackWriter {

    /// Writes the file and returns where it landed.
    static func write(to url: URL, source: some DepthTrackFrameSource) async throws -> URL {
        let spec = source.spec
        try? FileManager.default.removeItem(at: url)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw DepthTrackWriterError.setupFailed(error.localizedDescription)
        }

        // MARK: The marker
        //
        // A top level item, so a player can tell a depth track file from a
        // plain one without opening every track.
        let marker = AVMutableMetadataItem()
        marker.identifier = DepthTrack.markerIdentifier
        marker.dataType = kCMMetadataBaseDataType_SInt32 as String
        marker.value = NSNumber(value: DepthTrack.formatVersion)
        writer.metadata = [marker]

        // MARK: Track 1, colour

        let colorInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: spec.width,
                AVVideoHeightKey: spec.height,
                AVVideoColorPropertiesKey: Self.rec709
            ]
        )
        colorInput.expectsMediaDataInRealTime = false
        let colorAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: colorInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: spec.width,
                kCVPixelBufferHeightKey as String: spec.height
            ]
        )

        // MARK: Track 2, depth
        //
        // Written from a full range 420 buffer with the depth sitting in the
        // luma plane and the chroma parked at neutral. Full range is the point:
        // it keeps level 0 at 0 and level 255 at 255 instead of squeezing the
        // map into 16...235 and handing back a rounding error at both ends of
        // the depth range, which is exactly where the near and far clamps live.

        let depthInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: spec.depthWidth,
                AVVideoHeightKey: spec.depthHeight,
                AVVideoColorPropertiesKey: Self.rec709
            ]
        )
        depthInput.expectsMediaDataInRealTime = false
        let depthAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: depthInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey as String: spec.depthWidth,
                kCVPixelBufferHeightKey as String: spec.depthHeight
            ]
        )

        // MARK: Track 3, timed metadata

        let metadataInput = AVAssetWriterInput(
            mediaType: .metadata,
            outputSettings: nil,
            sourceFormatHint: try Self.shotFormatDescription()
        )
        metadataInput.expectsMediaDataInRealTime = false
        let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)

        // MARK: Optional tone

        let audioInput: AVAssetWriterInput? = spec.includeTone
            ? AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: ToneTrack.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 96_000
                ]
            )
            : nil
        audioInput?.expectsMediaDataInRealTime = false

        for input in [colorInput, depthInput, metadataInput, audioInput].compactMap({ $0 }) {
            guard writer.canAdd(input) else {
                throw DepthTrackWriterError.setupFailed(
                    "The writer rejected the \(input.mediaType.rawValue) input."
                )
            }
            writer.add(input)
        }

        guard writer.startWriting() else {
            throw DepthTrackWriterError.setupFailed(
                writer.error?.localizedDescription ?? "The writer would not start."
            )
        }
        writer.startSession(atSourceTime: .zero)

        // MARK: Pumps

        let colorDriver = TrackDriver(input: colorInput, label: "makeit3d.write.color") { index in
            guard index < spec.frameCount else { return false }
            let buffer = try source.colorFrame(at: index)
            guard colorAdaptor.append(buffer, withPresentationTime: spec.time(ofFrame: index)) else {
                throw DepthTrackWriterError.writeFailed("A colour frame was rejected.")
            }
            return true
        }

        let depthDriver = TrackDriver(input: depthInput, label: "makeit3d.write.depth") { index in
            guard index < spec.frameCount else { return false }
            let buffer = try source.depthFrame(at: index)
            guard depthAdaptor.append(buffer, withPresentationTime: spec.time(ofFrame: index)) else {
                throw DepthTrackWriterError.writeFailed("A depth frame was rejected.")
            }
            return true
        }

        let shots = source.shots
        let metadataDriver = TrackDriver(input: metadataInput, label: "makeit3d.write.shots") { index in
            guard index < shots.count else { return false }
            let group = try Self.timedGroup(for: shots[index])
            guard metadataAdaptor.append(group) else {
                throw DepthTrackWriterError.writeFailed("Shot \(index)'s metadata was rejected.")
            }
            return true
        }

        let audioDriver = audioInput.map { input in
            TrackDriver(input: input, label: "makeit3d.write.tone") { _ in
                guard let chunk = try source.toneChunk() else { return false }
                guard input.append(chunk) else {
                    throw DepthTrackWriterError.writeFailed("A tone sample was rejected.")
                }
                return true
            }
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await colorDriver.run() }
            group.addTask { try await depthDriver.run() }
            group.addTask { try await metadataDriver.run() }
            if let audioDriver {
                group.addTask { try await audioDriver.run() }
            }
            try await group.waitForAll()
        }

        await writer.finishWriting()
        if writer.status == .failed {
            try? FileManager.default.removeItem(at: url)
            throw DepthTrackWriterError.writeFailed(
                writer.error?.localizedDescription ?? "Writing failed."
            )
        }
        return url
    }

    // MARK: Pieces

    /// Computed rather than stored, because a dictionary of Any is not Sendable
    /// and a global one is a data race waiting for a second writer.
    private static var rec709: [String: Any] {
        [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
    }

    /// Describes the one kind of sample the metadata track carries: UTF-8 JSON
    /// under the shot identifier.
    static func shotFormatDescription() throws -> CMMetadataFormatDescription {
        let specification: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                DepthTrack.shotIdentifier.rawValue,
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                kCMMetadataBaseDataType_UTF8 as String
        ]
        var description: CMMetadataFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw DepthTrackWriterError.setupFailed(
                "Couldn't describe the shot metadata track (\(status))."
            )
        }
        return description
    }

    private static func timedGroup(for shot: Shot) throws -> AVTimedMetadataGroup {
        let json = try shot.metadata.jsonData()
        guard let text = String(data: json, encoding: .utf8) else {
            throw DepthTrackWriterError.writeFailed("Shot \(shot.metadata.shot) would not encode.")
        }
        let item = AVMutableMetadataItem()
        item.identifier = DepthTrack.shotIdentifier
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = text as NSString
        return AVTimedMetadataGroup(items: [item], timeRange: shot.timeRange)
    }

    /// Feeds one writer input until its supplier says there is nothing left.
    /// `supply` returns false when the track is done.
    ///
    /// Unchecked Sendable is load bearing rather than a way to quiet a warning:
    /// every stored property is touched only from `queue`, which is serial, and
    /// `requestMediaDataWhenReady` delivers its callbacks there. The writer
    /// input and the supply closure are non Sendable precisely because they
    /// must not be used from two places at once, and this class is the thing
    /// guaranteeing they are not.
    private final class TrackDriver: @unchecked Sendable {
        private let input: AVAssetWriterInput
        private let supply: (Int) throws -> Bool
        private let queue: DispatchQueue
        private var index = 0
        private var finished = false
        private var continuation: CheckedContinuation<Void, Error>?

        init(input: AVAssetWriterInput, label: String, supply: @escaping (Int) throws -> Bool) {
            self.input = input
            self.supply = supply
            self.queue = DispatchQueue(label: label)
        }

        func run() async throws {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                self.continuation = continuation
                input.requestMediaDataWhenReady(on: queue) { [weak self] in
                    self?.pump()
                }
            }
        }

        private func pump() {
            while input.isReadyForMoreMediaData {
                do {
                    if try supply(index) {
                        index += 1
                    } else {
                        complete(nil)
                        return
                    }
                } catch {
                    complete(error)
                    return
                }
            }
        }

        /// Resumes exactly once, however many times the callback fires.
        private func complete(_ error: Error?) {
            guard !finished else { return }
            finished = true
            input.markAsFinished()
            if let error {
                continuation?.resume(throwing: error)
            } else {
                continuation?.resume()
            }
            continuation = nil
        }
    }
}
