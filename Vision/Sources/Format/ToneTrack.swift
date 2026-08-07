import AVFoundation
import CoreMedia
import Foundation

/// A test tone, handed out in chunks.
///
/// It exists so the four track interleave is exercised rather than assumed. A
/// depth track file made by the Mac app carries the source audio, and a writer
/// that has only ever been run without an audio input is a writer that has not
/// been tested against the one thing that stalls it.
///
/// Not Sendable and deliberately so: it holds a write position and is pumped
/// from exactly one serial queue, the audio track's.
final class ToneTrack {

    static let sampleRate = 44_100.0
    static let toneHz = 440.0

    private let durationSeconds: Double
    private let formatDescription: CMAudioFormatDescription
    private let chunkSize = 4096
    private var written = 0

    private var totalSamples: Int { Int(Self.sampleRate * durationSeconds) }

    init(durationSeconds: Double) throws {
        self.durationSeconds = durationSeconds

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
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
            throw DepthTrackWriterError.setupFailed("Couldn't describe the tone format (\(status)).")
        }
        formatDescription = description
    }

    /// The next chunk, or nil once the whole track has been handed out.
    func nextChunk() throws -> CMSampleBuffer? {
        guard written < totalSamples else { return nil }
        let count = min(chunkSize, totalSamples - written)

        var samples = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            let t = Double(written + index) / Self.sampleRate
            // Loud enough to be obviously present, quiet enough that nobody
            // jumps when the fixture plays in a headset.
            let value = sin(2 * .pi * Self.toneHz * t) * 0.2
            samples[index] = Int16(value * Double(Int16.max))
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
            throw DepthTrackWriterError.writeFailed("Couldn't allocate the tone buffer.")
        }

        let copied = samples.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard copied == noErr else {
            throw DepthTrackWriterError.writeFailed("Couldn't fill the tone buffer.")
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(Self.sampleRate)),
            presentationTimeStamp: CMTime(
                value: CMTimeValue(written), timescale: CMTimeScale(Self.sampleRate)
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
            throw DepthTrackWriterError.writeFailed("Couldn't build the tone sample.")
        }

        written += count
        return sampleBuffer
    }
}
