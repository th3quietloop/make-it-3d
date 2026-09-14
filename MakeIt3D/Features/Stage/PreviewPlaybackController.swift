import AVFoundation
import AppKit
import Observation

/// Familiar movie playback is separate from deliberate still-eye alternation.
/// The shared time callback always reports time in the original video's space,
/// including when playing an excerpt whose local timestamp starts at zero.
@Observable
@MainActor
final class PreviewPlaybackController {
    let player = AVPlayer()
    private(set) var sourceURL: URL?
    private(set) var activeProofURL: URL?
    private(set) var proofSourceStartSeconds: Double = 0
    private(set) var isShowingProof = false
    private(set) var isPlaying = false
    private(set) var currentSeconds: Double = 0
    private(set) var duration: Double = 0
    private(set) var errorMessage: String?
    var loopProof = true
    var onTimeChanged: (@MainActor (Double) -> Void)?
    var onPlaybackStopped: (@MainActor () -> Void)?
    @ObservationIgnored private var timeObserver: PreviewPeriodicObservation?
    @ObservationIgnored private var endObserver: PreviewNotificationObservation?
    @ObservationIgnored private var failureObserver: PreviewNotificationObservation?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?

    var sourceSeconds: Double { currentSeconds + (isShowingProof ? proofSourceStartSeconds : 0) }

    init() {
        player.actionAtItemEnd = .pause
        let token = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 15.0, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, time.seconds.isFinite else { return }
                self.currentSeconds = time.seconds
                if self.isPlaying { self.onTimeChanged?(self.sourceSeconds) }
            }
        }
        timeObserver = PreviewPeriodicObservation(player: player, token: token)
    }

    func updateSource(url: URL) {
        guard sourceURL != url else { return }
        sourceURL = url
        stop()
        activeProofURL = nil
        proofSourceStartSeconds = 0
        isShowingProof = false
        replace(url)
    }

    func showOriginal(at seconds: Double? = nil) {
        guard let sourceURL else { return }
        let target = seconds ?? sourceSeconds
        let resume = isPlaying
        stop()
        isShowingProof = false
        replace(sourceURL)
        seek(seconds: target)
        if resume { play() }
    }

    func loadProof(url: URL, sourceStartSeconds: Double = 0) {
        stop()
        activeProofURL = url
        proofSourceStartSeconds = max(0, sourceStartSeconds)
        isShowingProof = true
        replace(url)
        seek(seconds: proofSourceStartSeconds)
    }

    func showProof(at sourceSeconds: Double? = nil) {
        guard let activeProofURL else { return }
        let target = sourceSeconds ?? self.sourceSeconds
        let resume = isPlaying
        stop()
        isShowingProof = true
        replace(activeProofURL)
        seek(seconds: target)
        if resume { play() }
    }

    /// Accepts original/global time for both the original and an excerpt.
    /// This method does not emit onTimeChanged, preventing model seek recursion.
    func seek(seconds: Double) {
        guard seconds.isFinite else { return }
        let local = max(0, seconds - (isShowingProof ? proofSourceStartSeconds : 0))
        let end = player.currentItem?.duration.seconds ?? 0
        let bounded = end.isFinite && end > 0 ? min(local, end) : local
        currentSeconds = bounded
        player.seek(to: CMTime(seconds: bounded, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlayback() { isPlaying ? stop() : play() }

    func play() {
        guard player.currentItem != nil else { return }
        if duration > 0, currentSeconds >= duration - 0.03 {
            seek(seconds: isShowingProof ? proofSourceStartSeconds : 0)
        }
        isPlaying = true
        player.play()
    }

    func stop() {
        let wasPlaying = isPlaying
        player.pause()
        isPlaying = false
        if wasPlaying { onPlaybackStopped?() }
    }

    func clear() {
        stop()
        player.replaceCurrentItem(with: nil)
        sourceURL = nil
        activeProofURL = nil
        proofSourceStartSeconds = 0
        currentSeconds = 0
        duration = 0
        isShowingProof = false
    }

    private func replace(_ url: URL) {
        endObserver = nil
        failureObserver = nil
        itemObservation = nil
        errorMessage = nil
        duration = 0
        currentSeconds = 0
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                if item.status == .failed {
                    self.errorMessage = item.error?.localizedDescription ?? "Couldn't play this video."
                    self.stop()
                }
                let seconds = item.duration.seconds
                if seconds.isFinite { self.duration = seconds }
            }
        }
        let endToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                if self.isShowingProof && self.loopProof {
                    self.seek(seconds: self.proofSourceStartSeconds)
                    self.play()
                } else { self.stop() }
            }
        }
        endObserver = PreviewNotificationObservation(center: .default, token: endToken)
        let failureToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.errorMessage = self.player.currentItem?.error?.localizedDescription ?? "Playback stopped before the end."
                self.stop()
            }
        }
        failureObserver = PreviewNotificationObservation(center: .default, token: failureToken)
    }
}
