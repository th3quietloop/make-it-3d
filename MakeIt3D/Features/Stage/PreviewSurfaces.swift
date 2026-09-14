import SwiftUI
import AppKit
import AVFoundation

/// AVPlayer supplies actual audio/video playback. The transport remains in the
/// shared stage chrome, so original and proof never acquire competing timelines.
struct PreviewPlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    let label: String
    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.setAccessibilityLabel(label)
        return view
    }
    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.setAccessibilityLabel(label)
    }
    final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = playerLayer
            playerLayer.videoGravity = .resizeAspect
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
        }
        required init?(coder: NSCoder) { return nil }
    }
}

/// A stable scroll surface keeps the same inspected region while switching
/// between original, automatic, and the user's settings.
struct PreviewImageSurface: View {
    let image: CGImage
    let nativeSize: Bool
    let label: String
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            if nativeSize {
                ScrollView([.horizontal, .vertical]) {
                    Image(image, scale: 1, label: Text(label))
                        .resizable()
                        .interpolation(.none)
                        .frame(width: CGFloat(image.width) / displayScale, height: CGFloat(image.height) / displayScale)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                }
                .defaultScrollAnchor(.center)
                .accessibilityLabel(label + ", one image pixel per screen pixel. Scroll to inspect.")
            } else {
                Image(image, scale: 1, label: Text(label))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(label)
            }
        }
    }
}
