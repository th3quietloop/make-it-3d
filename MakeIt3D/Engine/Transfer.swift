import CoreMedia
import CoreVideo
import CoreGraphics

/// Ownership handoff for Core Foundation media types, which are deliberately
/// not Sendable.
///
/// The engine's rule is that a pixel buffer is owned by exactly one task at a
/// time. Where a buffer genuinely changes hands (an actor returning a rendered
/// frame to the caller that will display it), the sender drops its reference at
/// the moment of transfer and never reads or mutates the payload again. That
/// discipline, not the type system, is what makes this safe, so the box is kept
/// deliberately small and is never used to share a buffer between two live
/// readers.
struct Transfer<Payload>: @unchecked Sendable {
    let value: Payload

    init(_ value: Payload) {
        self.value = value
    }
}

/// A synthesized stereo pair leaving the engine.
struct StereoPair: @unchecked Sendable {
    let left: CVPixelBuffer
    let right: CVPixelBuffer
    let time: CMTime
}
