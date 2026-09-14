import AVFoundation
import Foundation

/// Tiny generated media regressions. No private recordings or external ffmpeg
/// installation are needed for the release gate.
enum MediaIntegrityCheck {
    static func run(in directory: URL) async -> Bool {
        var passed = true
        var tail = SyntheticClip.Spec()
        tail.width = 160; tail.height = 120; tail.durationSeconds = 1
        tail.audioDurationSeconds = 20
        var multi = tail
        multi.audioDurationSeconds = 2; multi.durationSeconds = 2; multi.audioTrackCount = 2
        var variable = multi
        variable.audioTrackCount = 0; variable.variableFrameRate = true
        for (name, spec) in [("audio-tail", tail), ("multiple-audio", multi), ("variable-rate", variable)] {
            do {
                let source = directory.appendingPathComponent("integrity-\(name)-source.mov")
                _ = try await SyntheticClip.generate(at: source, spec: spec)
                let report = try await roundTrip(source: source,
                    output: directory.appendingPathComponent("integrity-\(name)-output.mov"))
                print("\(report.passed ? "PASS" : "FAIL")  Media regression: \(name)")
                if !report.passed { print(report.text); passed = false }
                if name == "multiple-audio" {
                    var custom = EngineTuning.default
                    custom.horizontalFOVDegrees = 80; custom.baselineMillimetres = 25
                    let range = CMTimeRange(start: CMTime(seconds: 0.4, preferredTimescale: 600),
                                           duration: CMTime(seconds: 0.8, preferredTimescale: 600))
                    let rangeReport = try await roundTrip(source: source,
                        output: directory.appendingPathComponent("integrity-range-output.mov"),
                        tuning: custom, timeRange: range)
                    print("\(rangeReport.passed ? "PASS" : "FAIL")  Media regression: range audio and custom metadata")
                    if !rangeReport.passed { print(rangeReport.text); passed = false }
                    try await verifyDestinationSafety(source: source, directory: directory)
                    print("PASS  Media regression: exclusive destination and cancellation cleanup")
                }
            } catch {
                print("FAIL  Media regression \(name): \(error.localizedDescription)")
                passed = false
            }
        }
        return passed
    }

    static func roundTrip(source: URL, output: URL, tuning: EngineTuning = .default,
                          timeRange: CMTimeRange? = nil) async throws -> VerificationReport {
        let probe = try await Ingest.probe(url: source)
        let range = try Ingest.validatedRange(timeRange, duration: probe.duration)
        let frames = try await Ingest.FrameSource.open(probe: probe, timeRange: range)
        let writer = try await SpatialWriter.open(outputURL: output, probe: probe, tuning: tuning, timeRange: range)
        do {
            try writer.start()
            while let frame = try frames.next() {
                try writer.append(StereoPair(left: frame.pixelBuffer, right: frame.pixelBuffer, time: frame.time))
            }
            try await writer.finish()
        } catch {
            frames.cancel(); writer.cancel(); throw error
        }
        return await VerificationReport.verify(outputURL: output, sourceProbe: probe,
            writtenFrameCount: writer.frameCount, sourceFrameCount: frames.decodedFrameCount,
            tuning: tuning, timeRange: range)
    }

    private static func verifyDestinationSafety(source: URL, directory: URL) async throws {
        let existing = directory.appendingPathComponent("protected-existing.mov")
        let bytes = Data("Preserve this existing file".utf8)
        try bytes.write(to: existing)
        let probe = try await Ingest.probe(url: source)
        do {
            _ = try await SpatialWriter.open(outputURL: existing, probe: probe, tuning: .default)
            throw IngestError.readerFailed("An existing destination was accepted.")
        } catch is SpatialWriterError { }
        guard try Data(contentsOf: existing) == bytes else {
            throw IngestError.readerFailed("The existing destination was modified.")
        }
        let cancelled = directory.appendingPathComponent("cancelled-output.mov")
        let writer = try await SpatialWriter.open(outputURL: cancelled, probe: probe, tuning: .default)
        try writer.start()
        writer.cancel()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard !FileManager.default.fileExists(atPath: cancelled.path),
              !files.contains(where: { $0.lastPathComponent.contains("cancelled-output.mov.") }) else {
            throw IngestError.readerFailed("Cancellation left an output or staging file.")
        }
    }
}
