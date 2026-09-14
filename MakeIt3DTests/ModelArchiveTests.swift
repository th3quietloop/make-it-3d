import XCTest
import CryptoKit
@testable import MakeIt3D

final class ModelArchiveTests: XCTestCase {
    func testValidArchiveAndExtraction() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("model.zip")
        let payload = Data("model fixture".utf8)
        try zip(path: "Sample.mlmodelc/weights.bin", payload: payload).write(to: archive)
        let entries = try ModelArchive.inspect(archive)
        XCTAssertEqual(entries.count, 1)
        let model = try await ModelArchive.extract(archive,
            into: directory.appendingPathComponent("extracted"), entries: entries)
        XCTAssertEqual(model.lastPathComponent, "Sample.mlmodelc")
        XCTAssertEqual(try Data(contentsOf: model.appendingPathComponent("weights.bin")), payload)
    }

    func testUnsafeArchiveNamesAndSymlinksAreRejected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for path in ["../escape", "/absolute", "model/../../escape", "model\\escape", "model//file", "model/./file", "C:escape"] {
            let archive = directory.appendingPathComponent(UUID().uuidString)
            try zip(path: path).write(to: archive)
            XCTAssertThrowsError(try ModelArchive.inspect(archive), path)
        }
        let archive = directory.appendingPathComponent("link.zip")
        try zip(path: "Model.mlmodelc/link", mode: 0xa1ff).write(to: archive)
        XCTAssertThrowsError(try ModelArchive.inspect(archive))
    }

    func testMismatchedLocalNameAndEncryptedArchiveAreRejected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("bad.zip")
        var mismatch = zip(path: "Model.mlmodelc/file")
        mismatch[30] = UInt8(ascii: "X")
        try mismatch.write(to: archive)
        XCTAssertThrowsError(try ModelArchive.inspect(archive))
        try zip(path: "Model.mlmodelc/file", flags: 1).write(to: archive)
        XCTAssertThrowsError(try ModelArchive.inspect(archive))
    }

    func testMalformedZIPAndExpandedLimitAreRejected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("bad.zip")
        try Data("not a ZIP".utf8).write(to: archive)
        XCTAssertThrowsError(try ModelArchive.inspect(archive))
        // ZIP64's size sentinel must be rejected even for a tiny physical file.
        var oversized = zip(path: "Model.mlmodelc/file")
        oversized.replaceSubrange(22..<26, with: [255, 255, 255, 255])
        let central = oversized.count - 22 - 46 - "Model.mlmodelc/file".utf8.count
        oversized.replaceSubrange((central + 24)..<(central + 28), with: [255, 255, 255, 255])
        try oversized.write(to: archive)
        XCTAssertThrowsError(try ModelArchive.inspect(archive))
    }

    func testWrongChecksumKeepsActiveModel() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("model.zip")
        try zip(path: "Sample.mlmodelc/weights.bin").write(to: archive)
        let active = directory.appendingPathComponent("active-perFrame.json")
        let previous = Data("previous model".utf8)
        try previous.write(to: active)
        do {
            _ = try await DepthModelStore.installArchive(from: archive,
                expectedSHA256: String(repeating: "0", count: 64), kind: .perFrame,
                storageDirectory: directory)
            XCTFail("A checksum mismatch was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("SHA-256"))
            XCTAssertEqual(try Data(contentsOf: active), previous)
        }
    }

    func testDownloadRequiresHTTPSAndValidChecksumBeforeNetwork() async throws {
        for (source, checksum) in [("http://example.invalid/model.zip", String(repeating: "0", count: 64)),
                                    ("https://example.invalid/model.zip", "bad checksum")] {
            do {
                _ = try await DepthModelStore.downloadAndInstall(from: URL(string: source)!,
                    expectedSHA256: checksum, kind: .perFrame)
                XCTFail("Invalid download input was accepted")
            } catch {
                XCTAssertTrue(error is DepthEstimatorError)
            }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("ModelArchiveTests-\(UUID())")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    private func zip(path: String, mode: UInt32 = 0x81a4, flags: UInt16 = 0,
                     payload: Data = Data([1, 2, 3])) -> Data {
        let name = Data(path.utf8)
        var crc: UInt32 = .max
        for byte in payload {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        }
        crc ^= .max
        var data = Data()
        func put16(_ value: UInt16) { data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8)) }
        func put32(_ value: UInt32) { put16(UInt16(truncatingIfNeeded: value)); put16(UInt16(truncatingIfNeeded: value >> 16)) }
        put32(0x04034b50); put16(20); put16(flags); put16(0); put16(0); put16(0)
        put32(crc); put32(UInt32(payload.count)); put32(UInt32(payload.count)); put16(UInt16(name.count)); put16(0)
        data.append(name); data.append(payload)
        let centralStart = data.count
        put32(0x02014b50); put16(0x0314); put16(20); put16(flags); put16(0); put16(0); put16(0)
        put32(crc); put32(UInt32(payload.count)); put32(UInt32(payload.count)); put16(UInt16(name.count))
        put16(0); put16(0); put16(0); put16(0); put32(mode << 16); put32(0); data.append(name)
        let centralSize = data.count - centralStart
        put32(0x06054b50); put16(0); put16(0); put16(1); put16(1)
        put32(UInt32(centralSize)); put32(UInt32(centralStart)); put16(0)
        return data
    }
}
