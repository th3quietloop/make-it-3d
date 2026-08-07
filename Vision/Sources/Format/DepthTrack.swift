import AVFoundation
import CoreMedia
import Foundation

/// The depth track format, frozen by VISIONOS_PRD.md.
///
/// This file is the interface between the Mac app and this one. Both sides are
/// being built in parallel by people who cannot see each other's work, so
/// nothing here changes without the PRD changing first. If a value in this file
/// disagrees with the PRD, the PRD wins and this file is the bug.
///
/// The shape, restated so it is readable without the PRD open:
///
///   Track 1  video      the original 2D source, copied through untouched
///   Track 2  video      the depth map as luminance, half resolution
///   Track 3  metadata   one JSON sample per shot, spanning that shot
///
/// Plus one top level metadata item marking the file as carrying a depth track,
/// so a player can tell without probing every track.
enum DepthTrack {

    // MARK: The contract

    /// Bumped only when the shape of the format changes, never for a value.
    static let formatVersion = 1

    /// The `mdta` key space, which is what a QuickTime `.mov` uses for its
    /// top level and timed metadata.
    static let keySpace = AVMetadataKeySpace.quickTimeMetadata

    /// Top level marker. Present with value 1 means this file has a depth
    /// track. Absent means plain MV-HEVC, which still has to play.
    static let markerKey = "com.russellwhite.makeit3d.depthtrack"
    static let markerIdentifier = AVMetadataIdentifier(rawValue: "mdta/\(markerKey)")

    /// The per shot JSON sample on the timed metadata track.
    static let shotKey = "com.russellwhite.makeit3d.shot"
    static let shotIdentifier = AVMetadataIdentifier(rawValue: "mdta/\(shotKey)")

    /// 0 is the farthest point in the shot, 255 is the nearest, linear between.
    static let farthestLevel: UInt8 = 0
    static let nearestLevel: UInt8 = 255

    /// Depth is stored at source size divided by two, rounded up to even.
    ///
    /// Even matters because every video encoder that ships wants even
    /// dimensions, and an odd one either fails or silently pads. Written as
    /// integer arithmetic rather than a rounded double so the Mac side and this
    /// side cannot disagree by one pixel on some resolution nobody tested.
    static func depthDimension(for source: Int) -> Int {
        precondition(source > 0, "A source dimension of \(source) is not a picture.")
        let half = (source + 1) / 2
        return half.isMultiple(of: 2) ? half : half + 1
    }

    static func depthSize(forSourceWidth width: Int, height: Int) -> (width: Int, height: Int) {
        (depthDimension(for: width), depthDimension(for: height))
    }
}

/// One timed metadata sample: the Mac's reading of one shot.
///
/// The player starts from these and lets the user override them live. They are
/// the Mac's opinion; the dial is the user's.
struct ShotMetadata: Codable, Sendable, Equatable {

    /// Format version, so a future player can refuse a file it does not
    /// understand instead of misreading it.
    var version: Int

    /// Which shot this is, counting from zero at the head of the film.
    var shot: Int

    /// Maps this shot's 0 to 255 back into the film's shared depth space, so a
    /// cut does not flash.
    var depthScale: Double
    var depthOffset: Double

    /// S, as a fraction of frame width. The same S the Mac engine uses.
    var suggestedStrength: Double

    /// C, the nearness that maps to zero disparity.
    var suggestedConvergence: Double

    /// The Mac's own verdict, where 1.0 means exactly on the comfort budget.
    var comfortLoad: Double

    init(
        version: Int = DepthTrack.formatVersion,
        shot: Int,
        depthScale: Double,
        depthOffset: Double,
        suggestedStrength: Double,
        suggestedConvergence: Double,
        comfortLoad: Double
    ) {
        self.version = version
        self.shot = shot
        self.depthScale = depthScale
        self.depthOffset = depthOffset
        self.suggestedStrength = suggestedStrength
        self.suggestedConvergence = suggestedConvergence
        self.comfortLoad = comfortLoad
    }

    /// Encoded exactly as the PRD writes it: flat JSON, no wrapper, no nesting.
    ///
    /// Keys are sorted so a byte comparison of two files with the same values
    /// is meaningful, which is what makes the fixture a regression fixture
    /// rather than a thing that merely parses.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(from data: Data) throws -> ShotMetadata {
        try JSONDecoder().decode(ShotMetadata.self, from: data)
    }
}

/// One shot's place in time, paired with what the Mac said about it.
struct Shot: Sendable, Equatable {
    let timeRange: CMTimeRange
    let metadata: ShotMetadata
}
