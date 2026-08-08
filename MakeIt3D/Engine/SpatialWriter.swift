import AVFoundation
import CoreMedia
import VideoToolbox
import Foundation

enum SpatialWriterError: LocalizedError {
    case unsupportedEncoder
    case setupFailed(String)
    case writeFailed(String)
    case diskFull
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedEncoder:
            return "This Mac can't encode MV-HEVC, so Make It 3D can't write a spatial video here."
        case .setupFailed(let detail):
            return "Couldn't start writing. \(detail)"
        case .writeFailed(let detail):
            return "Writing stopped. \(detail)"
        case .diskFull:
            return "The disk filled up. Make It 3D removed the partial file. Free some space and try again."
        case .cancelled:
            return "Cancelled."
        }
    }
}

/// The writer contract. The native MV-HEVC path implements it; keeping it a
/// protocol is what lets a side by side plus external mux path drop in without
/// the pipeline above it changing at all.
protocol SpatialVideoWriting: AnyObject {
    func start() throws
    func append(_ pair: StereoPair) throws
    func finish() async throws
    func cancel()
    var outputURL: URL { get }
}

/// Writes MV-HEVC spatial video: two tagged layers in one HEVC track, carrying
/// the spatial metadata visionOS reads, with the source audio passed through
/// untouched.
final class SpatialWriter: SpatialVideoWriting {

    let outputURL: URL

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let videoAdaptor: AVAssetWriterInputTaggedPixelBufferGroupAdaptor
    private let audioInput: AVAssetWriterInput?
    private let audioSource: AudioPassthrough?

    private let width: Int
    private let height: Int
    private var started = false
    private var appendedFrames = 0

    /// An audio sample pulled from the source but not yet accepted by the
    /// writer, either because it belongs to a later moment than the video has
    /// reached or because the audio input was momentarily full.
    private var pendingAudio: CMSampleBuffer?
    private var audioDrained = false

    /// How far ahead of the video the audio track is kept. AVAssetWriter will
    /// not let one input run far ahead of another, so audio has to be fed as
    /// the video advances rather than appended in a block at the end. Half a
    /// second of lead keeps the video input from ever being the one waiting.
    private static let audioLead = CMTime(value: 1, timescale: 2)

    /// Roughly 60 seconds at the 2ms poll interval.
    private static let stallLimitSpins = 30_000

    /// Frames written so far. The verification report compares this against the
    /// source frame count.
    var frameCount: Int { appendedFrames }

    /// Opens a writer, loading the source audio track first so it can be passed
    /// through.
    static func open(
        outputURL: URL,
        probe: SourceProbe,
        tuning: EngineTuning
    ) async throws -> SpatialWriter {
        let audio = probe.hasAudio ? try? await AudioPassthrough.open(url: probe.url) : nil
        return try SpatialWriter(
            outputURL: outputURL, probe: probe, tuning: tuning, audio: audio ?? nil
        )
    }

    private init(
        outputURL: URL,
        probe: SourceProbe,
        tuning: EngineTuning,
        audio: AudioPassthrough?
    ) throws {
        guard VTIsStereoMVHEVCEncodeSupported() else {
            throw SpatialWriterError.unsupportedEncoder
        }

        self.outputURL = outputURL
        self.width = probe.width
        self.height = probe.height

        // A stale file at the destination would otherwise fail the writer.
        try? FileManager.default.removeItem(at: outputURL)

        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw SpatialWriterError.setupFailed(error.localizedDescription)
        }

        // MARK: Video input
        //
        // Units matter here and they are not all the same:
        //   baseline is micrometres, FOV is millidegrees, and the disparity
        //   adjustment is an int32 where 10000 means 1.0.

        let baselineMicrometres = UInt32((tuning.baselineMillimetres * 1000).rounded())
        let fovMillidegrees = UInt32((tuning.horizontalFOVDegrees * 1000).rounded())
        let disparityAdjustment = Int32((tuning.horizontalDisparityAdjustment * 10000).rounded())

        var compression: [String: Any] = [
            // Two layers, tagged 0 and 1, mapped to view IDs 0 and 1.
            kVTCompressionPropertyKey_MVHEVCVideoLayerIDs as String: [0, 1],
            kVTCompressionPropertyKey_MVHEVCViewIDs as String: [0, 1],
            // View 0 is the left eye, view 1 is the right.
            kVTCompressionPropertyKey_MVHEVCLeftAndRightViewIDs as String: [0, 1],
            kVTCompressionPropertyKey_HasLeftStereoEyeView as String: true,
            kVTCompressionPropertyKey_HasRightStereoEyeView as String: true,
            kVTCompressionPropertyKey_HeroEye as String: kCMFormatDescriptionHeroEye_Left as String,
            kVTCompressionPropertyKey_StereoCameraBaseline as String: baselineMicrometres,
            kVTCompressionPropertyKey_HorizontalDisparityAdjustment as String: disparityAdjustment,
            kVTCompressionPropertyKey_HorizontalFieldOfView as String: fovMillidegrees,
            AVVideoAverageBitRateKey: Self.bitrate(for: probe)
        ]

