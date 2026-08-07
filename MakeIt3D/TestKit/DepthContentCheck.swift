import Foundation
import AVFoundation

/// Measures real footage and prints what the depth analyser makes of it.
///
/// This exists because the confidence thresholds in DepthContent are the one
/// place in the auto tuner where a number was chosen rather than derived, and a
/// chosen number that nobody ever checked against real video is a guess wearing
/// a lab coat.
///
/// Run it as `MakeIt3D --analyse <file> [file ...]`. It prints the per shot
/// spread and confidence so the thresholds can be set from measurements rather
/// than from intuition, and rechecked whenever the depth model changes.
enum DepthContentCheck {

    static func shouldRun() -> Bool {
        CommandLine.arguments.contains("--analyse") || CommandLine.arguments.contains("--analyze")
    }

    static func run() async -> Bool {
        let paths = CommandLine.arguments
            .drop { $0 != "--analyse" && $0 != "--analyze" }
            .dropFirst()
            .filter { !$0.hasPrefix("-") }

        guard !paths.isEmpty else {
            print("Usage: MakeIt3D --analyse <file> [file ...]")
            return false
        }

        var allSucceeded = true

        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("MISSING  \(url.lastPathComponent)")
                allSucceeded = false
                continue
            }

            print("")
            print(String(repeating: "=", count: 72))
            print(url.lastPathComponent)
            print(String(repeating: "=", count: 72))

            do {
                let probe = try await Ingest.probe(url: url)
                let estimator = try CoreMLDepthEstimator()
                let began = Date()
                let plan = try await ShotPlanner.plan(
                    for: probe,
                    estimator: estimator,
                    tuning: .default
                )
                let elapsed = Date().timeIntervalSince(began)

                print(String(
                    format: "%d x %d, %.2fs, %d shots from %d samples in %.1fs",
                    probe.width, probe.height, probe.duration.seconds,
                    plan.shots.count, plan.samplesTaken, elapsed
                ))
                print("")
                print("  shot  start     dur     spread  conf   S%     C      load")
                print("  " + String(repeating: "-", count: 60))

                for shot in plan.shots {
                    print(String(
                        format: "  %4d  %7.2f  %6.2f  %6.3f  %4.2f  %5.3f  %5.3f  %5.2f",
                        shot.id + 1,
                        shot.start.seconds,
                        shot.duration.seconds,
                        shot.content.spread,
                        shot.settings.confidence,
                        shot.settings.strength * 100,
                        shot.settings.convergence,
                        shot.settings.predictedLoad
                    ))
                }

                // The thing the old gauge could never say: do these shots
                // differ from each other at all?
                let spreads = plan.shots.map(\.content.spread)
                let strengths = plan.shots.map(\.settings.strength)
                if let lowSpread = spreads.min(), let highSpread = spreads.max(),
                   let lowS = strengths.min(), let highS = strengths.max() {
                    print("")
                    print(String(
                        format: "  spread %.3f to %.3f, strength %.3f%% to %.3f%%",
                        lowSpread, highSpread, lowS * 100, highS * 100
                    ))
                    if plan.shots.count > 1, highS - lowS < 1e-6 {
                        print("  WARNING: every shot got the same strength. The measurement is not discriminating.")
                        allSucceeded = false
                    }
                }
            } catch {
                print("FAILED  \(error.localizedDescription)")
                allSucceeded = false
            }
        }

        print("")
        return allSucceeded
    }
}
