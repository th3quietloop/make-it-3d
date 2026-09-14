import Foundation
import Darwin

/// A deliberately narrow ZIP reader: validates central and local records before
/// handing a verified, bounded archive to the system extractor.
enum ModelArchive {
    static let maximumDownloadBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    static let maximumExpandedBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
    static let maximumEntries = 20_000

    struct Entry: Sendable {
        let path: String
        let isDirectory: Bool
        let size: UInt64
    }

    static func inspect(_ url: URL) throws -> [Entry] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        func invalid(_ detail: String) -> DepthEstimatorError {
            .modelLoadFailed("The model ZIP is not supported: \(detail)")
        }
        func u16(_ offset: Int) throws -> UInt16 {
            guard offset >= 0, offset <= data.count - 2 else { throw invalid("truncated record.") }
            return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> UInt32 {
            UInt32(try u16(offset)) | UInt32(try u16(offset + 2)) << 16
        }
        func name(_ offset: Int, _ length: Int) throws -> String {
            guard offset >= 0, length > 0, offset <= data.count - length,
                  let result = String(data: data[offset..<(offset + length)], encoding: .utf8) else {
                throw invalid("invalid UTF-8 entry name.")
            }
            return result
        }
        func checkExtras(_ start: Int, _ length: Int) throws {
            guard start <= data.count - length else { throw invalid("truncated extra fields.") }
            var cursor = start
            while cursor < start + length {
                let identifier = try u16(cursor), size = Int(try u16(cursor + 2))
                // Permit timestamps and Unix owner IDs only. In particular,
                // Unicode-path and Unix-link extras can override safe names.
                let supported = [0x5455, 0x000a, 0x7875].contains(identifier)
                    || (identifier == 0x5855 && [8, 12].contains(size))
                guard cursor + 4 + size <= start + length, supported else {
                    throw invalid("ZIP64, path overrides, or unsupported extra fields.")
                }
                cursor += 4 + size
            }
        }
        guard data.count >= 22, Int64(data.count) <= maximumDownloadBytes else {
            throw invalid("archive size is outside the supported limit.")
        }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try u32(offset) == 0x06054b50,
               offset + 22 + Int(try u16(offset + 20)) == data.count {
                end = offset
                break
            }
        }
        guard let end else { throw invalid("missing end record.") }
        let count = Int(try u16(end + 10)), centralSize = Int(try u32(end + 12))
        let centralStart = Int(try u32(end + 16))
        guard try u16(end + 4) == 0, try u16(end + 6) == 0,
              Int(try u16(end + 8)) == count, count > 0, count <= maximumEntries,
              centralStart + centralSize == end else {
            throw invalid("multipart, ZIP64, or excessive entries.")
        }
        var cursor = centralStart, total: UInt64 = 0
        var result: [Entry] = []
        var names: [String: Bool] = [:]
        var intervals: [Range<Int>] = []
        for _ in 0..<count {
            try Task.checkCancellation()
            guard try u32(cursor) == 0x02014b50 else { throw invalid("invalid central record.") }
            let flags = try u16(cursor + 8), method = try u16(cursor + 10)
            let compressed = Int(try u32(cursor + 20)), expanded = UInt64(try u32(cursor + 24))
            let nameLength = Int(try u16(cursor + 28)), extraLength = Int(try u16(cursor + 30))
            let commentLength = Int(try u16(cursor + 32)), local = Int(try u32(cursor + 42))
            let attributes = try u32(cursor + 38), mode = (attributes >> 16) & 0xf000
            guard flags & 0x2041 == 0, [0, 8].contains(method), try u16(cursor + 34) == 0,
                  [0, 0x4000, 0x8000].contains(mode),
                  compressed != Int(UInt32.max), expanded != UInt64(UInt32.max) else {
                throw invalid("encrypted, linked, special, or unsupported entries.")
            }
            let path = try name(cursor + 46, nameLength)
            let isDirectory = path.hasSuffix("/")
            let clean = isDirectory ? String(path.dropLast()) : path
            let components = clean.split(separator: "/", omittingEmptySubsequences: false)
            guard !clean.isEmpty, clean.utf8.count <= 1_024, components.count <= 16,
                  !path.contains("\\"), !path.contains(":"), !path.contains("\0"),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  mode != 0x4000 || isDirectory, mode != 0x8000 || !isDirectory,
                  !isDirectory || (expanded == 0 && compressed == 0) else {
                throw invalid("unsafe entry path or directory.")
            }
            let key = clean.precomposedStringWithCanonicalMapping.lowercased()
            guard names[key] == nil else { throw invalid("duplicate or case-colliding paths.") }
            names[key] = isDirectory
            total += expanded
            guard total <= maximumExpandedBytes else { throw invalid("expanded size exceeds 8 GiB.") }
            try checkExtras(cursor + 46 + nameLength, extraLength)
            guard try u32(local) == 0x04034b50, try u16(local + 6) == flags,
                  try u16(local + 8) == method else { throw invalid("mismatched local record.") }
            let localNameLength = Int(try u16(local + 26)), localExtraLength = Int(try u16(local + 28))
            guard try name(local + 30, localNameLength) == path else { throw invalid("mismatched entry names.") }
            try checkExtras(local + 30 + localNameLength, localExtraLength)
            for (localField, centralField) in [(14, 16), (18, 20), (22, 24)] {
                let value = try u32(local + localField)
                guard value == (try u32(cursor + centralField)) || (flags & 8 != 0 && value == 0) else {
                    throw invalid("mismatched entry sizes or checksum.")
                }
            }
            let contentStart = local + 30 + localNameLength + localExtraLength
            guard local >= 0, contentStart + compressed <= centralStart else { throw invalid("overlapping archive records.") }
            intervals.append(local..<(contentStart + compressed))
            result.append(Entry(path: clean, isDirectory: isDirectory, size: expanded))
            cursor += 46 + nameLength + extraLength + commentLength
            guard cursor <= end else { throw invalid("central record exceeds archive.") }
        }
        guard cursor == end else { throw invalid("unexpected central records.") }
        intervals.sort { $0.lowerBound < $1.lowerBound }
        for index in 1..<intervals.count where intervals[index - 1].upperBound > intervals[index].lowerBound {
            throw invalid("overlapping entry content.")
        }
        for key in names.keys {
            var parent = key
            while let slash = parent.lastIndex(of: "/") {
                parent = String(parent[..<slash])
                if names[parent] == false { throw invalid("a file is also used as a directory.") }
            }
        }
        return result
    }

    static func extract(_ archive: URL, into directory: URL, entries: [Entry]) async throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage,
           available < Int64(entries.reduce(UInt64(0)) { $0 + $1.size }) + 512 * 1_024 * 1_024 {
            throw DepthEstimatorError.modelLoadFailed("There isn't enough free space to extract this model.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["--norsrc", "--noextattr", "--noacl", "-x", "-k", archive.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let expectedFiles = Dictionary(uniqueKeysWithValues: entries.filter { !$0.isDirectory }.map { ($0.path, $0.size) })
        try process.run()
        do {
            let deadline = Date().addingTimeInterval(300)
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw DepthEstimatorError.modelLoadFailed("Model extraction timed out.") }
                try checkExtractionLimits(in: directory, expectedFiles: expectedFiles)
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw error
        }
        guard process.terminationStatus == 0 else {
            throw DepthEstimatorError.modelLoadFailed("The model ZIP could not be extracted.")
        }
        return try extractedModel(in: directory, entries: entries)
    }

    /// Checks actual writes as well as advertised ZIP sizes, so a dishonest
    /// expanded-size field cannot silently fill the destination volume.
    private static func checkExtractionLimits(in directory: URL, expectedFiles: [String: UInt64]) throws {
        let root = directory.resolvingSymlinksInPath().path + "/"
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        let totalLimit = expectedFiles.values.reduce(UInt64(0), +)
        var actualTotal: UInt64 = 0
        for case let url as URL in enumerator {
            let properties = try url.resourceValues(forKeys: keys)
            guard properties.isSymbolicLink != true else {
                throw DepthEstimatorError.modelLoadFailed("A link appeared while extracting the model.")
            }
            if properties.isRegularFile == true {
                let path = url.resolvingSymlinksInPath().path
                guard path.hasPrefix(root) else { throw DepthEstimatorError.modelLoadFailed("An extracted file escaped the model folder.") }
                let relative = String(path.dropFirst(root.count))
                // ditto first writes each file to a .BC.T_ sibling, then renames
                // it. Bound that transient file by its directory's largest entry.
                var maximum = expectedFiles[relative]
                if maximum == nil, url.lastPathComponent.hasPrefix(".BC.T_") {
                    let parent = (relative as NSString).deletingLastPathComponent
                    maximum = expectedFiles.filter { ($0.key as NSString).deletingLastPathComponent == parent }.values.max()
                }
                guard let maximum, let actual = properties.fileSize,
                      actual >= 0, UInt64(actual) <= maximum else {
                    throw DepthEstimatorError.modelLoadFailed("Extracted file '\(relative)' exceeded its verified size.")
                }
                actualTotal += UInt64(actual)
                guard actualTotal <= totalLimit else { throw DepthEstimatorError.modelLoadFailed("Model extraction exceeded its verified total size.") }
            }
        }
    }

    private static func extractedModel(in directory: URL, entries: [Entry]) throws -> URL {
        let manager = FileManager.default
        let root = directory.resolvingSymlinksInPath().path + "/"
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else {
            throw DepthEstimatorError.modelLoadFailed("The extracted model could not be inspected.")
        }
        let files = Dictionary(uniqueKeysWithValues: entries.filter { !$0.isDirectory }.map { ($0.path, $0.size) })
        var seen: Set<String> = [], models: [URL] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let properties = try url.resourceValues(forKeys: keys)
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(root) else { throw DepthEstimatorError.modelLoadFailed("An extracted file escaped the model folder.") }
            let relative = String(path.dropFirst(root.count))
            guard properties.isSymbolicLink != true,
                  properties.isRegularFile == true || properties.isDirectory == true else {
                throw DepthEstimatorError.modelLoadFailed("The extracted model contains a link or special file.")
            }
            if properties.isRegularFile == true {
                guard let expected = files[relative], let actual = properties.fileSize,
                      actual >= 0, UInt64(actual) == expected else {
                    throw DepthEstimatorError.modelLoadFailed("Extracted file '\(relative)' does not match the verified archive size.")
                }
                seen.insert(relative)
            }
            if properties.isDirectory == true, ["mlpackage", "mlmodelc"].contains(url.pathExtension.lowercased()),
               !relative.split(separator: "/").contains("__MACOSX"),
               !models.contains(where: { url.path.hasPrefix($0.path + "/") }) { models.append(url) }
        }
        guard seen.count == files.count, models.count == 1 else {
            throw DepthEstimatorError.modelLoadFailed("The ZIP must contain exactly one complete .mlpackage or .mlmodelc model.")
        }
        return models[0]
    }
}

final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double?) -> Void
    init(progress: @escaping @Sendable (Double?) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > ModelArchive.maximumDownloadBytes ||
            totalBytesExpectedToWrite > ModelArchive.maximumDownloadBytes { downloadTask.cancel(); return }
        progress(totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }
}