        // Rectilinear projection: a converted flat video is a flat rectangle,
        // not a dome.
        compression[kVTCompressionPropertyKey_ProjectionKind as String] =
            kCMFormatDescriptionProjectionKind_Rectilinear as String

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: probe.width,
            AVVideoHeightKey: probe.height,
            AVVideoCompressionPropertiesKey: compression,
            // The warp renders into 8 bit BGRA, so the output is SDR Rec. 709
            // regardless of what the source claimed.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(videoInput) else {
            throw SpatialWriterError.setupFailed("The MV-HEVC video input was rejected.")
        }
        writer.add(videoInput)

        videoAdaptor = AVAssetWriterInputTaggedPixelBufferGroupAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Ingest.pixelFormat,
                kCVPixelBufferWidthKey as String: probe.width,
                kCVPixelBufferHeightKey as String: probe.height
            ]
        )

        // MARK: Audio passthrough

        if let audio {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: audio.formatDescription
            )
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
                audioSource = audio
            } else {
                audioInput = nil
                audioSource = nil
            }
        } else {
            audioInput = nil
            audioSource = nil
        }
    }

    /// Bits per pixel per second, scaled by resolution and frame rate. MV-HEVC
    /// predicts the second view from the first, so two eyes cost far less than
    /// twice one eye.
    private static func bitrate(for probe: SourceProbe) -> Int {
        let pixels = Double(probe.width * probe.height)
        let bitsPerPixel = 0.15
        return Int(pixels * probe.nominalFrameRate * bitsPerPixel)
    }

    func start() throws {
        guard writer.startWriting() else {
            throw SpatialWriterError.setupFailed(
                writer.error?.localizedDescription ?? "The writer would not start."
            )
        }
        writer.startSession(atSourceTime: .zero)
        started = true
    }

    func append(_ pair: StereoPair) throws {
        guard started else { throw SpatialWriterError.writeFailed("The writer was not started.") }

        // Keep the audio track running slightly ahead of the video, otherwise
        // the video input stops accepting frames and never recovers.
        try drainAudio(through: pair.time + Self.audioLead)

        // Backpressure: block until the encoder is ready rather than queueing
        // frames into memory. A feature length file would otherwise balloon.
        var spins = 0
        while !videoInput.isReadyForMoreMediaData {
            if writer.status == .failed { throw mapWriterError() }
            Thread.sleep(forTimeInterval: 0.002)
            spins += 1

            // Keep offering audio while waiting. If the video input is above
            // its high water level because the audio track fell behind, this is
            // what releases it.
            if spins % 100 == 0 {
                try drainAudio(through: .positiveInfinity)
            }

            // Fail loudly rather than hang. A wedged encoder used to look like
            // the app doing nothing forever, which is the least debuggable
            // possible outcome.
            if spins > Self.stallLimitSpins {
                throw SpatialWriterError.writeFailed(
                    "The encoder stopped accepting frames at frame \(appendedFrames)."
                )
            }
        }

        let group = try Self.makeTaggedGroup(left: pair.left, right: pair.right)

        guard videoAdaptor.appendTaggedPixelBufferGroup(group, withPresentationTime: pair.time) else {
            throw mapWriterError()
        }
        appendedFrames += 1
    }

    /// Builds the two layer tagged buffer group the MV-HEVC encoder expects.
    ///
    /// This goes through the double underscore CoreMedia symbols on purpose.
    /// CMTaggedBufferGroup and its create function are marked
    /// CF_REFINED_FOR_SWIFT, which hides the plain names from Swift in favour
    /// of a nicer replacement, and the replacement that can actually reach an
    /// asset writer input (AVAssetWriter.inputTaggedPixelBufferGroupReceiver)
    /// is macOS 26 and later. Make It 3D targets macOS 15, so the unrefined C entry
    /// points are the supported way to get there from Swift. Building the group
    /// as a CMSampleBuffer instead does not work: the writer input rejects it
    /// because a tagged buffer group sample buffer does not carry the "vide"
    /// media type the input requires.
    private static func makeTaggedGroup(
        left: CVPixelBuffer,
        right: CVPixelBuffer
    ) throws -> __CMTaggedBufferGroup {

        func collection(layer: Int64, eye: CMStereoViewComponents) throws -> __CMTagCollection {
            let tags = [
                __CMTagMakeWithSInt64Value(__CMTagCategory.videoLayerID, layer),
                __CMTagMakeWithFlagsValue(__CMTagCategory.stereoView, eye.rawValue)
            ]
            var result: __CMTagCollection?
            let status = tags.withUnsafeBufferPointer { buffer in
                __CMTagCollectionCreate(
                    kCFAllocatorDefault, buffer.baseAddress, CMItemCount(buffer.count), &result
                )
            }
            guard status == noErr, let result else {
                throw SpatialWriterError.writeFailed("Couldn't tag the eye views (\(status)).")
            }
            return result
        }

        // Layer 0 is the left eye, layer 1 the right, matching the view IDs and
        // the left and right view mapping set on the encoder.
        let leftCollection = try collection(layer: 0, eye: .leftEye)
        let rightCollection = try collection(layer: 1, eye: .rightEye)

        var group: __CMTaggedBufferGroup?
        let status = __CMTaggedBufferGroupCreate(
            kCFAllocatorDefault,
            [leftCollection, rightCollection] as CFArray,
            [left, right] as CFArray,
            &group
        )
        guard status == noErr, let group else {
            throw SpatialWriterError.writeFailed("Couldn't build the stereo pair (\(status)).")
        }
        return group
    }

    /// Copies source audio across, sample for sample and with no re-encode, up
    /// to the given time. Never blocks: anything the writer is not ready for is
    /// held back and offered again on the next frame, so the video track keeps
    /// moving.
    private func drainAudio(through time: CMTime) throws {
        guard let audioInput, let audioSource, !audioDrained else { return }

        while true {
            let sample: CMSampleBuffer
            if let pending = pendingAudio {
                sample = pending
            } else if let next = audioSource.next() {
                sample = next
            } else {
                audioDrained = true
                audioInput.markAsFinished()
                return
            }

            // A passthrough reader can hand back marker buffers that carry no
            // samples and an invalid timestamp. Comparing one of those against
            // the target time parks it as pending forever, and because the
            // pending slot is checked first, the drain then never advances
            // again and the video track stalls behind it.
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
            guard CMSampleBufferGetNumSamples(sample) > 0, presentationTime.isNumeric else {
                pendingAudio = nil
                continue
            }

            if presentationTime > time {
                pendingAudio = sample
                return
            }
            guard audioInput.isReadyForMoreMediaData else {
                pendingAudio = sample
                return
            }
            guard audioInput.append(sample) else { throw mapWriterError() }
            pendingAudio = nil
        }
    }

    /// Flushes whatever audio is left once the video track is complete. This is
    /// the one place blocking on the audio input is correct, because there is
    /// no video left to starve.
    private func finishAudio() throws {
        guard let audioInput, audioSource != nil, !audioDrained else { return }

        while !audioDrained {
            while !audioInput.isReadyForMoreMediaData {
                if writer.status == .failed { throw mapWriterError() }
                Thread.sleep(forTimeInterval: 0.002)
            }
            try drainAudio(through: .positiveInfinity)
        }
    }

    func finish() async throws {
        try finishAudio()
        videoInput.markAsFinished()
        await writer.finishWriting()

        if writer.status == .failed {
            let error = mapWriterError()
            cleanUpPartialFile()
            throw error
        }
    }

    func cancel() {
        writer.cancelWriting()
        audioSource?.cancel()
        cleanUpPartialFile()
    }

    private func cleanUpPartialFile() {
        try? FileManager.default.removeItem(at: outputURL)
    }

    /// Turns a writer failure into something a person can act on. A full disk is
    /// the one failure worth naming specifically, because the fix is obvious
    /// once you know that is what happened.
    private func mapWriterError() -> SpatialWriterError {
        guard let error = writer.error as NSError? else {
            return .writeFailed("The writer stopped for an unknown reason.")
        }
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        let codes: Set<Int> = [Int(ENOSPC), Int(EDQUOT)]
        if codes.contains(underlying?.code ?? 0) || error.code == AVError.diskFull.rawValue {
            cleanUpPartialFile()
            return .diskFull
        }
        return .writeFailed(error.localizedDescription)
    }
}

