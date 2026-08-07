import SwiftUI
import AppKit
import Observation

/// Translucent materials, and the accessibility settings that switch them off.
///
/// macOS chrome is vibrant. Sidebars, floating panels, and popovers let what is
/// behind them show through, which is how the system tells you what is content
/// and what is furniture. Relief's panes were flat fills, which is the loudest
/// signal an app was not built for this platform.
///
/// The stage stays opaque on purpose. This is a viewing instrument and the
/// picture must sit on a dead black field, so the material lives on the chrome
/// around it and nowhere near the image being judged.

// MARK: - Accessibility

/// Watches the system accessibility switches that materials have to respect.
///
/// Translucency with no fallback is not a style choice, it is an accessibility
/// failure: someone who has turned transparency off gets unreadable text. The
/// same goes for increased contrast, which wants defined borders rather than
/// tonal separation.
@Observable
@MainActor
final class AppearanceSettings {

    private(set) var reduceTransparency: Bool
    private(set) var increaseContrast: Bool
    private(set) var reduceMotion: Bool

    init() {
        let workspace = NSWorkspace.shared
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion

        // The token is deliberately not retained for removal: this object
        // lives as long as the app does, so there is no moment where removing
        // it would matter.
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        let workspace = NSWorkspace.shared
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
    }
}

// MARK: - Behind window vibrancy

/// An NSVisualEffectView, for the materials SwiftUI cannot express.
///
/// SwiftUI's own Material blends against what is inside the window. A macOS
/// sidebar blends against what is behind it, which is a different effect and
/// the one people recognise.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var isEnabled: Bool = true

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .followsWindowActiveState
        view.material = material
        view.blendingMode = blending
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        // Turning transparency off is a system setting, not a suggestion.
        view.state = isEnabled ? .followsWindowActiveState : .inactive
    }
}

// MARK: - The house materials

extension Tokens {

    /// Where each material belongs. Weight encodes hierarchy: heavier
    /// separates structural regions, lighter draws attention to things that
    /// float above content.
    enum Surface {
        /// The queue. A structural region, so it takes the heaviest material
        /// and the one macOS reserves for exactly this.
        case sidebar
        /// The inspector. A parallel panel, translucent and offset, with no
        /// scrim, because it does not block the flow.
        case panel
        /// Toasts and the scrubber. Small surfaces that float over the stage.
        case floating
    }
}

/// Applies the right material for a surface, with a solid fallback.
struct SurfaceMaterial: ViewModifier {
    let surface: Tokens.Surface
    @Environment(AppearanceSettings.self) private var appearance

    private var nsMaterial: NSVisualEffectView.Material {
        switch surface {
        case .sidebar: return .sidebar
        case .panel: return .contentBackground
        case .floating: return .hudWindow
        }
    }

    /// What the surface falls back to when translucency is off, and what tints
    /// the material the rest of the time. Materials on a dark app read too
    /// light on their own, so each carries a tone of the palette it replaced.
    private var solidFill: Color {
        switch surface {
        case .sidebar: return Tokens.Palette.panel
        case .panel: return Tokens.Palette.panel
        case .floating: return Tokens.Palette.panelRaised
        }
    }

    private var tintOpacity: Double {
        switch surface {
        case .sidebar: return 0.55
        case .panel: return 0.62
        case .floating: return 0.50
        }
    }

    func body(content: Content) -> some View {
        content
            .background {
                if appearance.reduceTransparency {
                    solidFill
                } else {
                    ZStack {
                        VisualEffect(material: nsMaterial, blending: blending)
                        // The palette showing through the glass, so Relief
                        // still looks like Relief rather than a default window.
                        solidFill.opacity(tintOpacity)
                    }
                }
            }
            // Increased contrast wants regions defined by a line, not by tone.
            .overlay {
                if appearance.increaseContrast {
                    Rectangle()
                        .strokeBorder(
                            Tokens.Palette.textSecondary,
                            lineWidth: Tokens.Layout.hairlineWidth
                        )
                }
            }
    }

    private var blending: NSVisualEffectView.BlendingMode {
        // The sidebar is the one surface that blends with the desktop, which
        // is the macOS convention. Everything else blends within the window so
        // the stage stays the darkest thing on screen.
        surface == .sidebar ? .behindWindow : .withinWindow
    }
}

extension View {
    func surfaceMaterial(_ surface: Tokens.Surface) -> some View {
        modifier(SurfaceMaterial(surface: surface))
    }

    /// A short fade where scrolling content passes under floating chrome.
    ///
    /// A 1pt divider says "these are two regions". A scroll edge says "there
    /// is more, and it is going under this". Only correct where content
    /// actually scrolls beneath something.
    func scrollEdgeFade(top: Bool = true, bottom: Bool = true) -> some View {
        mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: top ? 0.03 : 0),
                    .init(color: .black, location: bottom ? 0.97 : 1),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// Instant press feedback.
    ///
    /// Apple highlights on pointer down, not on release. Waiting for the click
    /// to complete before showing anything is the difference between a control
    /// that feels connected and one that feels dead.
    func pressable(scale: CGFloat = 0.97) -> some View {
        modifier(Pressable(pressedScale: scale))
    }
}

private struct Pressable: ViewModifier {
    let pressedScale: CGFloat
    @State private var isPressed = false
    @Environment(AppearanceSettings.self) private var appearance

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed && !appearance.reduceMotion ? pressedScale : 1)
            .animation(.easeOut(duration: 0.1), value: isPressed)
            .onLongPressGesture(minimumDuration: 0, pressing: { isPressed = $0 }, perform: {})
    }
}


/// Makes the host window transparent so vibrant regions can blend with what is
/// behind them.
///
/// A macOS sidebar picks up the desktop. That only works if nothing opaque is
/// painted underneath it, which means the window itself cannot be opaque and
/// every region that is not vibrant has to paint its own background. The stage
/// does exactly that, deliberately, because the picture must sit on a dead
/// field rather than on the user's wallpaper.
struct WindowVibrancy: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
