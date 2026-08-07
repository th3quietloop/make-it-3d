import AppKit
import UserNotifications
import Foundation

/// Reaches the user when Make It 3D is not the app they are looking at.
///
/// A feature length conversion runs for an hour. The whole premise is that you
/// walk away, so the completion moment cannot live only inside a window that is
/// behind three others.
@MainActor
enum SystemNotifier {

    private static var isAuthorized = false
    private static var hasAsked = false

    /// Notification permission is asked for at the moment it starts to matter,
    /// which is the first time a conversion begins, not at launch. Asking
    /// before the user has done anything is asking for a no.
    static func prepare() {
        guard !hasAsked, center != nil else { return }
        hasAsked = true
        center?.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in isAuthorized = granted }
        }
    }

    /// nil when there is no bundle identifier to hang notifications off, which
    /// happens if the binary is run outside its app bundle.
    private static var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    static func post(title: String, body: String) {
        // Only when Make It 3D is not frontmost. Notifying about something the user
        // is already watching happen is noise.
        guard !NSApp.isActive, isAuthorized, let center else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        center.add(UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        ))
    }

    /// Bounces the Dock icon once for something that needs attention.
    static func requestAttention() {
        guard !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest)
    }
}

/// Draws conversion progress onto the Dock icon.
///
/// The Compressor convention: a bar across the bottom of the app icon, so the
/// Dock answers "is it still going" without switching apps.
@MainActor
final class DockProgress {

    static let shared = DockProgress()

    private var hostView: NSImageView?
    private let barView = ProgressBarView()

    private init() {}

    /// 0 to 1 while converting, nil to clear.
    var fraction: Double? {
        didSet {
            guard fraction != oldValue else { return }
            apply()
        }
    }

    private func apply() {
        let tile = NSApp.dockTile

        guard let fraction else {
            tile.contentView = nil
            tile.display()
            return
        }

        if hostView == nil {
            let host = NSImageView()
            host.image = NSApp.applicationIconImage
            host.imageScaling = .scaleProportionallyUpOrDown
            host.addSubview(barView)
            hostView = host
        }

        if let hostView {
            barView.fraction = min(max(fraction, 0), 1)
            barView.frame = CGRect(
                x: hostView.bounds.width * 0.12,
                y: hostView.bounds.height * 0.08,
                width: hostView.bounds.width * 0.76,
                height: hostView.bounds.height * 0.08
            )
            tile.contentView = hostView
        }
        tile.display()
    }

    /// The bar itself. Determinate only, per the design file: once a conversion
    /// has started there is a real number to show, so there is never a reason
    /// to show an indeterminate one.
    private final class ProgressBarView: NSView {
        var fraction: Double = 0

        override func draw(_ dirtyRect: NSRect) {
            let radius = bounds.height / 2

            // Track, on the stage colour so it reads as part of the icon.
            let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
            NSColor(srgbRed: 0x10 / 255.0, green: 0x11 / 255.0, blue: 0x14 / 255.0, alpha: 0.85).setFill()
            track.fill()

            guard fraction > 0 else { return }
            let filled = NSRect(
                x: bounds.minX, y: bounds.minY,
                width: max(bounds.width * fraction, bounds.height),
                height: bounds.height
            )
            let fill = NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius)
            // accent #29C4D6, the only colour allowed on chrome.
            NSColor(srgbRed: 0x29 / 255.0, green: 0xC4 / 255.0, blue: 0xD6 / 255.0, alpha: 1).setFill()
            fill.fill()
        }
    }
}