/// Pulls compressed audio samples straight off the source so they can be
/// appended without a re-encode.
final class AudioPassthrough {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    let formatDescription: CMAudioFormatDescription?

    /// Loads the audio track properly before opening the reader.
    ///
    /// The synchronous `tracks(withMediaType:)` accessor returns an empty array
    /// on a freshly created asset, because nothing has been loaded yet. Using
    /// it here silently produced files with no audio at all: the initializer
    /// threw "no audio track", the caller's `try?` swallowed it, and the writer
    /// carried on without an audio input.
    static func open(url: URL) async throws -> AudioPassthrough? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }
        let formats = try await track.load(.formatDescriptions)
        return try AudioPassthrough(asset: asset, track: track, formatDescription: formats.first)
    }

    private init(
        asset: AVURLAsset,
        track: AVAssetTrack,
        formatDescription: CMAudioFormatDescription?
    ) throws {
        reader = try AVAssetReader(asset: asset)
        self.formatDescription = formatDescription

        // nil output settings means hand back the samples exactly as stored.
        output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw SpatialWriterError.setupFailed("The audio track could not be read.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw SpatialWriterError.setupFailed("The audio reader would not start.")
        }
    }

    func next() -> CMSampleBuffer? {
        output.copyNextSampleBuffer()
    }

    func cancel() {
        reader.cancelReading()
    }
}
