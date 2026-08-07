import SwiftUI

/// The design laws, carried across from MAKEIT3D_DESIGN.md.
///
/// Same family, same accent, same radius vocabulary, same ban list. What
/// changes on visionOS is the surface underneath: there is no window chrome to
/// tint and no wallpaper to sit against, so panel fills give way to the
/// system's own glass and the tokens that survive are the ones that carry
/// meaning rather than the ones that painted a background.
///
/// The stage colour survives and matters more here than it did on the Mac.
/// Depth is judged against a dead field, and in a headset the dead field is the
/// only thing standing between the picture and the room.
enum VisionTokens {

    enum Palette {
        /// Off-black, never pure black. The letterbox around the picture and
        /// the surround in a darkened room.
        static let stage = Color(red: 0x10 / 255, green: 0x11 / 255, blue: 0x14 / 255)

        static let textPrimary = Color(red: 0xF4 / 255, green: 0xF5 / 255, blue: 0xF7 / 255)
        static let textSecondary = textPrimary.opacity(0.78)
        static let textTertiary = textPrimary.opacity(0.55)

        /// Cyan, right eye lineage. The only colour allowed on chrome.
        static let accent = Color(red: 0x29 / 255, green: 0xC4 / 255, blue: 0xD6 / 255)

        /// Vermilion. Only ever paired with the accent, only where stereo is
        /// the literal meaning. Never alone, never as chrome, never as error.
        static let stereoL = Color(red: 0xFF / 255, green: 0x4F / 255, blue: 0x42 / 255)

        static let error = Color(red: 0xFF / 255, green: 0x63 / 255, blue: 0x69 / 255)

        static let hairline = Color.white.opacity(0.12)
    }

    /// 8pt base grid. No values off this scale.
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    /// 6 for controls, 10 for panels. Nothing larger. Rounded corner inflation
    /// is banned.
    enum Radius {
        static let control: CGFloat = 6
        static let panel: CGFloat = 10
    }

    /// SF Pro and SF Mono. No serif anywhere, in any state, ever.
    ///
    /// The scale is the Mac's 1.2 ratio moved up one step, because visionOS
    /// body type is 17pt at a metre rather than 13pt at arm's length, and type
    /// that reads on a monitor disappears on a wall.
    enum Font {
        static let caption = SwiftUI.Font.system(size: 13, weight: .regular)
        static let sectionLabel = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 17, weight: .regular)
        static let bodyMedium = SwiftUI.Font.system(size: 17, weight: .medium)
        static let rowTitle = SwiftUI.Font.system(size: 20, weight: .medium)
        static let headline = SwiftUI.Font.system(size: 34, weight: .semibold)

        /// SF Mono, tabular figures, for every numeric readout.
        static let mono = SwiftUI.Font.system(size: 17, design: .monospaced).monospacedDigit()
        static let monoCaption = SwiftUI.Font.system(size: 13, design: .monospaced).monospacedDigit()
        static let monoReadout = SwiftUI.Font.system(size: 28, design: .monospaced).monospacedDigit()
    }

    enum Tracking {
        static let sectionLabel: CGFloat = 0.4
    }

    /// Every animation has a job written next to it.
    enum Motion {
        /// Panels and disclosure. Job: spatial continuity.
        static var panel: Animation { .spring(response: 0.28, dampingFraction: 1.0) }
        /// The dial has no animation at all, and that is the design. A depth
        /// change has to be visible within one frame of the gesture, and any
        /// easing on the value itself is a lie about what the film looks like
        /// at the number under your finger.
    }
}

/// A section label, set once so no view invents its own.
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(VisionTokens.Font.sectionLabel)
            .tracking(VisionTokens.Tracking.sectionLabel)
            .textCase(.uppercase)
            .foregroundStyle(VisionTokens.Palette.textTertiary)
    }
}

/// A number the app is claiming as measured, set in mono so it reads as one.
struct Readout: View {
    let value: String
    var emphasis: Bool = false

    var body: some View {
        Text(value)
            .font(emphasis ? VisionTokens.Font.monoReadout : VisionTokens.Font.mono)
            .foregroundStyle(
                emphasis ? VisionTokens.Palette.textPrimary : VisionTokens.Palette.textSecondary
            )
    }
}

#Preview {
    VStack(alignment: .leading, spacing: VisionTokens.Space.m) {
        SectionLabel("Strength")
        Readout(value: "1.60 %", emphasis: true)
        Readout(value: "90.0 fps")
    }
    .padding(VisionTokens.Space.xl)
}
