import AVFoundation
import CoreMedia
import CoreVideo
import CoreGraphics
import Foundation

/// Generates the parity test clip: a box translating over a gradient, with a
/// tone on the audio track.
///
/// It exists so three things can be checked without a human watching: that the
/// export has the same frame count as the source, that audio survives the trip,
/// and that the stereo sign convention is right.
enum SyntheticClip {

    struct Spec: Sendable {
        var width = 1280
        var height = 720
        var frameRate = 30
        var durationSeconds = 4
        var sampleRate = 44100.0
        var toneHz = 440.0

        var frameCount: Int { frameRate * durationSeconds }
    }

    enum GenerationError: LocalizedError {
        case setupFailed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .setupFailed(let detail): return "Couldn't set up the test clip. \(detail)"
            case .writeFailed(let detail): return "Couldn't write the test clip. \(detail)"
            }
        }
    }

    /// Writes the clip and returns where it landed.
    static func generate(at url: URL, spec: Spec = Spec()) async throws -> URL {
        try? FileManager.default.removeItem(at: url)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw GenerationError.setupFailed(error.localizedDescription)
        }

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: spec.width,
                AVVideoHeightKey: spec.height
            ]
        )
        videoInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Ingest.pixelFormat,
                kCVPixelBufferWidthKey as String: spec.width,
                kCVPixelBufferHeightKey as String: spec.height
            ]
        )

        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: spec.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96000
            ]
        )
        audioInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw GenerationError.setupFailed("The test clip inputs were rejected.")
        }
        writer.add(videoInput)
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw GenerationError.setupFailed(
                writer.error?.localizedDescription ?? "The writer would not start."
            )
        }
        writer.startSession(atSourceTime: .zero)

        // MARK: Video and audio
        //
        // Both tracks are driven by requestMediaDataWhenReady rather than by a
        // hand written polling loop, and that is not a style preference.
        // AVAssetWriter interleaves tracks, so it will not let one input run
        // far ahead of another: past a certain lead, isReadyForMoreMediaData
        // goes false and stays false until the other track catches up. Trying
        // to stay ahead manually does not work either, because the AAC encoder
        // only emits packets on its own granule boundaries, so the encoded
        // audio timeline lags whatever has been appended. Handing the pull
        // schedule back to AVFoundation removes the whole class of stall.

        let tone = try ToneGenerator(spec: spec)

        let videoDriver = TrackDriver(
            input: videoInput,
            label: "relief.synthetic.video"
        ) { index in
            guard index < spec.frameCount else { return false }
            let buffer = try frame(at: index, spec: spec)
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(spec.frameRate))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw GenerationError.writeFailed("A frame was rejected.")
            }
            return true
        }

        let audioDriver = TrackDriver(
            input: audioInput,
            label: "relief.synthetic.audio"
        ) { _ in
            guard let sample = try tone.nextChunk() else { return false }
            guard audioInput.append(sample) else {
                throw GenerationError.writeFailed("A tone sample was rejected.")
            }
            return true
        }

        async let videoWritten: Void = videoDriver.run()
        async let audioWritten: Void = audioDriver.run()
        _ = try await (videoWritten, audioWritten)

        await writer.finishWriting()
        if writer.status == .failed {
            throw GenerationError.writeFailed(
                writer.error?.localizedDescription ?? "Writing failed."
            )
        }
        return url
    }

    /// Feeds one writer input until its supplier says there is nothing left,
    /// then marks it finished. `supply` returns false when the track is done.
    ///
    /// Unchecked Sendable is doing real work here rather than papering over a
    /// warning: every stored property is touched only from `queue`, which is
    /// serial, and `requestMediaDataWhenReady` delivers its callbacks there.
    /// The writer input and the supply closure are non Sendable precisely
    /// because they must not be used from two places at once, and this class is
    /// the thing guaranteeing they are not.
    private final class TrackDriver: @unchecked Sendable {
        private let input: AVAssetWriterInput
        private let supply: (Int) throws -> Bool
        private let queue: DispatchQueue
        private var index = 0
        private var finished = false
        private var continuation: CheckedContinuation<Void, Error>?

        init(
            input: AVAssetWriterInput,
            label: String,
            supply: @escaping (Int) throws -> Bool
        ) {
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

    // MARK: Frame drawing

    /// A vertical gradient background with a light box sliding left to right.
    /// The box is the near object: the sign convention check looks for it.
    static func frame(at index: Int, spec: Spec) throws -> CVPixelBuffer {
        let buffer = try WarpRenderer.makePixelBuffer(width: spec.width, height: spec.height)

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw GenerationError.writeFailed("Couldn't address the frame.")
        }

        let colourSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: base,
            width: spec.width,
            height: spec.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colourSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw GenerationError.writeFailed("Couldn't make a drawing context.")
        }

        // Background: a smooth vertical gradient, so the depth model has
        // something continuous to read behind the box.
        let gradientColours = [
            CGColor(red: 0.10, green: 0.11, blue: 0.14, alpha: 1),
            CGColor(red: 0.42, green: 0.45, blue: 0.52, alpha: 1)
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: colourSpace, colors: gradientColours, locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 0, y: spec.height),
                options: []
            )
        }

        // The near box, translating across the frame.
        let progress = Double(index) / Double(max(spec.frameCount - 1, 1))
        let boxSize = CGFloat(spec.height) * 0.32
        let travel = CGFloat(spec.width) - boxSize * 2
        let x = boxSize * 0.5 + travel * CGFloat(progress)
        let y = (CGFloat(spec.height) - boxSize) * 0.5

        context.setFillColor(CGColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: x, y: y, width: boxSize, height: boxSize))

        // A darker inner square gives the box internal structure, so a depth
        // model has more than a flat patch to work with.
        context.setFillColor(CGColor(red: 0.55, green: 0.57, blue: 0.62, alpha: 1))
        context.fill(CGRect(
            x: x + boxSize * 0.3, y: y + boxSize * 0.3,
            width: boxSize * 0.4, height: boxSize * 0.4
        ))

        return buffer
    }

    /// Where the near box sits in a given frame, in pixels. The sign convention
    /// check uses this to know what it is looking for.
    static func boxCentreX(at index: Int, spec: Spec) -> Double {
        let progress = Double(index) / Double(max(spec.frameCount - 1, 1))
        let boxSize = Double(spec.height) * 0.32
        let travel = Double(spec.width) - boxSize * 2
        return boxSize * 0.5 + travel * progress + boxSize * 0.5
    }

    // MARK: Audio

    /// Emits the test tone in chunks, on demand, so it can be interleaved with
    /// the video track as the clip is written.
    private final class ToneGenerator {
        private let spec: Spec
        private let formatDescription: CMAudioFormatDescription
        private let chunkSize = 4096
        private var written = 0

        private var totalSamples: Int { Int(spec.sampleRate * Double(spec.durationSeconds)) }

        init(spec: Spec) throws {
            self.spec = spec

            var asbd = AudioStreamBasicDescription(
                mSampleRate: spec.sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 2,
                mFramesPerPacket: 1,
                mBytesPerFrame: 2,
                mChannelsPerFrame: 1,
                mBitsPerChannel: 16,
                mReserved: 0
            )

            var description: CMAudioFormatDescription?
            let status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &description
            )
            guard status == noErr, let description else {
                throw GenerationError.setupFailed("Couldn't describe the tone format.")
            }
            formatDescription = description
        }

        /// The next chunk of tone, or nil once the whole track has been handed
        /// out. Called from the audio input's serial queue.
        func nextChunk() throws -> CMSampleBuffer? {
            guard written < totalSamples else { return nil }
            let count = min(chunkSize, totalSamples - written)

            var samples = [Int16](repeating: 0, count: count)
            for i in 0..<count {
                let t = Double(written + i) / spec.sampleRate
                // Loud enough to be obviously present, quiet enough that
                // nobody jumps when the test clip plays.
                let value = sin(2 * .pi * spec.toneHz * t) * 0.2
                samples[i] = Int16(value * Double(Int16.max))
            }

            let byteCount = count * MemoryLayout<Int16>.size
            var blockBuffer: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: 0,
                blockBufferOut: &blockBuffer
            ) == noErr, let blockBuffer else {
                throw GenerationError.writeFailed("Couldn't allocate the tone buffer.")
            }

            let copied = samples.withUnsafeBytes { bytes -> OSStatus in
                guard let base = bytes.baseAddress else { return -1 }
                return CMBlockBufferReplaceDataBytes(
                    with: base, blockBuffer: blockBuffer,
                    offsetIntoDestination: 0, dataLength: byteCount
                )
            }
            guard copied == noErr else {
                throw GenerationError.writeFailed("Couldn't fill the tone buffer.")
            }

            var sampleBuffer: CMSampleBuffer?
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(spec.sampleRate)),
                presentationTimeStamp: CMTime(
                    value: CMTimeValue(written), timescale: CMTimeScale(spec.sampleRate)
                ),
                decodeTimeStamp: .invalid
            )
            guard CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDescription,
                sampleCount: count,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: [MemoryLayout<Int16>.size],
                sampleBufferOut: &sampleBuffer
            ) == noErr, let sampleBuffer else {
                throw GenerationError.writeFailed("Couldn't build the tone sample.")
            }

            written += count
            return sampleBuffer
        }
    }
}
