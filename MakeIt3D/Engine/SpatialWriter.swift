import AVFoundation
import CoreMedia
import VideoToolbox
import Foundation
import Darwin

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

/// Higher-bit-depth writer support is exercised by HDRCapabilityCheck. The app
/// conversion continues to request SDR until its complete renderer is HDR-capable.
enum SpatialColorEncoding: Sendable {
    case sdr, hlg, pq
    var pixelFormat: OSType {
        self == .sdr ? Ingest.pixelFormat : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }
    var properties: [String: String] {
        [AVVideoColorPrimariesKey: self == .sdr ? AVVideoColorPrimaries_ITU_R_709_2 : AVVideoColorPrimaries_ITU_R_2020,
         AVVideoTransferFunctionKey: self == .sdr ? AVVideoTransferFunction_ITU_R_709_2
            : (self == .hlg ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_SMPTE_ST_2084_PQ),
         AVVideoYCbCrMatrixKey: self == .sdr ? AVVideoYCbCrMatrix_ITU_R_709_2 : AVVideoYCbCrMatrix_ITU_R_2020]
    }
}

/// Writes MV-HEVC spatial video: two tagged layers in one HEVC track, carrying
/// the spatial metadata visionOS reads, with the source audio passed through
/// untouched.
final class SpatialWriter: SpatialVideoWriting {

    let outputURL: URL

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let videoAdaptor: AVAssetWriterInputTaggedPixelBufferGroupAdaptor
    private final class AudioChannel {
        let input: AVAssetWriterInput
        let source: AudioPassthrough
        var pending: CMSampleBuffer?
        var drained = false
        init(input: AVAssetWriterInput, source: AudioPassthrough) {
            self.input = input
            self.source = source
        }
    }
    private var audioChannels: [AudioChannel] = []
    private let stagingURL: URL
    private let timeRange: CMTimeRange?
    private var committed = false
    private var audioSamplesWritten = 0

