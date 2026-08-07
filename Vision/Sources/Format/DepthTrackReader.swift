import AVFoundation
import CoreMedia
import Foundation

enum DepthTrackReaderError: LocalizedError {
    case noVideoTrack
    case depthSizeMismatch(expected: String, found: String)
    case readerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "There is no video in this file."
        case .depthSizeMismatch(let expected, let found):
            return """
                This file's depth track is \(found) where the format says \(expected). \
                It was written by something that does not speak this format.
                """
        case .readerFailed(let detail):
            return "Couldn't read this file. \(detail)"
        }
    }
}

/// What the player knows about a file before it plays a frame of it.
///
/// A file with no depth track is not an error. Every file Make It 3D has ever
/// written has to open, and the ones written before the depth track existed are
/// ordinary MV-HEVC. Those arrive here with `depth` nil and the dial disabled.
struct DepthTrackFile: Sendable {

    struct DepthTrackInfo: Sendable {
        let trackID: CMPersistentTrackID
        let width: Int
        let height: Int
        /// One entry per shot, in order, covering the duration.
        let shots: [Shot]
    }

    let url: URL
    let colorTrackID: CMPersistentTrackID
    let width: Int
    let height: Int
    let frameRate: Double
    let duration: CMTime
    let hasAudio: Bool
    let depth: DepthTrackInfo?

    var hasDepthTrack: Bool { depth != nil }

    /// Why the dial is off, in the language of the person holding the headset.
    /// Nil when the dial works.
    var dialDisabledReason: String? {
        if depth == nil {
            return "This file has no depth track, so its depth is already baked in."
        }
        if depth?.shots.isEmpty == true {
            return "This file has depth but no shot readings, so there is nothing to start from."
        }
        return nil
    }

    /// The shot covering a moment, or the nearest one before it.
    ///
    /// Nearest before rather than nil, because a metadata track can leave a
    /// hairline gap at a cut and a player that answers "no shot" for one frame
    /// flashes.
    func shot(at time: CMTime) -> Shot? {
        guard let shots = depth?.shots, !shots.isEmpty else { return nil }
        var best: Shot?
        for shot in shots {
            if shot.timeRange.containsTime(time) { return shot }
            if shot.timeRange.start <= time { best = shot }
        }
        return best ?? shots.first
    }
}

enum DepthTrackReader {

    /// Opens a file and reads everything static about it.
    ///
    /// Track roles come from order, which is the contract: the first video
    /// track is the colour, the second is the depth. The depth track's size is
    /// then checked against what the format says it must be, so a file written
    /// by something that got the halving wrong is rejected loudly here rather
    /// than sampled wrongly for two hours.
    static func open(url: URL) async throws -> DepthTrackFile {
        let asset = AVURLAsset(url: url)

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let colorTrack = videoTracks.first else { throw DepthTrackReaderError.noVideoTrack }

        let duration = try await asset.load(.duration)
        let naturalSize = try await colorTrack.load(.naturalSize)
        let transform = try await colorTrack.load(.preferredTransform)
        let nominalRate = try await colorTrack.load(.nominalFrameRate)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        // A rotated track reports its pre transform size, so apply the
        // transform to get the size the viewer will actually see.
        let displaySize = naturalSize.applying(transform)
        let width = Int(abs(displaySize.width).rounded())
        let height = Int(abs(displaySize.height).rounded())
        guard width > 0, height > 0 else {
            throw DepthTrackReaderError.readerFailed("The video track has no size.")
        }

        let marked = try await isMarked(asset: asset)
        var depthInfo: DepthTrackFile.DepthTrackInfo?

        if videoTracks.count >= 2 {
            let depthTrack = videoTracks[1]
            let depthSize = try await depthTrack.load(.naturalSize)
            let depthWidth = Int(abs(depthSize.width).rounded())
            let depthHeight = Int(abs(depthSize.height).rounded())
            let expected = DepthTrack.depthSize(forSourceWidth: width, height: height)

            guard depthWidth == expected.width, depthHeight == expected.height else {
                throw DepthTrackReaderError.depthSizeMismatch(
                    expected: "\(expected.width) x \(expected.height)",
                    found: "\(depthWidth) x \(depthHeight)"
                )
            }

            let shots = try await readShots(asset: asset)
            depthInfo = DepthTrackFile.DepthTrackInfo(
                trackID: depthTrack.trackID,
                width: depthWidth,
                height: depthHeight,
                shots: shots
            )
        }

        // The marker exists so a player can skip the probing above. It is not
        // the authority on whether a depth track is present: a second video
        // track of the right size is. Disagreement means the file is damaged,
        // and it is worth saying so rather than quietly trusting one of them.
        if marked && depthInfo == nil {
            throw DepthTrackReaderError.readerFailed(
                "This file says it carries a depth track but does not have one."
            )
        }

        return DepthTrackFile(
            url: url,
            colorTrackID: colorTrack.trackID,
            width: width,
            height: height,
            frameRate: nominalRate > 0 ? Double(nominalRate) : 30,
            duration: duration,
            hasAudio: !audioTracks.isEmpty,
            depth: depthInfo
        )
    }

    /// True when the top level marker is present.
    static func isMarked(asset: AVAsset) async throws -> Bool {
        let metadata = try await asset.load(.metadata)
        let items = AVMetadataItem.metadataItems(
            from: metadata, filteredByIdentifier: DepthTrack.markerIdentifier
        )
        guard let item = items.first else { return false }
        if let number = try await item.load(.numberValue) { return number.intValue >= 1 }
        if let text = try await item.load(.stringValue) { return Int(text) ?? 0 >= 1 }
        return false
    }

    /// Reads the whole timed metadata track into memory.
    ///
    /// One sample per shot means this is tens of entries for a feature, not
    /// tens of thousands, so reading it once up front is cheaper and far more
    /// predictable than streaming it during playback and hoping a sample
    /// arrives before the cut it describes.
    static func readShots(asset: AVAsset) async throws -> [Shot] {
        let tracks = try await asset.loadTracks(withMediaType: .metadata)
        guard let track = tracks.first else { return [] }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw DepthTrackReaderError.readerFailed(error.localizedDescription)
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else {
            throw DepthTrackReaderError.readerFailed("The shot metadata track could not be opened.")
        }
        reader.add(output)
        let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)

        guard reader.startReading() else {
            throw DepthTrackReaderError.readerFailed(
                reader.error?.localizedDescription ?? "The reader would not start."
            )
        }

        var shots: [Shot] = []
        while let group = adaptor.nextTimedMetadataGroup() {
            let items = AVMetadataItem.metadataItems(
                from: group.items, filteredByIdentifier: DepthTrack.shotIdentifier
            )
            for item in items {
                let text = try await item.load(.stringValue)
                guard let text, let data = text.data(using: .utf8) else { continue }
                guard let metadata = try? ShotMetadata.decode(from: data) else {
                    throw DepthTrackReaderError.readerFailed(
                        "A shot's metadata is not the JSON this format describes."
                    )
                }
                shots.append(Shot(timeRange: group.timeRange, metadata: metadata))
            }
        }

        if reader.status == .failed {
            throw DepthTrackReaderError.readerFailed(
                reader.error?.localizedDescription ?? "Reading the shot metadata stopped."
            )
        }

        return shots.sorted { $0.timeRange.start < $1.timeRange.start }
    }
}
