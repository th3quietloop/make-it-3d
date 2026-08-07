import SwiftUI

@main
struct MakeIt3DVisionApp: App {

    /// One model, built once. If Metal or the shader library is not there,
    /// nothing this app does is possible, so the failure is shown rather than
    /// worked around.
    @State private var startup = Startup()
    @State private var room = RoomSettings()

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    var body: some Scene {
        WindowGroup(id: "controls") {
            Group {
                switch startup.state {
                case .ready(let model):
                    ControlsView(model: model, room: room)
                        .task {
                            // The picture belongs in the room, not in this
                            // window, so the space opens as soon as there is
                            // something to put in it.
                            _ = await openImmersiveSpace(id: "theatre")
                        }
                case .failed(let message):
                    StartupFailureView(message: message)
                }
            }
        }
        .defaultSize(width: 620, height: 720)

        ImmersiveSpace(id: "theatre") {
            if case .ready(let model) = startup.state {
                TheatreView(model: model, room: room)
            }
        }
        // Mixed, so the room is still there. A film is watched in a place, and
        // taking the place away is a decision the person watching should make
        // with the dimmer, not one the app makes for them at launch.
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

/// Building the model can fail, and a SwiftUI App cannot throw, so the failure
/// becomes a state rather than a crash.
@MainActor
@Observable
final class Startup {
    enum State {
        case ready(PlayerModel)
        case failed(String)
    }

    let state: State

    init() {
        do {
            state = .ready(try PlayerModel())
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

struct StartupFailureView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: VisionTokens.Space.m) {
            Text("Make It 3D cannot start here.")
                .font(VisionTokens.Font.headline)
                .foregroundStyle(VisionTokens.Palette.textPrimary)
            Text(message)
                .font(VisionTokens.Font.body)
                .foregroundStyle(VisionTokens.Palette.error)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(VisionTokens.Space.xl)
    }
}

#Preview {
    StartupFailureView(message: "Make It 3D's shaders would not load.")
}