    private let width: Int
    private let height: Int
    private var started = false
    private var appendedFrames = 0

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
        tuning: EngineTuning,
        timeRange: CMTimeRange? = nil,
        colorEncoding: SpatialColorEncoding = .sdr
    ) async throws -> SpatialWriter {
        let audio = probe.hasAudio ? try await AudioPassthrough.open(url: probe.url, timeRange: timeRange) : []
        return try SpatialWriter(
            outputURL: outputURL, probe: probe, tuning: tuning,
            audio: audio, timeRange: timeRange, colorEncoding: colorEncoding
        )
    }

    private init(
        outputURL: URL,
        probe: SourceProbe,
        tuning: EngineTuning,
        audio: [AudioPassthrough],
        timeRange: CMTimeRange?,
        colorEncoding: SpatialColorEncoding
    ) throws {
        guard VTIsStereoMVHEVCEncodeSupported() else {
            throw SpatialWriterError.unsupportedEncoder
        }

        self.outputURL = outputURL
        self.width = probe.width
        self.height = probe.height

        self.timeRange = timeRange
        guard outputURL.standardizedFileURL.resolvingSymlinksInPath()
                != probe.url.standardizedFileURL.resolvingSymlinksInPath(),
              !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw SpatialWriterError.setupFailed("The destination already exists. Choose a new filename.")
        }
        stagingURL = outputURL.deletingLastPathComponent().appendingPathComponent(
            ".\(outputURL.lastPathComponent).\(UUID().uuidString).partial.mov"
        )
        do {
            writer = try AVAssetWriter(outputURL: stagingURL, fileType: .mov)
        } catch {
            throw SpatialWriterError.setupFailed(error.localizedDescription)
        }

        // MARK: Video input
        //
        // Units matter here and they are not all the same:
        //   baseline is micrometres, FOV is millidegrees, and the disparity
        //   adjustment is an int32 where 10000 means 1.0.

        guard tuning.baselineMillimetres.isFinite, (0...1000).contains(tuning.baselineMillimetres),
              tuning.horizontalFOVDegrees.isFinite, (1...179).contains(tuning.horizontalFOVDegrees),
              tuning.horizontalDisparityAdjustment.isFinite,
              (-1...1).contains(tuning.horizontalDisparityAdjustment) else {
            throw SpatialWriterError.setupFailed("The headset metadata is outside its supported range.")
        }
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

        if colorEncoding != .sdr {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            compression[kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String] = false
            compression[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] = kVTHDRMetadataInsertionMode_Auto
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: probe.width,
            AVVideoHeightKey: probe.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: colorEncoding.properties
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
                kCVPixelBufferPixelFormatTypeKey as String: colorEncoding.pixelFormat,
                kCVPixelBufferWidthKey as String: probe.width,
                kCVPixelBufferHeightKey as String: probe.height
            ]
        )

        // MARK: Audio passthrough

        for source in audio {
            let input = AVAssetWriterInput(
                mediaType: .audio, outputSettings: nil,
                sourceFormatHint: source.formatDescription
            )
            input.expectsMediaDataInRealTime = false
            input.languageCode = source.languageCode
            input.extendedLanguageTag = source.extendedLanguageTag
            input.metadata = source.metadata
            input.marksOutputTrackAsEnabled = source.isEnabled
            guard writer.canAdd(input) else {
                throw SpatialWriterError.setupFailed("An audio track could not be preserved in the output movie.")
            }
            writer.add(input)
            audioChannels.append(AudioChannel(input: input, source: source))
        }
        let enabled = audioChannels.filter { $0.source.isEnabled }
        if audioChannels.count > 1, enabled.count == 1 {
            let group = AVAssetWriterInputGroup(inputs: audioChannels.map(\.input), defaultInput: enabled[0].input)
            guard writer.canAdd(group) else {
                throw SpatialWriterError.setupFailed("The alternate audio track group could not be preserved.")
            }
            writer.add(group)
        }
    }

    deinit {
        if !committed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: stagingURL)
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
        writer.startSession(atSourceTime: timeRange?.start ?? .zero)
        started = true
    }

    func append(_ pair: StereoPair) throws {
        guard started else { throw SpatialWriterError.writeFailed("The writer was not started.") }

        // Keep the audio track running slightly ahead of the video, otherwise
        // the video input stops accepting frames and never recovers.
        try drainAudioChannels(through: pair.time + Self.audioLead)

        // Backpressure: block until the encoder is ready rather than queueing
        // frames into memory. A feature length file would otherwise balloon.
        var spins = 0
        while !videoInput.isReadyForMoreMediaData {
            if Task.isCancelled {
                cancel()
                throw CancellationError()
            }
            if writer.status == .failed { throw mapWriterError() }
            Thread.sleep(forTimeInterval: 0.002)
            spins += 1

            // Keep offering audio while waiting. If the video input is above
            // its high water level because the audio track fell behind, this is
            // what releases it.
            if spins % 100 == 0 {
                try drainAudioChannels(through: .positiveInfinity)
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
    private func drainAudioChannels(through time: CMTime) throws {
        for channel in audioChannels where !channel.drained {
            try drainAudio(channel, through: time)
        }
    }

    private func drainAudio(_ channel: AudioChannel, through time: CMTime) throws {
        while !channel.drained {
            try Task.checkCancellation()
            let sample: CMSampleBuffer
            if let pending = channel.pending {
                sample = pending
            } else if let next = try channel.source.next() {
                sample = next
            } else {
                channel.drained = true
                channel.input.markAsFinished()
                return
            }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
            guard CMSampleBufferGetNumSamples(sample) > 0, presentationTime.isNumeric else {
                channel.pending = nil
                continue
            }
            if let timeRange, presentationTime >= timeRange.end {
                channel.pending = nil
                channel.drained = true
                channel.input.markAsFinished()
                return
            }
            guard presentationTime <= time, channel.input.isReadyForMoreMediaData else {
                channel.pending = sample
                return
            }
            guard channel.input.append(sample) else { throw mapWriterError() }
            channel.pending = nil
            audioSamplesWritten += 1
        }
    }

    private func finishAudio() throws {
        var lastProgress = Date()
        while audioChannels.contains(where: { !$0.drained }) {
            try Task.checkCancellation()
            if writer.status == .failed { throw mapWriterError() }
            let before = audioSamplesWritten
            try drainAudioChannels(through: .positiveInfinity)
            if before != audioSamplesWritten { lastProgress = Date() }
            if Date().timeIntervalSince(lastProgress) > 60 {
                throw SpatialWriterError.writeFailed("The encoder stopped accepting audio while finishing.")
            }
            if audioChannels.contains(where: { !$0.drained }) {
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
    }

    func finish() async throws {
        guard appendedFrames > 0 else {
            throw SpatialWriterError.writeFailed("The selected range contained no video frames.")
        }
        // Audio may continue beyond the last video frame. Release video
        // backpressure before draining that tail, otherwise both inputs wait.
        videoInput.markAsFinished()
        try finishAudio()
        if let timeRange { writer.endSession(atSourceTime: timeRange.end) }
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else { throw mapWriterError() }

        // A same-directory exclusive rename publishes a complete file atomically.
        // Races with another export cannot replace an existing destination.
        let status = stagingURL.path.withCString { from in
            outputURL.path.withCString { to in renamex_np(from, to, UInt32(RENAME_EXCL)) }
        }
        guard status == 0 else {
            throw SpatialWriterError.writeFailed(
                "Couldn't publish the finished movie: \(String(cString: strerror(errno)))."
            )
        }
        committed = true
    }

    func cancel() {
        if !committed { writer.cancelWriting() }
        audioChannels.forEach { $0.source.cancel() }
        cleanUpPartialFile()
    }

    private func cleanUpPartialFile() {
        try? FileManager.default.removeItem(at: stagingURL)
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
    let languageCode: String?
    let extendedLanguageTag: String?
    let metadata: [AVMetadataItem]
    let isEnabled: Bool

    static func open(url: URL, timeRange: CMTimeRange? = nil) async throws -> [AudioPassthrough] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        var sources: [AudioPassthrough] = []
        for track in tracks {
            let trackRange = try await track.load(.timeRange)
            if let timeRange, CMTimeRangeGetIntersection(trackRange, otherRange: timeRange).isEmpty {
                continue
            }
            let formats = try await track.load(.formatDescriptions)
            let language = try await track.load(.languageCode)
            let extended = try await track.load(.extendedLanguageTag)
            let metadata = try await track.load(.metadata)
            let enabled = try await track.load(.isEnabled)
            sources.append(try AudioPassthrough(
                asset: asset, track: track, formatDescription: formats.first,
                languageCode: language, extendedLanguageTag: extended,
                metadata: metadata, isEnabled: enabled, timeRange: timeRange
            ))
        }
        return sources
    }

    private init(
        asset: AVURLAsset, track: AVAssetTrack,
        formatDescription: CMAudioFormatDescription?, languageCode: String?,
        extendedLanguageTag: String?, metadata: [AVMetadataItem], isEnabled: Bool,
        timeRange: CMTimeRange?
    ) throws {
        reader = try AVAssetReader(asset: asset)
        self.formatDescription = formatDescription
        self.languageCode = languageCode
        self.extendedLanguageTag = extendedLanguageTag
        self.metadata = metadata
        self.isEnabled = isEnabled
        output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        if let timeRange { reader.timeRange = timeRange }
        guard reader.canAdd(output) else {
            throw SpatialWriterError.setupFailed("The audio track could not be read.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw SpatialWriterError.setupFailed(
                reader.error?.localizedDescription ?? "The audio reader would not start."
            )
        }
    }

    func next() throws -> CMSampleBuffer? {
        let sample = output.copyNextSampleBuffer()
        if sample == nil, reader.status == .failed {
            throw SpatialWriterError.writeFailed(
                "Reading source audio failed. \(reader.error?.localizedDescription ?? "Unknown reader error.")"
            )
        }
        return sample
    }

    func cancel() { reader.cancelReading() }
}
