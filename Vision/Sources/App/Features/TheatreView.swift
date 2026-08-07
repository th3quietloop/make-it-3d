import AVFoundation
import RealityKit
import SwiftUI

/// The picture, in the room.
///
/// An immersive space rather than a volume, and that is a decision. A volume is
/// capped at roughly two metres on a side, and a two metre screen is a
/// television. The PRD's success condition is watching a whole film at theatre
/// scale, which needs a wall, and a wall needs the space.
///
/// The screen is a plain plane. Everything interesting about it is in its
/// material, which shows a different picture to each eye, and in the two
/// textures behind that, which Metal rewrites at video rate.
struct TheatreView: View {

    let model: PlayerModel
    let room: RoomSettings

    @State private var root = Entity()
    @State private var screen = ModelEntity()
    @State private var surround = ModelEntity()
    @State private var updates: EventSubscription?

    var body: some View {
        RealityView { content in
            root.addChild(surround)
            root.addChild(screen)
            content.add(root)

            await buildScreen()
            buildSurround()
            layout()

            updates = content.subscribe(to: SceneEvents.Update.self) { _ in
                MainActor.assumeIsolated { model.onDisplayFrame() }
            }
        } update: { _ in
            layout()
        }
        .onChange(of: model.eyes == nil) { _, _ in
            Task { await buildScreen() }
        }
        .onChange(of: model.plainPlayer) { _, _ in
            Task { await buildScreen() }
        }
    }

    // MARK: Building

    /// The screen, sized to the film's own shape.
    ///
    /// Width is the thing a person means by "how big", so width is what the
    /// room setting controls and height follows from the aspect ratio. A screen
    /// that changed width when the film changed shape would feel like the room
    /// moved.
    private func buildScreen() async {
        let aspect = model.file.map { Double($0.width) / Double($0.height) } ?? 16.0 / 9.0
        let width = Float(room.screenWidthMetres)
        let height = Float(room.screenWidthMetres / aspect)
        screen.model = ModelComponent(
            mesh: .generatePlane(width: width, height: height),
            materials: [UnlitMaterial(color: .black)]
        )

        // A file with no depth track goes to RealityKit's own MV-HEVC
        // playback, which already shows spatial video in proper stereo. There
        // is nothing for the warp to do and nothing for the dial to change.
        if let player = model.plainPlayer {
            var component = VideoPlayerComponent(avPlayer: player)
            component.desiredViewingMode = .stereo
            screen.components.set(component)
            model.recordScreenMaterial(.nativeSpatialVideo)
            return
        }
        screen.components.remove(VideoPlayerComponent.self)

        guard let eyes = model.eyes else { return }

        do {
            let material = try await ScreenMaterial.perEye(textures: eyes)
            screen.model?.materials = [material]
            model.recordScreenMaterial(.perEye)
        } catch {
            // The per eye material is the only part of the picture that is not
            // plain Metal, so it is the only part that can fail on a system
            // this was not built against. Falling back to the left eye view on
            // both eyes keeps the film watchable and says so, which beats a
            // black screen and a log line nobody reads.
            screen.model?.materials = [ScreenMaterial.singleEye(texture: eyes.left)]
            model.recordScreenMaterial(.singleEye(reason: error.localizedDescription))
        }
    }

    /// A dimmable surround, so the picture is the brightest thing in the space.
    ///
    /// A sphere with its normals turned inward, unlit and near black. At full
    /// dim it is the stage colour from the design file, which is off black and
    /// never pure black, for the same reason it is off black on the Mac: pure
    /// black is not a colour anything is judged against, it is an absence, and
    /// a picture floating in an absence loses its edges.
    private func buildSurround() {
        surround.model = ModelComponent(
            mesh: .generateSphere(radius: 12),
            materials: [surroundMaterial()]
        )
        // Inside out, so the inside of the sphere is what gets drawn.
        surround.scale = SIMD3<Float>(-1, 1, 1)
    }

    private func surroundMaterial() -> UnlitMaterial {
        var material = UnlitMaterial(color: .init(white: 0.066, alpha: 1))
        material.blending = .transparent(opacity: .init(floatLiteral: Float(room.dimming)))
        return material
    }

    private func layout() {
        screen.position = SIMD3<Float>(0, Float(room.screenHeightMetres), -Float(room.distanceMetres))
        let aspect = model.file.map { Double($0.width) / Double($0.height) } ?? 16.0 / 9.0
        screen.model?.mesh = .generatePlane(
            width: Float(room.screenWidthMetres),
            height: Float(room.screenWidthMetres / aspect)
        )
        surround.model?.materials = [surroundMaterial()]
    }
}

/// Where the picture sits and how dark the room is.
@Observable
@MainActor
final class RoomSettings {
    /// Three metres wide at four metres away is about a thirty degree field,
    /// which is a good cinema seat rather than a front row one.
    var screenWidthMetres: Double = 3.0
    var distanceMetres: Double = 4.0
    /// Slightly below eye level, the way a screen in a room is.
    var screenHeightMetres: Double = -0.2
    /// 0 leaves the room as it is, 1 is fully surrounded by the stage colour.
    var dimming: Double = 0.0

    static let widthRange = 1.0...8.0
    static let distanceRange = 1.5...9.0
    static let heightRange = -1.2...1.2
}
