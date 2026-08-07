import SwiftUI
import UniformTypeIdentifiers

/// The window you reach for without taking the headset off.
///
/// One decision per state, which is the rule the Mac app works to. Empty asks
/// "which film". Playing asks "does the depth read right", and that is the dial
/// and nothing else above the fold. Everything measured lives further down,
/// where it is available without being in the way.
struct ControlsView: View {

    let model: PlayerModel
    let room: RoomSettings

    @State private var showingImporter = false
    @State private var showingMeasurements = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VisionTokens.Space.l) {
                switch model.status {
                case .empty:
                    emptyState
                case .opening(let what):
                    opening(what)
                case .playing:
                    playing
                case .playingWithoutDepth(let reason):
                    playingWithoutDepth(reason)
                case .failed(let message):
                    failure(message)
                }
            }
            .padding(VisionTokens.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.quickTimeMovie, .mpeg4Movie, .movie]
        ) { result in
            guard case .success(let url) = result else { return }
            Task { await model.open(url: url) }
        }
    }

    // MARK: States

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: VisionTokens.Space.m) {
            Text("Turn the depth while you watch.")
                .font(VisionTokens.Font.headline)
                .foregroundStyle(VisionTokens.Palette.textPrimary)

            Text("""
                Open a film Make It 3D wrote with a depth track and the strength \
                becomes something you change on your face, mid scene, without \
                converting anything again.
                """)
                .font(VisionTokens.Font.body)
                .foregroundStyle(VisionTokens.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: VisionTokens.Space.s) {
                Button("Open a film") { showingImporter = true }
                    .buttonStyle(.borderedProminent)
                Button("Use the test clip") {
                    Task { await model.openTestClip() }
                }
            }
            .font(VisionTokens.Font.body)
        }
    }

    private func opening(_ what: String) -> some View {
        VStack(alignment: .leading, spacing: VisionTokens.Space.s) {
            Text(what)
                .font(VisionTokens.Font.rowTitle)
                .foregroundStyle(VisionTokens.Palette.textPrimary)
            ProgressView()
        }
    }

    private var playing: some View {
        VStack(alignment: .leading, spacing: VisionTokens.Space.l) {
            transport

            // The depth dial itself is not here. It lives under the picture, in
            // the room, because changing depth means watching the change, and a
            // window sits between you and the screen.
            Text("The depth dial is under the picture.")
                .font(VisionTokens.Font.caption)
                .foregroundStyle(VisionTokens.Palette.textTertiary)

            DepthDial(
                value: model.tuning.convergence,
                range: StereoTuning.convergenceRange,
                label: "Screen plane",
                // Written as a closure rather than passed as a method
                // reference. A bare `model.setConvergence` makes Swift 6.3.3
                // build a reabstraction thunk between an isolated and a non
                // isolated function type, and that thunk crashes the
                // compiler's IR generation. The closure does the same work
                // without producing one.
                format: { String(format: "%.2f", $0) },
                onChange: { model.setConvergence($0) }
            )

            roomControls
            measurements
        }
    }

    private func playingWithoutDepth(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: VisionTokens.Space.m) {
            transport
            Text(reason)
                .font(VisionTokens.Font.body)
                .foregroundStyle(VisionTokens.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            roomControls
            Button("Open another film") { showingImporter = true }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: VisionTokens.Space.m) {
            Text(message)
                .font(VisionTokens.Font.body)
                .foregroundStyle(VisionTokens.Palette.error)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: VisionTokens.Space.s) {
                Button("Open a film") { showingImporter = true }
                Button("Rewrite the test clip") {
                    Task { await model.rebuildTestClip() }
                }
            }
        }
    }

    // MARK: Pieces

    private var transport: some View {
        HStack(spacing: VisionTokens.Space.m) {
            Button {
                model.togglePlayback()
            } label: {
                Label(
                    model.isPlaying ? "Pause" : "Play",
                    systemImage: model.isPlaying ? "pause.fill" : "play.fill"
                )
                .labelStyle(.iconOnly)
            }

            Text(Self.timecode(model.currentTime.seconds))
                .font(VisionTokens.Font.mono)
                .foregroundStyle(VisionTokens.Palette.textSecondary)

            if let file = model.file {
                Slider(
                    value: Binding(
                        get: {
                            let total = file.duration.seconds
                            return total > 0 ? model.currentTime.seconds / total : 0
                        },
                        set: { model.seek(toFraction: $0) }
                    )
                )
                Text(Self.timecode(file.duration.seconds))
                    .font(VisionTokens.Font.mono)
                    .foregroundStyle(VisionTokens.Palette.textTertiary)
            }

            Button("Open") { showingImporter = true }
        }
    }

    private var roomControls: some View {
        VStack(alignment: .leading, spacing: VisionTokens.Space.s) {
            SectionLabel("The room")

            labelledSlider(
                "Screen width",
                value: Binding(get: { room.screenWidthMetres }, set: { room.screenWidthMetres = $0 }),
                range: RoomSettings.widthRange,
                readout: String(format: "%.1f m", room.screenWidthMetres)
            )
            labelledSlider(
                "Distance",
                value: Binding(get: { room.distanceMetres }, set: { room.distanceMetres = $0 }),
                range: RoomSettings.distanceRange,
                readout: String(format: "%.1f m", room.distanceMetres)
            )
            labelledSlider(
                "Height",
                value: Binding(get: { room.screenHeightMetres }, set: { room.screenHeightMetres = $0 }),
                range: RoomSettings.heightRange,
                readout: String(format: "%+.1f m", room.screenHeightMetres)
            )
            labelledSlider(
                "Dial position",
                value: Binding(get: { room.consoleDropMetres }, set: { room.consoleDropMetres = $0 }),
                range: RoomSettings.consoleDropRange,
                readout: String(format: "%+.2f m", room.consoleDropMetres)
            )
            labelledSlider(
                "Dim the room",
                value: Binding(get: { room.dimming }, set: { room.dimming = $0 }),
                range: 0...1,
                readout: "\(Int((room.dimming * 100).rounded())) %"
            )
        }
    }

    private func labelledSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        readout: String
    ) -> some View {
        HStack(spacing: VisionTokens.Space.s) {
            Text(title)
                .font(VisionTokens.Font.body)
                .foregroundStyle(VisionTokens.Palette.textSecondary)
                .frame(width: 140, alignment: .leading)
            Slider(value: value, in: range)
            Text(readout)
                .font(VisionTokens.Font.mono)
                .foregroundStyle(VisionTokens.Palette.textSecondary)
                .frame(width: 80, alignment: .trailing)
        }
    }

    /// Every number this app is willing to claim, and nothing it is not.
    private var measurements: some View {
        DisclosureGroup(isExpanded: $showingMeasurements) {
            let reading = model.performance.reading
            VStack(alignment: .leading, spacing: VisionTokens.Space.xs) {
                measurement("Display", String(format: "%.1f fps", reading.displayFramesPerSecond))
                measurement(
                    "Slowest display frame",
                    String(format: "%.1f ms", reading.worstDisplayFrameMilliseconds)
                )
                measurement(
                    "Stereo pair, mean",
                    String(format: "%.2f ms", reading.meanWarpMilliseconds)
                )
                measurement(
                    "Stereo pair, worst",
                    String(format: "%.2f ms", reading.worstWarpMilliseconds)
                )
                measurement(
                    "Pairs synthesized",
                    String(format: "%.1f per second", reading.warpsPerSecond)
                )
                measurement(
                    "Frame pairing",
                    """
                    \(model.pairing.exactMatches) exact, \
                    \(model.pairing.nearMatches) near, \
                    \(model.pairing.misses) missed
                    """
                )
                if model.indexChecking {
                    measurement(
                        "Frame index agreement",
                        "\(model.indexMismatches) mismatched of \(model.indexFramesChecked)"
                    )
                }
                measurement(
                    "Dial latency, worst",
                    "\(model.dialLatencyWorstFrames) display frame(s)"
                )
                measurement("Screen", model.screenMaterial.summary)
                if let shot = model.shot {
                    measurement("Shot", "\(shot.shot)")
                    measurement("Comfort load", String(format: "%.2f", shot.comfortLoad))
                }
            }
            .padding(.top, VisionTokens.Space.xs)
        } label: {
            SectionLabel("Measured")
        }
    }

    private func measurement(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
                .font(VisionTokens.Font.caption)
                .foregroundStyle(VisionTokens.Palette.textTertiary)
            Spacer()
            Text(value)
                .font(VisionTokens.Font.monoCaption)
                .foregroundStyle(VisionTokens.Palette.textSecondary)
        }
    }

    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}
