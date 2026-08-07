import Foundation
import RealityKit

/// What the screen is made of.
///
/// Two real states, not one state and a placeholder.
///
/// `perEye` is the product: a material that shows the left eye view to the left
/// eye and the right eye view to the right, so the depth dial has something to
/// change.
///
/// `singleEye` is what a file with no depth track gets, and every file Make It
/// 3D wrote before the depth track existed is such a file. There is nothing to
/// synthesize, so the frame is shown as filmed, to both eyes, and the dial is
/// off with a line saying why. It is also where the app lands if the per eye
/// material cannot be built on this system, which is a thing worth surviving
/// rather than crashing on.
@MainActor
enum ScreenMaterial {

    /// The material's prim path inside StereoScreen.usda.
    private static let materialName = "/Root/StereoScreen"
    private static let leftParameter = "LeftEye"
    private static let rightParameter = "RightEye"

    enum MaterialError: LocalizedError {
        case documentMissing
        case notLoadable(String)

        var errorDescription: String? {
            switch self {
            case .documentMissing:
                return "The screen material is missing from the app."
            case .notLoadable(let detail):
                return "The per eye screen material would not build. \(detail)"
            }
        }
    }

    /// Builds the per eye material and binds the two eye textures to it.
    static func perEye(textures: EyeTextures) async throws -> ShaderGraphMaterial {
        guard let url = Bundle.main.url(forResource: "StereoScreen", withExtension: "usda") else {
            throw MaterialError.documentMissing
        }

        var material: ShaderGraphMaterial
        do {
            material = try await ShaderGraphMaterial(named: materialName, from: url)
        } catch {
            throw MaterialError.notLoadable(
                "\(error.localizedDescription) Loading \(materialName) from \(url.lastPathComponent)."
            )
        }

        try material.setParameter(name: leftParameter, value: .textureResource(textures.left))
        try material.setParameter(name: rightParameter, value: .textureResource(textures.right))
        return material
    }

    /// The same frame to both eyes.
    static func singleEye(texture: TextureResource) -> UnlitMaterial {
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        // The picture is the picture. A film graded once should not be graded
        // again on the way to the eye.
        material.faceCulling = .back
        return material
    }

    /// Rebinds the textures on an existing per eye material, for the case where
    /// a new file has a different frame size and the textures were remade.
    static func rebind(
        _ material: inout ShaderGraphMaterial, textures: EyeTextures
    ) throws {
        try material.setParameter(name: leftParameter, value: .textureResource(textures.left))
        try material.setParameter(name: rightParameter, value: .textureResource(textures.right))
    }
}
