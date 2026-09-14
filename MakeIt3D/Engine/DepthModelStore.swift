import Foundation
import CoreML
import CoreVideo
import CryptoKit

/// Local, explicitly imported models. A model is copied, compiled, checked and
/// exercised before its activation record is changed. Built-in models remain intact.
enum DepthModelStore {
    struct InstalledModel: Codable, Sendable {
        let kind: EngineTuning.DepthModel
        let displayName: String
        let checksum: String
        let validatedAt: Date
        let inferenceSeconds: Double
        let inputWidth: Int
        let inputHeight: Int
        let relativePath: String
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MakeIt3D/Models", isDirectory: true)
    }

    private static func recordURL(_ kind: EngineTuning.DepthModel) -> URL {
        directory.appendingPathComponent("active-\(kind.rawValue).json")
    }

    static func installedModel(for kind: EngineTuning.DepthModel) -> InstalledModel? {
        guard let data = try? Data(contentsOf: recordURL(kind)),
              let record = try? JSONDecoder().decode(InstalledModel.self, from: data),
              record.kind == kind, !record.relativePath.contains("/"),
              !record.relativePath.contains(".."),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent(record.relativePath).path) else {
            return nil
        }
        return record
    }

    static func activeModelURL(for kind: EngineTuning.DepthModel) -> URL? {
        installedModel(for: kind).map { directory.appendingPathComponent($0.relativePath) }
    }

    static func useBuiltInModel(for kind: EngineTuning.DepthModel) throws {
        let record = recordURL(kind)
        if FileManager.default.fileExists(atPath: record.path) {
            try FileManager.default.removeItem(at: record)
        }
    }

    /// Downloads only a user-selected HTTPS ZIP with a separately supplied
    /// SHA-256. `nil` progress means archive checks or model inference are running.
    static func downloadAndInstall(from source: URL, expectedSHA256: String,
        kind: EngineTuning.DepthModel,
        computePreference: EngineTuning.ComputePreference = .automatic,
        progress: @escaping @Sendable (Double?) -> Void = { _ in },
        storageDirectory: URL? = nil) async throws -> InstalledModel {
        guard source.scheme?.lowercased() == "https", source.host != nil,
              source.user == nil, source.password == nil else {
            throw DepthEstimatorError.modelLoadFailed("Use an HTTPS model ZIP URL without embedded credentials.")
        }
        _ = try validatedChecksum(expectedSHA256)
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3_600
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        progress(0)
        let delegate = ModelDownloadDelegate(progress: progress)
        let (archive, response) = try await session.download(from: source, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: archive) }
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
              response.url?.scheme?.lowercased() == "https" else {
            throw DepthEstimatorError.modelLoadFailed("The model server did not return a successful HTTPS download.")
        }
        progress(nil)
        return try await installArchive(from: archive, expectedSHA256: expectedSHA256, kind: kind,
            computePreference: computePreference, storageDirectory: storageDirectory)
    }

    static func installArchive(from archive: URL, expectedSHA256: String,
        kind: EngineTuning.DepthModel,
        computePreference: EngineTuning.ComputePreference = .automatic,
        storageDirectory: URL? = nil) async throws -> InstalledModel {
        let expected = try validatedChecksum(expectedSHA256)
        let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, Int64(size) <= ModelArchive.maximumDownloadBytes else {
            throw DepthEstimatorError.modelLoadFailed("The model ZIP must be smaller than 2 GiB.")
        }
        var hash = SHA256()
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw DepthEstimatorError.modelLoadFailed("The downloaded ZIP does not match the supplied SHA-256. The active model was kept.")
        }
        let entries = try ModelArchive.inspect(archive)
        let extraction = FileManager.default.temporaryDirectory.appendingPathComponent("DepthModel-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: extraction) }
        let model = try await ModelArchive.extract(archive, into: extraction, entries: entries)
        return try await install(from: model, kind: kind, computePreference: computePreference,
                                 storageDirectory: storageDirectory)
    }

    private static func validatedChecksum(_ value: String) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard clean.count == 64, clean.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw DepthEstimatorError.modelLoadFailed("Enter the distributor's 64-character SHA-256 for this ZIP.")
        }
        return clean
    }

    static func install(from source: URL, kind: EngineTuning.DepthModel,
                        computePreference: EngineTuning.ComputePreference = .automatic,
                        storageDirectory: URL? = nil) async throws -> InstalledModel {
        guard ["mlpackage", "mlmodelc"].contains(source.pathExtension.lowercased()) else {
            throw DepthEstimatorError.modelLoadFailed("Choose a Core ML .mlpackage or .mlmodelc folder.")
        }
        try Task.checkCancellation()
        let directory = storageDirectory ?? Self.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identifier = UUID().uuidString
        let staged = directory.appendingPathComponent(".\(identifier).mlmodelc", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staged) }
        let compiled: URL
        var temporaryCompilation: URL?
        defer { if let temporaryCompilation { try? FileManager.default.removeItem(at: temporaryCompilation) } }
        if source.pathExtension.lowercased() == "mlpackage" {
            compiled = try await MLModel.compileModel(at: source)
            temporaryCompilation = compiled
        } else { compiled = source }
        try FileManager.default.copyItem(at: compiled, to: staged)
        let sample = try calibrationFrame()
        var inferenceSeconds = 0.0
        let input: (width: Int, height: Int)
        let maps: [NearnessMap]
        switch kind {
        case .perFrame:
            let estimator = try CoreMLDepthEstimator(modelURL: staged, computePreference: computePreference)
            input = estimator.inputSize
            let began = Date()
            maps = [try estimator.nearness(from: sample)]
            inferenceSeconds = Date().timeIntervalSince(began)
        case .video:
            let estimator = try VideoDepthEstimator(modelURL: staged, computePreference: computePreference)
            input = estimator.inputSize
            let began = Date()
            maps = try estimator.nearness(forWindow: [CVPixelBuffer](repeating: sample, count: estimator.windowLength))
            inferenceSeconds = Date().timeIntervalSince(began)
        }
        guard !maps.isEmpty, maps.allSatisfy({ map in
            map.width > 0 && map.height > 0 && map.values.count == map.width * map.height
                && map.values.allSatisfy(\.isFinite)
        }) else {
            throw DepthEstimatorError.inferenceFailed("The imported model did not produce a finite depth plane.")
        }
        try Task.checkCancellation()
        let record = InstalledModel(kind: kind, displayName: source.deletingPathExtension().lastPathComponent,
            checksum: try checksum(of: staged), validatedAt: Date(),
            inferenceSeconds: inferenceSeconds, inputWidth: input.width, inputHeight: input.height,
            relativePath: "\(identifier).mlmodelc")
        let destination = directory.appendingPathComponent(record.relativePath, isDirectory: true)
        try FileManager.default.moveItem(at: staged, to: destination)
        do {
            try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("active-\(kind.rawValue).json"), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return record
    }

    private static func checksum(of url: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(at: url,
            includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw DepthEstimatorError.modelLoadFailed("The copied model could not be inspected.")
        }
        let files = enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.path < $1.path }
        var hash = SHA256()
        for file in files {
            try Task.checkCancellation()
            hash.update(data: Data(file.path.replacingOccurrences(of: url.path, with: "").utf8))
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let data = try handle.read(upToCount: 65_536), !data.isEmpty { hash.update(data: data) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func calibrationFrame() throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 256, 192, Ingest.pixelFormat,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result)
        guard status == kCVReturnSuccess, let result else {
            throw DepthEstimatorError.inferenceFailed("Couldn't create the model validation frame.")
        }
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        guard let base = CVPixelBufferGetBaseAddress(result) else {
            throw DepthEstimatorError.inferenceFailed("Couldn't address the model validation frame.")
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(result)
        for y in 0..<192 {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<256 {
                row[x * 4] = UInt8(x)
                row[x * 4 + 1] = UInt8(y)
                row[x * 4 + 2] = x > 80 && x < 176 && y > 48 && y < 144 ? 230 : 40
                row[x * 4 + 3] = 255
            }
        }
        return result
    }
}
