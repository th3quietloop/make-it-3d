import Foundation
import CoreMedia

enum PreviewNavigation {
    /// Accepts seconds, m:ss.mmm, or h:mm:ss.mmm. A period always means a
    /// decimal second, never an ambiguous frame number.
    static func seconds(from text: String) -> Double? {
        let components = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count), components.allSatisfy({ !$0.isEmpty }),
              let seconds = Double(components.last!), seconds.isFinite, seconds >= 0 else { return nil }
        if components.count == 1 { return seconds }
        guard seconds < 60, let minutes = Int(components[components.count - 2]), minutes >= 0 else { return nil }
        if components.count == 2 { return Double(minutes) * 60 + seconds }
        guard minutes < 60, let hours = Int(components[0]), hours >= 0 else { return nil }
        let total = Double(hours) * 3600 + Double(minutes) * 60 + seconds
        return total.isFinite ? total : nil
    }

    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 1000) else { return "0:00.000" }
        let milliseconds = Int((seconds * 1000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let remaining = (milliseconds / 1000) % 60
        let fraction = milliseconds % 1000
        if hours > 0 { return String(format: "%d:%02d:%02d.%03d", hours, minutes, remaining, fraction) }
        return String(format: "%d:%02d.%03d", minutes, remaining, fraction)
    }

    static func previousShot(in plan: ShotPlan, at seconds: Double) -> Double? {
        plan.shots.map(\.start.seconds).last { $0 < seconds - 0.05 }
    }

    static func nextShot(in plan: ShotPlan, at seconds: Double) -> Double? {
        plan.shots.map(\.start.seconds).first { $0 > seconds + 0.05 }
    }
}
