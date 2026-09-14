import AVFoundation
import CoreVideo
import Foundation

/// An isolated 10-bit encoder/readback gate. Passing it does not enable HDR
/// conversion: the app's depth warp remains SDR and has a separate validation gate.
enum HDRCapabilityCheck {
    struct Result: Sendable {
        let passed: Bool
        let detail: String
        let outputURL: URL
    }

    static func run(in directory: URL) async -> Result {
        let output = directory.appendingPathComponent("hdr-writer-capability-\(UUID()).mov")
        do {
            let probe = SourceProbe(url: output.appendingPathExtension("generated-source"),
                duration: CMTime(value: 12, timescale: 30), nominalFrameRate: 30,
                width: 128, height: 64, hasAudio: false, estimatedFrameCount: 12)
            let writer = try await SpatialWriter.open(outputURL: output, probe: probe,
                tuning: .default, colorEncoding: .hlg)
            try writer.start()
            for index in 0..<12 {
                let left = try frame(), right = try frame()
                try writer.append(StereoPair(left: left, right: right, time: CMTime(value: Int64(index), timescale: 30)))
            }
            try await writer.finish()
            let asset = AVURLAsset(url: output)
            let hdrTracks = try await asset.loadTracks(withMediaCharacteristic: .containsHDRVideo)
            let stereoTracks = try await asset.loadTracks(withMediaCharacteristic: .containsStereoMultiviewVideo)
            guard let track = try await asset.loadTracks(withMediaType: .video).first,
                  let format = try await track.load(.formatDescriptions).first else {
                throw IngestError.noVideoTrack
            }
            let bits = (CMFormatDescriptionGetExtension(format,
                extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? NSNumber)?.intValue
            let reader = try AVAssetReader(asset: asset)
            let input = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            ])
            reader.add(input)
            guard reader.startReading(), let sample = input.copyNextSampleBuffer(),
                  let buffer = CMSampleBufferGetImageBuffer(sample) else {
                throw IngestError.readerFailed("The HDR test movie could not be decoded.")
            }
            let error = lumaError(buffer)
            reader.cancelReading()
            let passed = !hdrTracks.isEmpty && !stereoTracks.isEmpty && bits == 10 && error < 8
            return Result(passed: passed,
                detail: "HDR tracks \(hdrTracks.count), stereo tracks \(stereoTracks.count), coded depth \(bits.map(String.init) ?? "not reported") bits, mean luma-code error \(String(format: "%.2f", error)). App rendering remains SDR.",
                outputURL: output)
        } catch {
            return Result(passed: false, detail: error.localizedDescription, outputURL: output)
        }
    }

    private static func frame() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 128, 64,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw WarpError.textureAllocationFailed }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            for y in 0..<rows {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
                for x in 0..<128 {
                    row[x] = UInt16(plane == 0 ? 64 + x * 876 / 127 : 512) << 6
                }
            }
        }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return buffer
    }

    private static func lumaError(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return .infinity }
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        var total = 0.0
        for y in 0..<64 {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
            for x in 0..<128 { total += abs(Double(row[x] >> 6) - Double(64 + x * 876 / 127)) }
        }
        return total / Double(128 * 64)
    }
}
