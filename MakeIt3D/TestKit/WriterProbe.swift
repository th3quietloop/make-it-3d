import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Feeds the MV-HEVC writer synthetic stereo pairs with nothing else in the
/// loop: no depth model, no warp, no reader.
///
/// It exists to answer one question quickly when an export stalls, which is
/// whether the writer is the thing that stopped or something upstream of it.
enum WriterProbe {

    static func run(frameCount: Int = 120, width: Int = 1280, height: Int = 720) async -> Bool {
        print("")
        print("Writer probe: \(frameCount) frames at \(width)x\(height)")

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakeIt3DWriterProbe.mov")

        let probe = SourceProbe(
            url: outputURL,
            duration: CMTime(value: CMTimeValue(frameCount), timescale: 30),
            nominalFrameRate: 30,
            width: width,
            height: height,
            hasAudio: false,
            estimatedFrameCount: frameCount
        )

        do {
            let writer = try await SpatialWriter.open(
                outputURL: outputURL, probe: probe, tuning: .default
            )
            try writer.start()

            let pool = try FramePool(width: width, height: height)
            let start = Date()

            for index in 0..<frameCount {
                let left = try pool.next()
                let right = try pool.next()
                fill(left, value: UInt8(index % 256))
                fill(right, value: UInt8((index + 8) % 256))

                let time = CMTime(value: CMTimeValue(index), timescale: 30)
                try writer.append(StereoPair(left: left, right: right, time: time))

                if index % 30 == 0 {
                    print(String(
                        format: "  %d frames, %.1f fps",
                        index, Double(index) / max(Date().timeIntervalSince(start), 0.001)
                    ))
                }
            }

            try await writer.finish()
            print("  wrote \(writer.frameCount) frames")

            let report = await VerificationReport.verify(
                outputURL: outputURL, sourceProbe: probe, writtenFrameCount: writer.frameCount
            )
            print(report.text)
            return report.passed
        } catch {
            print("  FAIL: \(error.localizedDescription)")
            return false
        }
    }

    private static func fill(_ buffer: CVPixelBuffer, value: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        memset(base, Int32(value), height * rowBytes)
    }
}
