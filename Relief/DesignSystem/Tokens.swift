import SwiftUI

/// Every color, spacing, radius, and type value in Relief is defined here and
/// nowhere else. RELIEF_DESIGN.md is the source; this file is its translation.
/// If a view needs a value that is not in this file, the value is wrong.
enum Tokens {

    // MARK: Color

    /// Dark only, and that is a decision: this is a viewing instrument and the
    /// stage must recede. Light mode is a non-goal.
    enum Palette {
        /// Off-black. Never pure black (banned).
        static let stage = Color(hex: 0x101114)
        static let panel = Color(hex: 0x17181C)
        static let panelRaised = Color(hex: 0x1D1F24)

        static let hairline = Color.white.opacity(0.07)

        static let textPrimary = Color(hex: 0xF4F5F7)
        static let textSecondary = Color(hex: 0xF4F5F7).opacity(0.62)
        static let textTertiary = Color(hex: 0xF4F5F7).opacity(0.40)

        /// Cyan, right eye lineage. The only color allowed on chrome:
        /// Convert fill, progress, focus rings, selection tint.
        static let accent = Color(hex: 0x29C4D6)

        /// Vermilion. Appears ONLY paired with accent cyan, only where stereo
        /// is the literal meaning: the L and R eye badges in Stereo mode, the
        /// app icon, the export complete moment. Never alone, never as chrome,
        /// never as error.
        static let stereoL = Color(hex: 0xFF4F42)

        static let error = Color(hex: 0xE5484D)

        /// Error text on a dark surface.
        ///
        /// The base error red measures about 3.8:1 as 11pt text on the chip
        /// fill, which misses AA. Dark surfaces want the lighter, slightly
        /// desaturated step of the same colour, which measures about 5.1:1.
        /// Same semantic, correct value for the surface it sits on.
        static let errorText = Color(hex: 0xFF6369)

        /// Selection tint: accent at 12% fill behind a selected queue row.
        static let selectionFill = accent.opacity(0.12)
        /// Focus ring: 2pt accent at 40%.
        static let focusRing = accent.opacity(0.40)

        /// Chip fills, at the same 12% as the selection tint.
        static let chipFillAccent = accent.opacity(0.12)
        static let chipFillError = error.opacity(0.12)
        /// The model missing banner across the top of the stage.
        static let bannerFill = error.opacity(0.10)
        /// An unselected preset chip: present, but not competing with the
        /// selected one.
        static let controlFillQuiet = panelRaised.opacity(0.5)

        /// Depth map ramp: monochrome silver. Explicitly not turbo or viridis.
        /// The rainbow ramp is an AI demo tell and it is banned here.
        static let depthNear = Color(hex: 0xE8E9EC)
        static let depthFar = Color(hex: 0x26282E)
    }

    /// The depth ramp as raw components, for Metal and CoreGraphics work that
    /// cannot take a SwiftUI Color.
    enum DepthRamp {
        /// near #E8E9EC
        static let near = (r: 0xE8 / 255.0, g: 0xE9 / 255.0, b: 0xEC / 255.0)
        /// far #26282E
        static let far = (r: 0x26 / 255.0, g: 0x28 / 255.0, b: 0x2E / 255.0)

        /// Samples the silver ramp. `nearness` is 0 (far) to 1 (near).
        static func sample(_ nearness: Double) -> (r: Double, g: Double, b: Double) {
            let t = min(max(nearness, 0), 1)
            return (far.r + (near.r - far.r) * t,
                    far.g + (near.g - far.g) * t,
                    far.b + (near.b - far.b) * t)
        }
    }

    // MARK: Spacing

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

    // MARK: Radius

    /// Radius vocabulary is 6 for controls, 10 for panels and thumbnails,
    /// nothing larger. Rounded corner inflation is banned.
    enum Radius {
        static let control: CGFloat = 6
        static let panel: CGFloat = 10
    }

    // MARK: Layout

    enum Layout {
        static let sidebarWidth: CGFloat = 264
        static let sidebarMinWidth: CGFloat = 220
        static let inspectorWidth: CGFloat = 296
        static let queueRowHeight: CGFloat = 56
        static let thumbnailSize: CGFloat = 40
        /// macOS control minimum.
        static let minTarget: CGFloat = 28
        /// Anything also reachable while leaning back.
        static let leanBackTarget: CGFloat = 44
        /// 2pt leading bar that encodes queue row selection.
        static let selectionBarWidth: CGFloat = 2
        static let focusRingWidth: CGFloat = 2
        static let hairlineWidth: CGFloat = 1

        /// The progress ring over a converting row's thumbnail.
        static let progressRing: CGFloat = 24
        static let progressRingWidth: CGFloat = 2

        /// Pane headers. One value, so QUEUE and STRENGTH sit on the same
        /// baseline off the toolbar edge rather than a few points apart.
        static let paneHeaderHeight: CGFloat = 40

        /// Toasts, bottom leading over the stage.
        static let toastWidth: CGFloat = 320
        /// The depth gauge that replaced the raw pixel readouts.
        static let gaugeHeight: CGFloat = 8
        static let gaugeMarker: CGFloat = 3
        /// Reserved height for the inspector's action stack, so the primary
        /// button never moves as a row changes status.
        static let actionStackHeight: CGFloat = 64
        /// The tick marking the screen plane on the convergence slider.
        static let tickHeight: CGFloat = 8
        /// Fixed columns, so numbers do not jitter as their digits change.
        static let timecodeColumn: CGFloat = 72
        static let durationColumn: CGFloat = 56
        static let percentColumn: CGFloat = 56
        /// The preview mode control, centred over the stage.
        static let previewPickerWidth: CGFloat = 320
    }

    // MARK: Type

