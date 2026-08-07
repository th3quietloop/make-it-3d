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
    static let spec = DepthTrackSpec(
        width: 1920,
        height: 1080,
        frameRate: 30,
        frameCount: 450,
        includeTone: true
    )

    static var url: URL {
        URL.documentsDirectory.appending(path: "MakeIt3D Test Clip.mov")
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
