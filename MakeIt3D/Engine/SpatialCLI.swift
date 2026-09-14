import Foundation

/// A second opinion on an export, from a tool that shares no code with Make It 3D.
///
/// Every other check in the verification report reads back metadata that Make It 3D
/// itself wrote, using the same frameworks Make It 3D used to write it. That proves
/// the values round trip; it does not prove they are the values another reader
/// would find. Mike Swanson's `spatial` tool is an independent implementation,
/// so agreement between the two is worth more than either alone.
///
/// Optional by design. The tool is a convenience, not a dependency, and its
/// absence is reported rather than treated as a failure.
enum SpatialCLI {

    /// Homebrew's location first, then anywhere else on PATH.
    static var executableURL: URL? {
        let candidates = [
            "/opt/homebrew/bin/spatial",
            "/usr/local/bin/spatial"
        ].map { URL(fileURLWithPath: $0) }

        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return found
        }
        return which("spatial")
    }

    static var isInstalled: Bool { executableURL != nil }

    /// What `spatial info` reports about a file.
    struct Reading {
        let hasLeftEye: Bool
        let hasRightEye: Bool
        let heroEye: String?
        let baselineMillimetres: Double?
        let fieldOfViewDegrees: Double?
        let disparityAdjustment: Double?
        let projection: String?
        let raw: String
    }

    /// Runs `spatial info` and parses what comes back. nil when the tool is not
    /// installed or would not run.
    static func read(_ url: URL) -> Reading? {
        guard let executableURL else { return nil }

        guard let text = run(executableURL, arguments: ["info", "-i", url.path]) else { return nil }

        return Reading(
            hasLeftEye: text.contains("Has left eye"),
            hasRightEye: text.contains("Has right eye"),
            heroEye: value(after: "Hero eye:", in: text),
            baselineMillimetres: number(after: "Camera distance:", in: text),
            fieldOfViewDegrees: number(after: "Horizontal field-of-view:", in: text),
            disparityAdjustment: number(after: "Horizontal disparity adjustment:", in: text),
            projection: value(after: "Projection:", in: text),
            raw: text
        )
    }

    /// Turns a reading into a verification check, comparing it against what
    /// Make It 3D intended to write.
    static func verify(
        _ url: URL,
        tuning: EngineTuning = .default
    ) -> VerificationReport.Check? {
        guard isInstalled else {
            return VerificationReport.Check(
                name: "Independent reader",
                passed: true,
                detail: "spatial CLI not installed. Install with: brew install spatial",
                skipped: true
            )
        }

        guard let reading = read(url) else {
            return VerificationReport.Check(
                name: "Independent reader",
                passed: false,
                detail: "the spatial CLI could not read this file"
            )
        }

        var mismatches: [String] = []
        if !reading.hasLeftEye { mismatches.append("no left eye") }
        if !reading.hasRightEye { mismatches.append("no right eye") }

        if let baseline = reading.baselineMillimetres,
           abs(baseline - tuning.baselineMillimetres) > 0.05 {
            mismatches.append(
                String(format: "baseline %.1fmm, expected %.1fmm", baseline, tuning.baselineMillimetres)
            )
        }
        if let fov = reading.fieldOfViewDegrees,
           abs(fov - tuning.horizontalFOVDegrees) > 0.05 {
            mismatches.append(
                String(format: "FOV %.1f deg, expected %.1f deg", fov, tuning.horizontalFOVDegrees)
            )
        }
        if let adjustment = reading.disparityAdjustment,
           abs(adjustment - tuning.horizontalDisparityAdjustment) > 0.0005 {
            mismatches.append(
                String(
                    format: "disparity adjustment %.4f, expected %.4f",
                    adjustment, tuning.horizontalDisparityAdjustment
                )
            )
        }
        if let projection = reading.projection, projection.lowercased() != "rectilinear" {
            mismatches.append("projection \(projection)")
        }

        guard mismatches.isEmpty else {
            return VerificationReport.Check(
                name: "Independent reader",
                passed: false,
                detail: "spatial CLI disagrees: \(mismatches.joined(separator: ", "))"
            )
        }

        var agreed = ["both eyes"]
        if let hero = reading.heroEye { agreed.append("hero eye \(hero)") }
        if let baseline = reading.baselineMillimetres {
            agreed.append(String(format: "baseline %.1fmm", baseline))
        }
        if let fov = reading.fieldOfViewDegrees {
            agreed.append(String(format: "FOV %.1f deg", fov))
        }
        if let projection = reading.projection { agreed.append(projection) }

        return VerificationReport.Check(
            name: "Independent reader",
            passed: true,
            detail: "spatial CLI agrees: \(agreed.joined(separator: ", "))"
        )
    }

    // MARK: Parsing

    private static func value(after label: String, in text: String) -> String? {
        for line in text.split(separator: "\n") where line.contains(label) {
            let remainder = line.replacingOccurrences(of: label, with: "")
            let trimmed = remainder.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Pulls the leading number out of a value like "19.2mm" or "63.4 degrees".
    private static func number(after label: String, in text: String) -> Double? {
        guard let raw = value(after: label, in: text) else { return nil }
        let digits = raw.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(digits)
    }

    private static func which(_ tool: String) -> URL? {
        guard let path = run(URL(fileURLWithPath: "/usr/bin/env"), arguments: ["which", tool])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Files keep stdout/stderr from filling a pipe and deadlocking verification.
    /// An external reader is useful evidence, but cannot hold an export forever.
    private static func run(_ executable: URL, arguments: [String]) -> String? {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("spatial-\(UUID()).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        guard let handle = try? FileHandle(forWritingTo: log) else { return nil }
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning {
            if Task.isCancelled || Date() >= deadline {
                process.terminate()
                return nil
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: log) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
