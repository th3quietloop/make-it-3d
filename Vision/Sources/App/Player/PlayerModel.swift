import AVFoundation
import CoreMedia
import Foundation
import Metal
import Observation
import RealityKit

/// Everything the app knows and everything it is doing.
///
/// One model rather than several, because the pieces are not separable: which
/// shot is playing decides what the dial starts from, the dial decides what the
/// warp renders, and the warp decides what the screen shows. Splitting that
/// into three objects would only mean writing the wiring three times.
///
/// Main actor throughout. RealityKit traps if a material, a mesh or a texture
/// is built anywhere else, and it traps as a crash inside the immersive space
/// rather than as a warning at the call site.
@MainActor
@Observable
final class PlayerModel {

    enum Status: Equatable {
        case empty
        case opening(String)
        /// A depth track file, playing, with the dial live.
        case playing
        /// A file with no depth track. It plays as ordinary MV-HEVC and the
        /// dial is off.
        case playingWithoutDepth(reason: String)
        case failed(String)
    }

    // MARK: Observed state

    private(set) var status: Status = .empty
    private(set) var file: DepthTrackFile?
    private(set) var shot: ShotMetadata?
    private(set) var currentTime: CMTime = .zero
    private(set) var isPlaying = false

    /// S and C, live.
    private(set) var tuning: StereoTuning = .default

    /// True while the shot's own suggestions are driving the dial. Goes false
    /// the moment the user touches it and stays false, because the suggestions
    /// are the Mac's opinion and the dial is the user's.
    private(set) var followsSuggestions = true

    let performance = PerformanceMeter()

    /// What the pairing has been doing. Zero near matches and zero misses is
    /// the Phase 1 gate, live, rather than in a test that ran once.
    private(set) var pairing = DepthFrameSink.Statistics()

    /// Frame index agreement, for the test clip. Real films carry no index
    /// strip, so this only runs on a file this app generated.
    private(set) var indexChecking = false
    private(set) var indexMismatches = 0
    private(set) var indexFramesChecked = 0

    /// What the screen is actually made of. Set by the view that builds it,
    /// held here so the measurements panel can say which of the two real states
    /// the app is in rather than leaving it to be inferred from the picture.
    enum ScreenMaterialStatus: Equatable {
        case notBuilt
        case perEye
        case singleEye(reason: String)
        case nativeSpatialVideo

        var summary: String {
            switch self {
            case .notBuilt: return "not built yet"
            case .perEye: return "per eye, camera index switch"
            case .singleEye(let reason): return "left eye to both eyes. \(reason)"
            case .nativeSpatialVideo: return "RealityKit MV-HEVC playback"
            }
        }
    }

    private(set) var screenMaterial: ScreenMaterialStatus = .notBuilt

    func recordScreenMaterial(_ status: ScreenMaterialStatus) {
        screenMaterial = status
    }

    // MARK: Engine

    private let device: MTLDevice
    private let library: MTLLibrary
    private let queue: MTLCommandQueue
    private let bridge: TextureBridge

    private var renderer: StereoWarpRenderer?
    private var playback: StereoPlayback?
    private(set) var eyes: EyeTextures?

    /// Set when the dial moves, cleared when the next frame is drawn.
    private var needsRerender = false
    private var lastShotNumber: Int?

    /// The player for a file with no depth track, handed straight to
    /// RealityKit's own MV-HEVC playback.
    private(set) var plainPlayer: AVPlayer?

