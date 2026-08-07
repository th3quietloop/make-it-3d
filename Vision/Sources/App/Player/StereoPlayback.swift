import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore

/// Playback for one file.
///
/// AVPlayer is the clock, and that is not a shortcut. It owns the audio, the
/// seek, the rate and the buffering, and every one of those is a month of work
/// to do worse by hand. What it does not do is hand back two video tracks, and
/// that is what `PairedFrameCompositor` is for.
///
/// A file with no depth track never gets here. There is nothing to synthesize
/// from, so it goes to RealityKit's own MV-HEVC playback instead and this class
/// is not built at all.
@MainActor
final class StereoPlayback {

    struct PairedFrame {
        let color: CVPixelBuffer
        let depth: CVPixelBuffer
        /// The time the frame will be shown at.
        let time: CMTime
        /// False when the depth came from a neighbouring composition time
        /// rather than this frame's own. Counted rather than hidden, because
        /// that is the shape a drift would take.
        let exactPairing: Bool
    }

    let file: DepthTrackFile
    let player: AVPlayer

    private let item: AVPlayerItem
    private let output: AVPlayerItemVideoOutput
    private let sink: DepthFrameSink

    /// Loops at the end. The fixture is short and the point of it is to watch
    /// the same cut over and over while turning the dial.
    var loops = true

    init(file: DepthTrackFile) throws {
        self.file = file

        let asset = AVURLAsset(url: file.url)
        let (composition, sink) = try PairedComposition.make(for: file)
        self.sink = sink

        item = AVPlayerItem(asset: asset)
        item.videoComposition = composition

        output = AVPlayerItemVideoOutput(outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        // The picture is being drawn by this app, not by a layer, so there is
        // no player rendering to suppress and asking for it back would only
        // make AVFoundation decode twice.
        output.suppressesPlayerRendering = true
        item.add(output)

        player = AVPlayer(playerItem: item)
        // Stop at the end rather than advance to nothing, so the loop below has
        // a stable state to notice.
        player.actionAtItemEnd = .pause
    }

    // MARK: Transport

    /// True when the film has run out.
    ///
    /// Asked once a display frame rather than observed through a notification,
    /// which sounds worse and is better: the loop already runs, a notification
    /// would need a token whose lifetime has to be managed across a deinit that
    /// cannot touch the main actor, and there is nothing here that a poll at
    /// 90 Hz answers late.
    var hasReachedEnd: Bool {
        guard let item = player.currentItem else { return false }
        let duration = item.duration
        guard duration.isNumeric, duration > .zero else { return false }
        return player.rate == 0 && item.currentTime() >= duration - CMTime(value: 1, timescale: 30)
    }

    /// Sends the film back to the start when it has run out and looping is on.
    /// Returns true when it did.
    @discardableResult
    func loopIfFinished() -> Bool {
        guard loops, hasReachedEnd else { return false }
        seek(to: .zero)
        player.play()
        return true
    }

    var isPlaying: Bool { player.rate > 0 }

    func play() { player.play() }
    func pause() { player.pause() }

    func togglePlayback() {
        if isPlaying { pause() } else { play() }
    }

    /// Seeking throws away everything the sink is holding. Those depth frames
    /// belong to a moment that is no longer the moment, and pairing one of them
    /// with a frame from somewhere else in the film is the worst possible
    /// outcome: a picture with someone else's depth in it.
    func seek(to time: CMTime) {
        sink.flush()
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    var currentTime: CMTime { player.currentTime() }

    // MARK: Frames

    /// The frame that should be on screen now, or nil when it is the same one
    /// as last time.
    ///
    /// Returning nil is the common case and the cheap one. Video runs at 24 or
    /// 30 and the display runs at 90, so most display frames have nothing new
    /// to decode, and the whole architecture depends on noticing that rather
    /// than redoing the warp for a picture that did not change.
    func newFrame() -> PairedFrame? {
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard itemTime.isValid, output.hasNewPixelBuffer(forItemTime: itemTime) else { return nil }

        var displayTime = CMTime.zero
        guard let color = output.copyPixelBuffer(
            forItemTime: itemTime, itemTimeForDisplay: &displayTime
        ) else { return nil }

        guard let match = sink.depth(at: displayTime) else { return nil }

        return PairedFrame(
            color: color,
            depth: match.buffer,
            time: displayTime,
            exactPairing: match.exact
        )
    }

    /// What the pairing has actually been doing, for the diagnostics panel.
    var pairingStatistics: DepthFrameSink.Statistics { sink.currentStatistics }

    func resetPairingStatistics() { sink.resetStatistics() }
}
