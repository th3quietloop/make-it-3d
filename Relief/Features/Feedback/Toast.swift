import SwiftUI
import Observation

/// A short message about something that just happened.
///
/// Relief spends most of its time working on a file the user is not watching,
/// so every meaningful event has to announce itself. Silence reads as a hang.
struct Toast: Identifiable, Equatable {
    enum Tone: Equatable {
        /// Something happened that the user did not ask about.
        case info
        /// Something the user asked for finished.
        case success
        /// Something the user asked for did not happen.
        case failure
        /// A first run nudge. Stays until acknowledged, because a lesson that
        /// times out before it is read was not taught.
        case guidance
    }

    let id = UUID()
    let tone: Tone
    let title: String
    /// A second line, when the title alone leaves the user guessing what to do.
    var detail: String?
    /// The one thing to do about it, if there is one.
    var actionLabel: String?
    var action: (@MainActor () -> Void)?

    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

/// Holds the toasts currently on screen.
///
/// Successes and notices retire themselves. Failures do not: a message about
/// something that went wrong has to survive the user being out of the room,
/// which is exactly when conversions finish.
@Observable
@MainActor
final class ToastCenter {

    private(set) var toasts: [Toast] = []

    /// Two at a time. A stack taller than this stops being feedback and starts
    /// being a log.
    private let maximumVisible = 2

    func show(_ toast: Toast) {
        toasts.append(toast)
        if toasts.count > maximumVisible {
            toasts.removeFirst(toasts.count - maximumVisible)
        }

        // Failures and guidance both stay put. A message you missed is a
        // message that failed.
        guard toast.tone != .failure, toast.tone != .guidance else { return }
        let id = toast.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Tokens.Motion.toastDwell))
            self?.dismiss(id)
        }
    }

    func dismiss(_ id: Toast.ID) {
        toasts.removeAll { $0.id == id }
    }

    func dismissAll() {
        toasts.removeAll()
    }

    // MARK: Shorthand

    func info(_ title: String, detail: String? = nil) {
        show(Toast(tone: .info, title: title, detail: detail))
    }

    func success(
        _ title: String,
        detail: String? = nil,
        actionLabel: String? = nil,
        action: (@MainActor () -> Void)? = nil
    ) {
        show(Toast(
            tone: .success, title: title, detail: detail,
            actionLabel: actionLabel, action: action
        ))
    }

    func failure(_ title: String, detail: String? = nil) {
        show(Toast(tone: .failure, title: title, detail: detail))
    }

    /// Guidance is exclusive. Two lessons on screen at once is not twice the
    /// teaching, it is a wall of text nobody reads, so a new one replaces
    /// whatever was being taught before.
    func guidance(
        _ title: String,
        detail: String? = nil,
        actionLabel: String? = nil,
        action: (@MainActor () -> Void)? = nil
    ) {
        toasts.removeAll { $0.tone == .guidance }
        show(Toast(
            tone: .guidance, title: title, detail: detail,
            actionLabel: actionLabel, action: action
        ))
    }
}

// MARK: - Presentation

/// The toast stack, bottom leading over the stage.
///
/// It sits above the scrubber rather than centred, so it never covers the
/// picture the user is judging.
struct ToastStack: View {
    let center: ToastCenter

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            ForEach(center.toasts) { toast in
                ToastView(toast: toast) { center.dismiss(toast.id) }
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .animation(Tokens.Motion.toastSpring, value: center.toasts)
        // Hug the bottom leading corner. Without the explicit alignment the
        // stack inherits the overlay's full height and the toasts stretch.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

struct ToastView: View {
    let toast: Toast
    let onDismiss: () -> Void

    @State private var isHovering = false

    private var accentColor: Color {
        switch toast.tone {
        case .info: return Tokens.Palette.textSecondary
        case .success: return Tokens.Palette.accent
        case .failure: return Tokens.Palette.error
        case .guidance: return Tokens.Palette.accent
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s) {
            // A colour bar rather than an icon: it carries the tone without
            // adding a glyph vocabulary the rest of the app does not use.
            RoundedRectangle(cornerRadius: Tokens.Layout.hairlineWidth)
                .fill(accentColor)
                .frame(width: Tokens.Layout.selectionBarWidth)

            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                Text(toast.title)
                    .font(Tokens.Font.bodyMedium)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = toast.detail {
                    Text(detail)
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let label = toast.actionLabel, let action = toast.action {
                    Button(label) {
                        action()
                        onDismiss()
                    }
                    .buttonStyle(.plain)
                    .font(Tokens.Font.bodyMedium)
                    .foregroundStyle(Tokens.Palette.accent)
                    .padding(.top, Tokens.Space.xxs)
                }
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(Tokens.Font.caption)
                    .foregroundStyle(
                        isHovering ? Tokens.Palette.textSecondary : Tokens.Palette.textTertiary
                    )
                    .frame(width: Tokens.Layout.minTarget, height: Tokens.Layout.minTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        // Hug the content vertically. The tone bar has no intrinsic height, so
        // left unconstrained it grows to whatever space the overlay offers and
        // drags the whole toast with it.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, Tokens.Space.s)
        .padding(.leading, Tokens.Space.s)
        .padding(.trailing, Tokens.Space.xxs)
        .frame(width: Tokens.Layout.toastWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.panel)
                .fill(Tokens.Palette.panelRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.panel)
                        .strokeBorder(Tokens.Palette.hairline, lineWidth: Tokens.Layout.hairlineWidth)
                )
        )
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    let center = ToastCenter()
    return ToastStack(center: center)
        .padding(Tokens.Space.m)
        .frame(width: 520, height: 320, alignment: .bottomLeading)
        .background(Tokens.Palette.stage)
        .onAppear {
            center.success(
                "Converted 2023 hike",
                detail: "Ready to watch on the Vision Pro.",
                actionLabel: "Send to Vision Pro"
            ) {}
            center.failure(
                "Couldn't convert beach clip",
                detail: "Relief speaks H.264, HEVC, and ProRes."
            )
        }
}