    // MARK: Setup

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw EngineError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw EngineError.noDevice }
        self.device = device
        self.queue = queue
        self.library = try ShaderLibrary.bundled(device: device)
        self.bridge = try TextureBridge(device: device)
    }

    // MARK: Opening

    func openTestClip() async {
        status = .opening("Writing the test clip")
        do {
            let url = try await TestClip.ensureExists()
            await open(url: url, expectsFrameIndexStrip: true)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func rebuildTestClip() async {
        status = .opening("Rewriting the test clip")
        do {
            let url = try await TestClip.rebuild()
            await open(url: url, expectsFrameIndexStrip: true)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func open(url: URL, expectsFrameIndexStrip: Bool = false) async {
        teardown()
        status = .opening(url.lastPathComponent)
        indexChecking = expectsFrameIndexStrip
        indexMismatches = 0
        indexFramesChecked = 0

        // A file arriving from the Files app is outside the sandbox until it is
        // asked for. Without this the reader gets a permission error that reads
        // like a corrupt file, which sends you looking in exactly the wrong
        // place.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let file = try await DepthTrackReader.open(url: url)
            self.file = file

            guard file.hasDepthTrack else {
                try startPlainPlayback(file: file)
                return
            }

            let renderer = try StereoWarpRenderer(
                device: device,
                library: library,
                frameWidth: file.width,
                frameHeight: file.height,
                meshVertexSpacing: tuning.meshVertexSpacing
            )
            let eyes = try EyeTextures(width: file.width, height: file.height)
            let playback = try StereoPlayback(file: file)

            self.renderer = renderer
            self.eyes = eyes
            self.playback = playback

            if let first = file.depth?.shots.first {
                shot = first.metadata
                tuning = tuning.applying(first.metadata)
                lastShotNumber = first.metadata.shot
            }
            followsSuggestions = true
            performance.reset()

            status = .playing
            playback.play()
            isPlaying = true
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// A file with no depth track still has to play, and RealityKit already
    /// knows how to show MV-HEVC in proper stereo. Rebuilding that badly would
    /// be a worse Photos, which is the thing this app exists not to be.
    private func startPlainPlayback(file: DepthTrackFile) throws {
        let player = AVPlayer(url: file.url)
        plainPlayer = player
        player.play()
        isPlaying = true
        status = .playingWithoutDepth(
            reason: file.dialDisabledReason
                ?? "This file has no depth track, so its depth is already baked in."
        )
    }

    private func teardown() {
        playback?.pause()
        playback = nil
        plainPlayer?.pause()
        plainPlayer = nil
        renderer = nil
        eyes = nil
        shot = nil
        lastShotNumber = nil
        isPlaying = false
        pairing = DepthFrameSink.Statistics()
    }

    // MARK: Transport

    func togglePlayback() {
        if let playback {
            playback.togglePlayback()
            isPlaying = playback.isPlaying
        } else if let plainPlayer {
            if plainPlayer.rate > 0 { plainPlayer.pause() } else { plainPlayer.play() }
            isPlaying = plainPlayer.rate > 0
        }
    }

    func seek(toFraction fraction: Double) {
        guard let file else { return }
        let seconds = file.duration.seconds * min(max(fraction, 0), 1)
        let time = CMTime(seconds: seconds, preferredTimescale: file.duration.timescale)
        playback?.seek(to: time)
        plainPlayer?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        // The plate is a memory of the frames just drawn, and after a seek none
        // of them are about this moment.
        renderer?.resetBackgroundPlate()
    }

    // MARK: The dial

    func setStrength(_ value: Double) {
        tuning.strength = value.clamped(to: StereoTuning.strengthRange)
        takeOver()
    }

    func setConvergence(_ value: Double) {
        tuning.convergence = value.clamped(to: StereoTuning.convergenceRange)
        takeOver()
    }

    /// Hands the dial back to the film's own suggestions.
    func followSuggestions() {
        followsSuggestions = true
        if let shot { tuning = tuning.applying(shot) }
        needsRerender = true
    }

    /// Starts the pairing counters over, so a reading covers a chosen stretch
    /// rather than everything since the file opened.
    func resetPairing() {
        playback?.resetPairingStatistics()
        pairing = DepthFrameSink.Statistics()
        indexMismatches = 0
        indexFramesChecked = 0
    }

    private func takeOver() {
        followsSuggestions = false
        // Not rendered here. The next display frame is at most eleven
        // milliseconds away and it is where every other frame gets drawn, so
        // going through it keeps one path instead of two and still lands
        // inside the one frame the gate asks for.
        needsRerender = true
    }

    /// Forward pop and depth behind the screen, in pixels, for the shot in
    /// play. What the gauge shows.
    var disparityPixels: (forward: Double, behind: Double)? {
        guard let shot, let file else { return nil }
        return (
            forward: tuning.forwardPopPixels(shot: shot, frameWidth: file.width),
            behind: tuning.depthPixels(shot: shot, frameWidth: file.width)
        )
    }

    // MARK: The loop

    /// Called once per display frame from the RealityView's update subscription.
    func onDisplayFrame() {
        performance.recordDisplayFrame()

        guard let playback, let renderer, let eyes else { return }

        playback.loopIfFinished()
        currentTime = playback.currentTime
        isPlaying = playback.isPlaying
        pairing = playback.pairingStatistics

        if let frame = playback.newFrame() {
            draw(frame, renderer: renderer, eyes: eyes)
        } else if needsRerender {
            redraw(renderer: renderer, eyes: eyes)
        }
    }

    private func draw(
        _ frame: StereoPlayback.PairedFrame,
        renderer: StereoWarpRenderer,
        eyes: EyeTextures
    ) {
        guard let file else { return }

        let currentShot = file.shot(at: frame.time)?.metadata
            ?? shot
            ?? ShotMetadata(
                shot: 0, depthScale: 1, depthOffset: 0,
                suggestedStrength: tuning.strength,
                suggestedConvergence: tuning.convergence,
                comfortLoad: 0
            )

        let startsNewShot = currentShot.shot != lastShotNumber
        if startsNewShot {
            lastShotNumber = currentShot.shot
            if followsSuggestions { tuning = tuning.applying(currentShot) }
        }
        shot = currentShot

        if indexChecking { checkFrameIndex(frame) }

        do {
            let color = try bridge.texture(from: frame.color, format: .bgra8Unorm)
            let depth = try bridge.texture(from: frame.depth, format: .bgra8Unorm)

            guard let commandBuffer = queue.makeCommandBuffer() else { return }
            let targets = eyes.writable(using: commandBuffer)

            renderer.renderFrame(
                commandBuffer: commandBuffer,
                source: color.texture,
                depth: depth.texture,
                shot: currentShot,
                startsNewShot: startsNewShot,
                tuning: tuning,
                left: targets.left,
                right: targets.right
            )
            performance.measure(commandBuffer)

            // The bridged textures are views onto the decoded frames. Holding
            // them until the buffer completes is what stops the frame being
            // recycled out from under the GPU mid warp.
            commandBuffer.addCompletedHandler { _ in
                _ = color
                _ = depth
            }
            commandBuffer.commit()
            needsRerender = false
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func redraw(renderer: StereoWarpRenderer, eyes: EyeTextures) {
        guard let commandBuffer = queue.makeCommandBuffer() else { return }
        let targets = eyes.writable(using: commandBuffer)
        let did = renderer.rerender(
            commandBuffer: commandBuffer,
            tuning: tuning,
            left: targets.left,
            right: targets.right
        )
        guard did else { return }
        performance.measure(commandBuffer)
        commandBuffer.commit()
        needsRerender = false
    }

    /// Reads the frame index out of both pictures and counts disagreements.
    ///
    /// This is Phase 1's gate running live, on the real player path, rather
    /// than in a test that passed once. It costs twelve pixel reads on each of
    /// two frames, which is nothing, and it means a drift can never be
    /// something the app failed to notice.
    private func checkFrameIndex(_ frame: StereoPlayback.PairedFrame) {
        // Both are read out of a BGRA raster: the depth track arrives from the
        // compositor as grey BGRA, so the same reader works on it.
        guard let colour = (try? TrackPairReader.colorIndex(of: frame.color)) ?? nil,
              let depth = (try? TrackPairReader.colorIndex(of: frame.depth)) ?? nil else { return }
        indexFramesChecked += 1
        if colour != depth { indexMismatches += 1 }
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
