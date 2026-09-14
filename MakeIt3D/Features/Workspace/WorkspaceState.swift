import Foundation
import Observation
import CoreMedia
import CryptoKit

struct DepthVariant: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var sourceID: UUID
    var tuning: EngineTuning
    var overrides: DepthOverrides
    var createdAt = Date()
}

struct ExportRecord: Codable, Identifiable {
    var id = UUID()
    var sourceID: UUID
    var title: String
    var outputURL: URL?
    var createdAt = Date()
    var passed: Bool
    var report: String
    var tuning: EngineTuning
    var overrides: DepthOverrides
    var duration: Double
    var proof: Bool
    var proofStart: Double? = nil
    var variantName: String? = nil
    var sourceURL: URL? = nil
    var runID: UUID? = nil
}

struct PerformanceSample: Codable {
    var model: EngineTuning.DepthModel
    var width: Int
    var height: Int
    var frames: Int
    var seconds: Double
    var analysis: Bool
    var date = Date()
    var hardware: String? = Self.currentHardware
    static var currentHardware: String {
        let info = ProcessInfo.processInfo
        return "\(info.processorCount)-\(info.physicalMemory)-\(info.operatingSystemVersion.majorVersion)"
    }
}

struct BatchRecord: Codable, Identifiable {
    var id: UUID
    var createdAt = Date()
    var total: Int
    var completed: Int
    var failed: Int
    var skipped: Int
    var title: String { "\(createdAt.formatted(date: .abbreviated, time: .shortened)) · \(total) videos" }
}

@Observable @MainActor final class WorkspaceState {
    var modelOperationInProgress = false
    var proofProgress: Double?
    var proofError: String?
    var proofLabel: String?
    var proofStale = false
    var variants: [DepthVariant] = []
    var history: [ExportRecord] = []
    var performance: [PerformanceSample] = []
    var batches: [BatchRecord] = []
    var selectedBatchID: UUID?
    var preflightIDs: [UUID] = []
    var preflightScope: QueueRunScope = .selectedSnapshot
    var preflightPresented = false
    var historyPresented = false
    var reviewPresented = false
    var restoredNotice: String?
    var sessionURL: URL?
    var savedAt: Date?
    var saveError: String?
}

/// A versioned, portable description of work. Media remains at its original URL.
struct WorkspaceDocument: Codable {
    var version = 1
    var savedAt = Date()
    var conversions: [SavedConversion]
    var selectionID: UUID?
    var playhead: Double
    var outputFolder: URL
    var filenamePattern: String
    var sidebarVisible: Bool
    var inspectorVisible: Bool
    var variants: [DepthVariant]
    var history: [ExportRecord]
    var performance: [PerformanceSample]
    var batches: [BatchRecord]? = nil
}

struct SavedConversion: Codable {
    var id: UUID
    var sourceURL: URL
    var tuning: EngineTuning
    var overrides: DepthOverrides
    var exportedTuning: EngineTuning?
    var exportedOverrides: DepthOverrides?
    var plan: ShotPlan?
    var exportedPlan: ShotPlan?
    var outputURL: URL?
    var failure: String?
    var interrupted: Bool
    var bookmarks: [Double]
}

/// Atomic, bounded storage. Cache keys include source identity and analysis revision.
enum WorkspaceStorage {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MakeIt3D", isDirectory: true)
    }
    static var autosaveURL: URL { directory.appendingPathComponent("Workspace.json") }
    static var proofsDirectory: URL { directory.appendingPathComponent("Proofs", isDirectory: true) }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    static func analysisURL(source: URL, tuning: EngineTuning) -> URL? {
        guard let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        let data = (try? JSONEncoder().encode(tuning)) ?? Data()
        let model = CoreMLDepthEstimator.bundledModelURL()
        let modelDate = model.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate } ?? .distantPast
        let key = "analysis-v3|\(source.standardizedFileURL.path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(modelDate.timeIntervalSince1970)|\(data.base64EncodedString())"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("Analysis", isDirectory: true).appendingPathComponent(digest).appendingPathExtension("json")
    }
    static func pruneAnalysisCache() {
        let folder = directory.appendingPathComponent("Analysis", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = files.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for url in sorted.dropFirst(150) { try? FileManager.default.removeItem(at: url) }
    }
}

extension Shot: Codable {
    enum CodingKeys: String, CodingKey { case id, start, end, content, settings, motionRisk, edgeRisk, representativeSeconds }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        start = CMTime(seconds: try c.decode(Double.self, forKey: .start), preferredTimescale: 60_000)
        end = CMTime(seconds: try c.decode(Double.self, forKey: .end), preferredTimescale: 60_000)
        content = try c.decode(DepthContent.self, forKey: .content)
        settings = try c.decode(AutoTune.Result.self, forKey: .settings)
        motionRisk = try c.decodeIfPresent(Double.self, forKey: .motionRisk) ?? 0
        edgeRisk = try c.decodeIfPresent(Double.self, forKey: .edgeRisk) ?? 0
        representativeSeconds = try c.decodeIfPresent([Double].self, forKey: .representativeSeconds) ?? []
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(start.seconds, forKey: .start); try c.encode(end.seconds, forKey: .end)
        try c.encode(content, forKey: .content); try c.encode(settings, forKey: .settings)
        try c.encode(motionRisk, forKey: .motionRisk); try c.encode(edgeRisk, forKey: .edgeRisk)
        try c.encode(representativeSeconds, forKey: .representativeSeconds)
    }
}
