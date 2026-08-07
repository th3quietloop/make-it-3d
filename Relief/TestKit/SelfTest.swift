import Foundation
import AVFoundation

/// The Phase 1 gate, automated.
///
/// Run the app with `--selftest` and it converts the synthetic clip end to end,
/// checks the stereo sign convention, and prints a verification report. Add a
/// file path after the flag to run a real clip through the same path.
enum SelfTest {

    static func shouldRun(_ arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains("--selftest")
    }

    static func extraClips(_ arguments: [String] = CommandLine.arguments) -> [URL] {
        guard let index = arguments.firstIndex(of: "--selftest") else { return [] }
        return arguments.dropFirst(index + 1)
            .filter { !$0.hasPrefix("--") }
            .map { URL(fileURLWithPath: $0) }
    }

    static func run() async -> Bool {
        var allPassed = true
        print("")
        print("Relief self test")
        print(String(repeating: "=", count: 60))

        // MARK: Sign convention
        //
        // Run first. If the stereo sign is wrong, nothing downstream is worth
        // looking at.
        do {
            let result = try SignConventionCheck.run()
            print("")
            print(result.line)
            if !result.passed { allPassed = false }
        } catch {
            print("")
            print("FAIL  Stereo sign convention: \(error.localizedDescription)")
            allPassed = false
        }

        // MARK: Synthetic clip end to end

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReliefSelfTest", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: workingDirectory, withIntermediateDirectories: true
        )

        var clips: [URL] = []
        do {
            let syntheticURL = workingDirectory.appendingPathComponent("synthetic_source.mov")
            print("")
            print("Generating the synthetic clip...")
            clips.append(try await SyntheticClip.generate(at: syntheticURL))
        } catch {
            print("FAIL  Synthetic clip: \(error.localizedDescription)")
            allPassed = false
        }

        clips.append(contentsOf: extraClips())

        for clip in clips {
            print("")
            print(String(repeating: "-", count: 60))
            print("Converting \(clip.lastPathComponent)")
            let passed = await convert(clip, into: workingDirectory)
            if !passed { allPassed = false }
        }

        print("")
        print(String(repeating: "=", count: 60))
        print(allPassed ? "SELF TEST: PASS" : "SELF TEST: FAIL")
        print("Working files: \(workingDirectory.path)")
        print("")
        return allPassed
    }

    private static func convert(_ url: URL, into directory: URL) async -> Bool {
        do {
            let probe = try await Ingest.probe(url: url)
            print(String(
                format: "Source: %@, %.2fs, %.2f fps, %d frames estimated, audio: %@",
                probe.displayDimensions,
                probe.duration.seconds,
                probe.nominalFrameRate,
                probe.estimatedFrameCount,
                probe.hasAudio ? "yes" : "no"
            ))

            let outputURL = directory.appendingPathComponent(
                url.deletingPathExtension().lastPathComponent + "_spatial.mov"
            )
            let request = ConversionRequest(
                probe: probe, tuning: .default, outputURL: outputURL
            )

            let start = Date()
            var report: VerificationReport?
            var failure: String?
            var framesDone = 0

            let stream = AsyncStream<ConversionEvent> { continuation in
                Task.detached {
                    await ConversionController.run(request) { continuation.yield($0) }
                    continuation.finish()
                }
            }

            for await event in stream {
                switch event {
                case .started(let total):
                    print("Converting \(total) frames...")
                case .progress(_, let done):
                    framesDone = done
                    if done % 30 == 0 {
                        let elapsed = Date().timeIntervalSince(start)
                        print(String(
                            format: "  %d frames, %.1f fps", done, Double(done) / max(elapsed, 0.001)
                        ))
                    }
                case .finished(let value):
                    report = value
                case .failed(let message):
                    failure = message
                case .cancelled:
                    failure = "cancelled"
                }
            }

            let elapsed = Date().timeIntervalSince(start)
            let throughput = Double(framesDone) / max(elapsed, 0.001)

            if let failure {
                print("FAIL  Conversion: \(failure)")
                return false
            }
            guard let report else {
                print("FAIL  Conversion: no report was produced.")
                return false
            }

            print("")
            print(report.text)
            print("")
            print(String(
                format: "Throughput: %.2f fps over %.1fs (%d frames)",
                throughput, elapsed, framesDone
            ))
            // The PRD guardrail is 15 fps at 1080p. Report it either way rather
            // than failing the gate on a machine dependent number.
            if probe.height >= 1080 {
                print(throughput >= 15
                      ? "PASS  Throughput guardrail: at or above 15 fps at 1080p"
                      : "NOTE  Throughput guardrail: below 15 fps at 1080p")
            }
            return report.passed
        } catch {
            print("FAIL  Conversion: \(error.localizedDescription)")
            return false
        }
    }
}
