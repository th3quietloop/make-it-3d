import Foundation
import AVFoundation

/// Explicit lifetime wrappers keep app services and test-created controllers
/// from leaving time/notification observers behind after they are released.
final class PreviewNotificationObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol
    init(center: NotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }
    deinit { center.removeObserver(token) }
}

final class PreviewPeriodicObservation: @unchecked Sendable {
    private let player: AVPlayer
    private let token: Any
    init(player: AVPlayer, token: Any) {
        self.player = player
        self.token = token
    }
    deinit { player.removeTimeObserver(token) }
}
