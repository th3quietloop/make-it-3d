import Foundation

/// Runs the app against its own test clip and writes down what happened.
///
/// A headset app is awkward to measure by hand: the numbers that matter are
/// frame rate and pairing, and both are things you have to watch for a while
/// rather than glance at. Launching with MAKEIT3D_SELFTEST=1 makes the app open
/// the test clip, play it, take readings, and write a report where the host can
/// read it.
///
/// It exercises the real path. Nothing here is a simulation of playback: it is
/// playback, watched.
@MainActor
enum SelfTest {

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["MAKEIT3D_SELFTEST"] == "1"
    }

    static var reportURL: URL {
        URL.documentsDirectory.appending(path: "selftest.txt")
    }

    /// Where the warp's budget comes from.
    ///
    /// The warp runs once per video frame, not once per display frame, so a
    /// stereo pair has a whole video frame to be synthesized in. At 30 fps that
    /// is 33.3 ms. Spending more than a third of it is the point at which the
    /// warp starts competing with everything else on the GPU.
    private static let warpBudgetFraction = 0.33

    /// How long to watch before writing anything down. Long enough for the
    /// warp to have run several hundred times and for at least one cut to have
    /// gone past, so the shot change path is included rather than assumed.
    private static let settleSeconds = 4.0
    private static let watchSeconds = 12.0

    /// Arranged for measurement, not for watching.
    ///
    /// A simulator looks in one fixed direction, so the picture and the dial
    /// have to be in the same view for a screenshot to show both. On a head
    /// this would be a glance down; here it has to be a layout.
    private static func arrangeForMeasurement(_ room: RoomSettings) {
        room.screenWidthMetres = 2.2
        room.screenHeightMetres = 0.25
        room.distanceMetres = 3.4
        room.consoleDropMetres = -0.05
    }

    static func run(model: PlayerModel, room: RoomSettings) async {
        arrangeForMeasurement(room)
        await run(model: model)
    }

    static func run(model: PlayerModel) async {
        var lines = [String]()
        func say(_ line: String) {
            lines.append(line)
            print(line)
        }

        say("Make It 3D for Vision Pro, self test")
        say("")

        await model.openTestClip()

        if case .failed(let message) = model.status {
            say("FAIL  Opening the test clip: \(message)")
            write(lines)
            return
        }

        guard let file = model.file else {
            say("FAIL  Opening the test clip: nothing was opened.")
            write(lines)
            return
        }

        say("File        \(file.url.lastPathComponent)")
        say("Picture     \(file.width) x \(file.height) at \(String(format: "%.2f", file.frameRate)) fps")
        say("Depth       \(file.depth.map { "\($0.width) x \($0.height)" } ?? "none")")
        say("Shots       \(file.depth?.shots.count ?? 0)")
        say("Duration    \(String(format: "%.1f", file.duration.seconds)) s")
        say("")

        try? await Task.sleep(for: .seconds(settleSeconds))
        say("Screen      \(model.screenMaterial.summary)")
        say(String(
            format: "Console     authored %.4f, rendered %.3f m",
            model.consoleAuthoredWidth, model.consoleWidthMetres
        ))
        say("")

        // The sign convention, measured here rather than only on the Mac that
        // compiled the shaders. This is a different GPU running a different
        // compilation of the same source, and the sign is the one thing this
        // project has already been wrong about once.
        do {
            for result in try model.runSignConventionCheck() {
                say(result.line)
            }
        } catch {
            say("FAIL  Stereo sign convention: could not run. \(error.localizedDescription)")
        }

        // Measured from the pixels of the frame actually playing, because every
        // other number in this report would read perfectly on a flat picture.
        do {
            for result in try model.runEyeSeparationCheck() {
                say(result.line)
            }
        } catch {
            say("FAIL  Eye separation: could not run. \(error.localizedDescription)")
        }
        say("")

        // Reset so the settling period does not colour the reading.
        model.performance.reset()
        model.resetPairing()
        model.resetDialLatency()

        // The dial gets turned during the watch, because the question Phase 3
        // asks is whether frame rate survives someone moving it, not whether it
        // survives being left alone.
        let sweepStart = Date()
        var sweeps = 0
        var worst = PerformanceMeter.Reading()
        var best = PerformanceMeter.Reading()
        var samples = 0
        var displayTotal = 0.0
        var warpTotal = 0.0

        while Date().timeIntervalSince(sweepStart) < watchSeconds {
            try? await Task.sleep(for: .milliseconds(250))

            // A full travel of the dial and back, four times a second, which is
            // faster than anyone actually turns it.
            let phase = Date().timeIntervalSince(sweepStart) / watchSeconds
            let swept = StereoTuning.strengthRange.lowerBound
                + (StereoTuning.strengthRange.upperBound - StereoTuning.strengthRange.lowerBound)
                * (0.5 + 0.5 * sin(phase * .pi * 8))
            model.setStrength(swept)
            sweeps += 1

            let reading = model.performance.reading
            guard !reading.isEmpty else { continue }
            samples += 1
            displayTotal += reading.displayFramesPerSecond
            warpTotal += reading.meanWarpMilliseconds
            if worst.isEmpty || reading.displayFramesPerSecond < worst.displayFramesPerSecond {
                worst = reading
            }
            if best.isEmpty || reading.displayFramesPerSecond > best.displayFramesPerSecond {
                best = reading
            }
        }

        say("Watched \(String(format: "%.0f", watchSeconds)) s while sweeping the depth dial \(sweeps) times.")
        say("")

        guard samples > 0 else {
            say("FAIL  No readings were taken, so the render loop never ran.")
            write(lines)
            return
        }

        let meanDisplay = displayTotal / Double(samples)
        let meanWarp = warpTotal / Double(samples)

        say(String(format: "Display, mean          %.1f fps over %d readings", meanDisplay, samples))
        say(String(format: "Display, worst second  %.1f fps", worst.displayFramesPerSecond))
        say(String(format: "Display, best second   %.1f fps", best.displayFramesPerSecond))
        say(String(format: "Slowest display frame  %.1f ms", worst.worstDisplayFrameMilliseconds))
        say(String(format: "Stereo pair, mean      %.2f ms", meanWarp))
        say(String(format: "Stereo pair, worst     %.2f ms", worst.worstWarpMilliseconds))
        say(String(format: "Pairs per second       %.1f", best.warpsPerSecond))
        say("")

        let pairing = model.pairing
        say("Pairing     \(pairing.identityMatches) by buffer, \(pairing.exactMatches) by time, "
            + "\(pairing.nearMatches) near, \(pairing.misses) missed, "
            + "\(pairing.missingDepthFrames) with no depth")
        say("Frame index \(model.indexMismatches) mismatched of \(model.indexFramesChecked) checked")
        say("Dial        \(model.dialChangesSeen) changes drawn, worst latency "
            + "\(model.dialLatencyWorstFrames) display frame(s)")
        say("")

        // MARK: Verdicts

        verdict(
            &lines,
            name: "Colour and depth stay aligned through the player",
            passed: model.indexFramesChecked > 0 && model.indexMismatches == 0,
            detail: "\(model.indexMismatches) mismatched of \(model.indexFramesChecked)"
        )
        verdict(
            &lines,
            name: "Pairing is exact, not approximate",
            passed: pairing.nearMatches == 0 && pairing.misses == 0
                && pairing.missingDepthFrames == 0,
            detail: "\(pairing.nearMatches) near, \(pairing.misses) missed"
        )
        verdict(
            &lines,
            name: "Both eyes are being synthesized",
            passed: model.screenMaterial == .perEye,
            detail: model.screenMaterial.summary
        )
        let budget = 1000.0 / file.frameRate * warpBudgetFraction
        verdict(
            &lines,
            name: "The warp fits inside a video frame",
            passed: worst.worstWarpMilliseconds > 0 && worst.worstWarpMilliseconds <= budget,
            detail: String(
                format: "worst pair %.2f ms against a %.1f ms budget, which is %.0f%% of a %.0f fps frame",
                worst.worstWarpMilliseconds, budget, warpBudgetFraction * 100, file.frameRate
            )
        )
        verdict(
            &lines,
            name: "The dial is visible within one frame",
            passed: model.dialChangesSeen > 0 && model.dialLatencyWorstFrames <= 1,
            detail: "worst \(model.dialLatencyWorstFrames) display frame(s) "
                + "over \(model.dialChangesSeen) changes, want at most 1"
        )
        verdict(
            &lines,
            name: "Frame rate holds while the dial moves",
            // 88 rather than 90: the reading is a one second window and a
            // single dropped frame inside it is not a failure of the warp.
            passed: worst.displayFramesPerSecond >= 88,
            detail: String(
                format: "worst second %.1f fps, want at least 88.0",
                worst.displayFramesPerSecond
            )
        )

        write(lines)
    }

    private static func verdict(
        _ lines: inout [String], name: String, passed: Bool, detail: String
    ) {
        let line = "\(passed ? "PASS" : "FAIL")  \(name): \(detail)"
        lines.append(line)
        print(line)
    }

    private static func write(_ lines: [String]) {
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: reportURL, atomically: true, encoding: .utf8)
        print("Self test report written to \(reportURL.path(percentEncoded: false))")
    }
}
