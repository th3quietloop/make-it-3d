import Foundation

/// The synthetic depth track file, made on the device that plays it.
///
/// It exists so the app is never blocked on the Mac side, and so there is
/// always one file whose every number is known in advance. It is the regression
/// fixture, and it is also the thing to hand someone who has just put the
/// headset on and wants to see what the dial does.
///
/// Generated into Documents rather than bundled, because a two minute 1080p
/// fixture is tens of megabytes of app for something that can be rebuilt in
/// twenty seconds, and because generating it here proves the writer runs on
/// visionOS rather than only on the Mac.
enum TestClip {

    /// Short enough to write while someone waits, long enough to contain
    /// several cuts, which is what the per shot depth normalization is for.
    ///
    /// The size can be overridden, because the guardrail the PRD sets is 4K per
    /// eye and a fixture that only ever exists at 1080p cannot answer that
    /// question. `MAKEIT3D_TEST_SIZE=4k` writes 3840 by 2160 instead.
    static var spec: DepthTrackSpec {
        let is4K = ProcessInfo.processInfo.environment["MAKEIT3D_TEST_SIZE"]?.lowercased() == "4k"
        return DepthTrackSpec(
            width: is4K ? 3840 : 1920,
            height: is4K ? 2160 : 1080,
            frameRate: 30,
            // Fewer frames at 4K, because the fixture is written on the device
            // and nobody should wait two minutes to find out a frame rate.
            frameCount: is4K ? 180 : 450,
            includeTone: true
        )
    }

    /// Named by size, so the two fixtures can sit side by side rather than one
    /// silently standing in for the other.
    static var url: URL {
        let spec = spec
        return URL.documentsDirectory.appending(
            path: "MakeIt3D Test Clip \(spec.width)x\(spec.height).mov"
        )
    }

    /// Writes it if it is not already there, and returns where it is.
    static func ensureExists() async throws -> URL {
        let url = url
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            return url
        }
        let clip = try SyntheticDepthClip(spec: spec)
        return try await DepthTrackWriter.write(to: url, source: clip)
    }

    /// Forces a rebuild. Used when the format changes underneath a file that is
    /// already on disk, which during a build session is most days.
    static func rebuild() async throws -> URL {
        try? FileManager.default.removeItem(at: url)
        return try await ensureExists()
    }
}
