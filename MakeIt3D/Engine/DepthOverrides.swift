import Foundation

/// Only explicit user intent is stored here. Auto remains a separate baseline.
struct DepthAdjustment: Codable, Equatable, Sendable {
    var strengthPercent: Double?
    var convergence: Double?
    var followsAutomatic: Bool? = nil
    var automaticStrength: Bool? = nil
    var automaticConvergence: Bool? = nil
    var isEmpty: Bool { strengthPercent == nil && convergence == nil && followsAutomatic != true && automaticStrength != true && automaticConvergence != true }

    func applying(to tuning: EngineTuning) -> EngineTuning {
        var result = tuning
        if let strengthPercent, strengthPercent.isFinite { result.customDisparityPercent = min(max(strengthPercent, 0), 4) }
        if let convergence, convergence.isFinite { result.convergence = min(max(convergence, 0), 1) }
        return result
    }
}

struct DepthOverrides: Codable, Equatable, Sendable {
    var global: DepthAdjustment?
    var shots: [Int: DepthAdjustment] = [:]
    var isEmpty: Bool { (global?.isEmpty ?? true) && shots.values.allSatisfy(\.isEmpty) }

    func applying(to tuning: EngineTuning, shotID: Int?) -> EngineTuning {
        let shot = shotID.flatMap { shots[$0] }
        var base = global?.applying(to: tuning) ?? tuning
        if shot?.followsAutomatic == true || shot?.automaticStrength == true { base.customDisparityPercent = tuning.disparityScale * 100 }
        if shot?.followsAutomatic == true || shot?.automaticConvergence == true { base.convergence = tuning.convergence }
        return shot?.applying(to: base) ?? base
    }
}

enum AdjustmentScope: String, CaseIterable, Identifiable {
    case shot, video
    var id: String { rawValue }
    var label: String { self == .shot ? "This shot" : "Whole video" }
}
