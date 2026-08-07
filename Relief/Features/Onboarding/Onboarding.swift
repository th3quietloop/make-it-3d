import SwiftUI
import Observation

/// The first run.
///
/// Relief's whole argument is that you judge the depth before you commit to a
/// conversion. A first time user does not know that. They drop a file, press
/// Convert, and get the same experience any other converter would have given
/// them, having never touched Depth, Stereo, or Wiggle.
///
/// So this teaches exactly one habit: look before you convert. Not a tour.
///
/// Three deliberate choices:
///
/// It does not block. There is no modal, no wizard, no step counter. Everything
/// arrives in the toast surface the app already had, so onboarding introduces
/// no new visual vocabulary and nothing stands between the user and the file
/// they came to convert.
///
/// It fires at the moment of relevance, not at launch. Telling someone about
/// preview modes before they have a file on screen is telling them about
/// nothing.
///
/// It acts rather than points. "Show me" does not highlight a control, it
/// switches to Wiggle and starts it. Watching the depth is the lesson; a coach
/// mark describing the lesson is not.
@Observable
@MainActor
final class Onboarding {

    /// The moments worth teaching. Deliberately short.
    ///
    /// A fourth beat for the AirDrop handoff was cut: the completion toast
    /// already says "Send it to the Vision Pro" and carries the action, so a
    /// guidance message there would be the same sentence twice.
    enum Beat: String, CaseIterable {
        /// A file is ready and the user has not yet been told to look at it.
        case judge
        /// They have looked. Now the dial that changes what they saw.
        case tune
    }

    private let defaults = UserDefaults.standard
    private static let prefix = "onboarding.seen."

    /// Set while a guided first run is in progress, so the beats fire even for
    /// someone who has used the app before and asked to see it again.
    private(set) var isTouring = false

    func hasSeen(_ beat: Beat) -> Bool {
        defaults.bool(forKey: Self.prefix + beat.rawValue)
    }

    func markSeen(_ beat: Beat) {
        defaults.set(true, forKey: Self.prefix + beat.rawValue)
    }

    var isComplete: Bool {
        Beat.allCases.allSatisfy(hasSeen)
    }

    func startTour() {
        Beat.allCases.forEach { defaults.set(false, forKey: Self.prefix + $0.rawValue) }
        isTouring = true
    }

    func reset() {
        Beat.allCases.forEach { defaults.removeObject(forKey: Self.prefix + $0.rawValue) }
        isTouring = false
    }

    private func shouldFire(_ beat: Beat) -> Bool {
        !hasSeen(beat)
    }

    // MARK: The beats

    /// A file finished probing and is on the stage for the first time.
    func fileBecameReady(
        toasts: ToastCenter,
        showDepth: @escaping @MainActor () -> Void
    ) {
        guard shouldFire(.judge) else { return }
        markSeen(.judge)

        toasts.guidance(
            "Look at the depth first",
            detail: "Wiggle flips between the two eyes. If the depth reads wrong here, it will read wrong in the headset.",
            actionLabel: "Show me"
        ) {
            showDepth()
        }
    }

    /// They have used a preview mode, so the control that changes what they are
    /// looking at is now worth naming.
    func previewModeUsed(_ mode: PreviewMode, toasts: ToastCenter) {
        // Source is the default, so arriving there proves nothing.
        guard mode != .source, shouldFire(.tune) else { return }
        guard hasSeen(.judge) else { return }
        markSeen(.tune)
        isTouring = false

        toasts.guidance(
            "Depth strength is the main dial",
            detail: "Soft, Standard, Deep. The gauge above Convert says whether this shot is comfortable or too strong."
        )
    }
}
