import Foundation

/// One measured claim about the build.
///
/// Every check in this folder returns one of these. None of them return an
/// opinion: `detail` always carries the numbers the verdict was reached on, so
/// a failure tells you what happened rather than that something happened.
struct CheckResult: Sendable {
    let name: String
    let passed: Bool
    let detail: String

    var line: String {
        "\(passed ? "PASS" : "FAIL")  \(name): \(detail)"
    }

    static func pass(_ name: String, _ detail: String) -> CheckResult {
        CheckResult(name: name, passed: true, detail: detail)
    }

    static func fail(_ name: String, _ detail: String) -> CheckResult {
        CheckResult(name: name, passed: false, detail: detail)
    }
}

/// Thrown when a check cannot reach a verdict at all, which is different from
/// reaching a failing one and has to be reported differently.
struct CheckAborted: LocalizedError {
    let check: String
    let reason: String

    var errorDescription: String? {
        "\(check) could not run: \(reason)"
    }
}