    /// One family: SF Pro. SF Mono for every numeric readout. No serif
    /// anywhere, in any state, ever (house rule). Scale is 1.2 ratio anchored
    /// to macOS 13pt body.
    enum TypeScale {
        static let caption: CGFloat = 11
        static let body: CGFloat = 13
        static let rowTitle: CGFloat = 16
        static let readout: CGFloat = 20
        static let headline: CGFloat = 28
    }

    enum Font {
        /// 11pt caption and section labels.
        static let caption = SwiftUI.Font.system(size: TypeScale.caption, weight: .regular)
        /// 11pt, all caps, +0.4 tracking, 62% text color. Apply `.tracking`
        /// and `.textCase(.uppercase)` at the call site via `SectionLabel`.
        static let sectionLabel = SwiftUI.Font.system(size: TypeScale.caption, weight: .semibold)
        /// 13pt UI and body.
        static let body = SwiftUI.Font.system(size: TypeScale.body, weight: .regular)
        static let bodyMedium = SwiftUI.Font.system(size: TypeScale.body, weight: .medium)
        /// 16pt row titles and viewer overlay labels.
        static let rowTitle = SwiftUI.Font.system(size: TypeScale.rowTitle, weight: .medium)
        /// 28pt empty state headline.
        static let headline = SwiftUI.Font.system(size: TypeScale.headline, weight: .semibold)

        /// SF Mono, tabular figures, for timecode and all tabular data.
        static let mono = SwiftUI.Font.system(size: TypeScale.body, design: .monospaced)
            .monospacedDigit()
        static let monoCaption = SwiftUI.Font.system(size: TypeScale.caption, design: .monospaced)
            .monospacedDigit()
        /// 20pt numeric readouts in the inspector.
        static let monoReadout = SwiftUI.Font.system(size: TypeScale.readout, design: .monospaced)
            .monospacedDigit()

        /// SF Mono at any size from the scale, for the shared Readout view.
        /// The size still has to come from TypeScale; this only saves every
        /// caller from spelling out the font construction.
        static func mono(size: CGFloat) -> SwiftUI.Font {
            SwiftUI.Font.system(size: size, design: .monospaced).monospacedDigit()
        }
    }

    enum Tracking {
        /// +0.4 on section labels.
        static let sectionLabel: CGFloat = 0.4
    }

    enum LineSpacing {
        /// Line height 1.2 on labels means 0.2 of the size as extra spacing.
        static func labels(_ size: CGFloat) -> CGFloat { size * 0.2 }
        /// Line height 1.45 on the empty state supporting sentence.
        static func supporting(_ size: CGFloat) -> CGFloat { size * 0.45 }
    }

    // MARK: Elevation

    /// Panels separate by tone and hairline, not shadows. There is exactly one
    /// shadow in the app: the viewer's floating scrubber.
    enum Shadow {
        static let scrubberRadius: CGFloat = 8
        static let scrubberY: CGFloat = 2
        static let scrubberColor = Color.black.opacity(0.24)
    }

    // MARK: Motion

    /// Every animation has a job written next to it.
    enum Motion {
        /// Preview mode switch crossfade. Job: feedback.
        static let previewCrossfade: Double = 0.150
        /// Inspector collapse. Job: spatial continuity.
        static let inspectorCollapse: Double = 0.200
        /// The stereo fuse on completion. Job: signature.
        static let stereoFuse: Double = 0.250
        /// Wiggle alternation at 6Hz, hard cut. Crossfade kills the effect.
        static let wiggleHz: Double = 6
        static var wiggleInterval: Double { 1.0 / wiggleHz }
        /// The 2px split of the stereo fuse, and the error shake distance.
        static let fuseOffset: CGFloat = 2
        static let shakeOffset: CGFloat = 2
        /// One leg of the error shake. Four legs, then rest.
        static let shakeStep: Double = 0.05

        /// How long a toast stays before it retires itself. Errors stay until
        /// dismissed, because a message you missed is a message that failed.
        static let toastDwell: Double = 4.0

        /// How long the playhead has to hold still before the preview goes back
        /// and fetches the exact frame rather than the nearest keyframe.
        static let scrubSettle: Double = 0.25

        /// Springs, not durations, for anything the user can interrupt.
        /// Critically damped by default: graceful, no overshoot, and it always
        /// animates from wherever the value currently is rather than snapping
        /// to the target first.
        static var panelSpring: Animation {
            .spring(response: inspectorCollapse, dampingFraction: 1.0)
        }
        static var toastSpring: Animation {
            // A little bounce, because a toast arrives rather than appears.
            .spring(response: 0.35, dampingFraction: 0.8)
        }

        static var previewCrossfadeAnimation: Animation {
            .easeOut(duration: previewCrossfade)
        }
        static var inspectorAnimation: Animation {
            .easeOut(duration: inspectorCollapse)
        }
    }

    // MARK: Interaction

    /// Hover is +6% lightness, active is -8%, per the eight state enumeration.
    enum StateShift {
        static let hover: Double = 0.06
        static let active: Double = -0.08
        /// A converting row's thumbnail dims to this while the ring runs.
        static let dimmed: Double = 0.4
    }
}

// MARK: - Color helpers

extension Color {
    /// Builds a token color from a 24 bit hex literal. Used only inside
    /// Tokens.swift so that hex values never appear in feature code.
    fileprivate init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1
        )
    }

    /// Shifts a color's lightness for hover and active states, keeping the
    /// eight state enumeration honest without inventing new tokens.
    func shiftedLightness(by amount: Double) -> Color {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let shifted = min(max(b + CGFloat(amount), 0), 1)
        return Color(NSColor(hue: h, saturation: s, brightness: shifted, alpha: a))
    }
}
