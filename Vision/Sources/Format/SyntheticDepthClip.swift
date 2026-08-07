import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// A conforming depth track file, made from nothing.
///
/// This exists before any player does, for three reasons. It removes the
/// dependency on the Mac app being finished. It gives the reader something real
/// to eat on day one. And it is the regression fixture forever: every number it
/// produces is known in advance, so a check can assert rather than admire.
///
/// The picture is a box translating over a gradient, which is the trick the Mac
/// app used, plus a binary frame index strip along the top of both the colour
/// and the depth raster so frame alignment can be measured.
///
/// Unchecked Sendable because it is pure. Every frame is a function of its
/// index and nothing else, so the two video pumps can call it from their own
/// queues at the same time. The one piece of state, the tone, is touched only
/// from the audio pump.
final class SyntheticDepthClip: DepthTrackFrameSource, @unchecked Sendable {

    let spec: DepthTrackSpec
    private let plans: [ShotPlan]
    private let tone: ToneTrack?

    init(spec: DepthTrackSpec) throws {
        self.spec = spec
        self.plans = Self.makePlans(for: spec)
        self.tone = spec.includeTone
            ? try ToneTrack(durationSeconds: Double(spec.frameCount) / Double(spec.frameRate))
            : nil
    }

    // MARK: Shots

    /// One shot's character.
    ///
    /// Nearness runs 0 far to 1 near, in the film's shared depth space. Each
    /// shot deliberately occupies a different slice of that space, because the
    /// whole point of per shot normalization is that a cut between two
    /// differently ranged shots must not flash.
    private struct ShotPlan {
        let index: Int
        let firstFrame: Int
        let frameCount: Int
        /// Background nearness at the top of the frame and at the bottom.
        let backgroundTop: Double
        let backgroundBottom: Double
        let boxNearness: Double
        let boxSizeFraction: Double
        let strength: Double
        let convergence: Double

        var lastFrame: Int { firstFrame + frameCount - 1 }
        /// The inner square, a little further away, so the box has structure
        /// rather than being a flat patch.
        var innerNearness: Double { boxNearness - 0.06 }

        var nearest: Double { max(backgroundTop, max(backgroundBottom, boxNearness)) }
        var farthest: Double { min(backgroundTop, min(backgroundBottom, innerNearness)) }
        var span: Double { max(nearest - farthest, 0.001) }

        func contains(frame index: Int) -> Bool {
            index >= firstFrame && index <= lastFrame
        }

        /// Where the box sits across this shot, 0 at the first frame and 1 at
        /// the last.
        func progress(atFrame index: Int) -> Double {
            guard frameCount > 1 else { return 0 }
            return Double(index - firstFrame) / Double(frameCount - 1)
        }
    }

    /// Four characters, cycled, so a clip of any length has cuts in it and
    /// consecutive shots never share a depth range.
    private static let characters: [(top: Double, bottom: Double, box: Double, size: Double, strength: Double, convergence: Double)] = [
        (top: 0.10, bottom: 0.35, box: 0.88, size: 0.32, strength: 0.016, convergence: 0.45),
        (top: 0.20, bottom: 0.50, box: 0.95, size: 0.24, strength: 0.024, convergence: 0.55),
        (top: 0.05, bottom: 0.20, box: 0.70, size: 0.40, strength: 0.010, convergence: 0.35),
        (top: 0.30, bottom: 0.60, box: 0.85, size: 0.28, strength: 0.016, convergence: 0.50)
    ]

    private static func makePlans(for spec: DepthTrackSpec) -> [ShotPlan] {
        let count = max(1, min(8, spec.frameCount / 45))
        let base = spec.frameCount / count
        let remainder = spec.frameCount % count

        var plans = [ShotPlan]()
        var cursor = 0
        for index in 0..<count {
            // The remainder goes to the early shots one frame at a time, so the
            // shots together cover every frame with no gap and no overlap.
            let length = base + (index < remainder ? 1 : 0)
            let character = characters[index % characters.count]
            plans.append(ShotPlan(
                index: index,
                firstFrame: cursor,
                frameCount: length,
                backgroundTop: character.top,
                backgroundBottom: character.bottom,
                boxNearness: character.box,
                boxSizeFraction: character.size,
                strength: character.strength,
                convergence: character.convergence
            ))
            cursor += length
        }
        return plans
    }

    private func plan(forFrame index: Int) -> ShotPlan {
        // Linear rather than binary: a feature length film has tens of shots,
        // not thousands, and a loop that is obviously correct beats a search
        // that is nearly correct.
        for plan in plans where plan.contains(frame: index) { return plan }
        return plans[plans.count - 1]
    }

    /// How much of the comfort budget a shot spends.
    ///
    /// The Mac app owns the real definition of this number. What the fixture
    /// owes is a value in the right shape and the right range, computed the
    /// same way every time, so a check can assert it round trips.
    private static let comfortBudgetFraction = 0.01
    /// Forward pop is the expensive direction for the eyes, so it is halved
    /// before it counts against the budget. This matches the Mac engine's
    /// `forwardPopScale`.
    private static let forwardPopScale = 0.5

    var shots: [Shot] {
        plans.map { plan in
            let start = spec.time(ofFrame: plan.firstFrame)
            let end = spec.time(ofFrame: plan.lastFrame + 1)
            let forwardPop = max(0, plan.strength * Self.forwardPopScale * (plan.nearest - plan.convergence))
            return Shot(
                timeRange: CMTimeRange(start: start, end: end),
                metadata: ShotMetadata(
                    shot: plan.index,
                    // shared = stored / 255 * depthScale + depthOffset
                    depthScale: plan.span,
                    depthOffset: plan.farthest,
                    suggestedStrength: plan.strength,
                    suggestedConvergence: plan.convergence,
                    comfortLoad: forwardPop / Self.comfortBudgetFraction
                )
            )
        }
    }

    // MARK: Colour

    func colorFrame(at index: Int) throws -> CVPixelBuffer {
        let plan = plan(forFrame: index)
        let buffer = try PixelBuffers.makeColor(width: spec.width, height: spec.height)

        try PixelBuffers.withLock(buffer) {
            guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                throw PixelBufferError.notAddressable
            }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

            let space = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                data: base,
                width: spec.width,
                height: spec.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                throw PixelBufferError.notAddressable
            }

            // CoreGraphics puts its origin at the bottom left, which is the
            // last row in memory. The gradient is therefore built bottom first:
            // location 0 is the bottom of the picture.
            let colours = [
                Self.surfaceColour(nearness: plan.backgroundBottom),
                Self.surfaceColour(nearness: plan.backgroundTop)
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: colours, locations: [0, 1]) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: 0, y: spec.height),
                    options: []
                )
            }

            let box = boxRect(plan: plan, index: index)
            context.setFillColor(Self.surfaceColour(nearness: plan.boxNearness))
            context.fill(Self.flipped(box, inHeight: spec.height))

            context.setFillColor(Self.surfaceColour(nearness: plan.innerNearness))
            context.fill(Self.flipped(Self.inner(of: box), inHeight: spec.height))

            // Stamped straight into memory afterwards, so row 0 is the visual
            // top and there is no question about which way up it is.
            try FrameIndexStrip.stamp(
                index: index,
                intoBGRA: base,
                bytesPerRow: bytesPerRow,
                width: spec.width,
                height: spec.height
            )
        }

        return buffer
    }

    /// A desaturated blue grey whose lightness tracks nearness, so the picture
    /// and the depth map agree with each other without the picture becoming a
    /// grey ramp.
    private static func surfaceColour(nearness: Double) -> CGColor {
        let level = 0.08 + 0.84 * min(max(nearness, 0), 1)
        return CGColor(red: level * 0.94, green: level * 0.97, blue: level, alpha: 1)
    }

    /// The box, in raster coordinates where row 0 is the top of the picture.
    private func boxRect(plan: ShotPlan, index: Int) -> CGRect {
        let size = Double(spec.height) * plan.boxSizeFraction
        let travel = Double(spec.width) - size * 2
        let x = size * 0.5 + travel * plan.progress(atFrame: index)
        let y = (Double(spec.height) - size) * 0.5
        return CGRect(x: x, y: y, width: size, height: size)
    }

    private static func inner(of box: CGRect) -> CGRect {
        box.insetBy(dx: box.width * 0.3, dy: box.height * 0.3)
    }

    /// Raster coordinates to CoreGraphics coordinates.
    private static func flipped(_ rect: CGRect, inHeight height: Int) -> CGRect {
        CGRect(
            x: rect.minX,
            y: Double(height) - rect.minY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: Depth

    func depthFrame(at index: Int) throws -> CVPixelBuffer {
        let plan = plan(forFrame: index)
        let buffer = try PixelBuffers.makeDepth(width: spec.depthWidth, height: spec.depthHeight)

        try PixelBuffers.withLock(buffer) {
            guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                  let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
                throw PixelBufferError.notAddressable
            }
            let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)

            // The box in depth space: the same rectangle, scaled to the depth
            // raster. Scaling the rectangle rather than the raster keeps the
            // depth edge exactly on the picture edge, which is what a real
            // depth track from the Mac would also have.
            let scaleX = Double(spec.depthWidth) / Double(spec.width)
            let scaleY = Double(spec.depthHeight) / Double(spec.height)
            let box = boxRect(plan: plan, index: index)
            let scaledBox = CGRect(
                x: box.minX * scaleX, y: box.minY * scaleY,
                width: box.width * scaleX, height: box.height * scaleY
            )
            let scaledInner = Self.inner(of: scaledBox)

            let lastRow = max(spec.depthHeight - 1, 1)
            for y in 0..<spec.depthHeight {
                let row = luma.advanced(by: y * lumaStride).assumingMemoryBound(to: UInt8.self)
                let down = Double(y) / Double(lastRow)
                let background = plan.backgroundTop + (plan.backgroundBottom - plan.backgroundTop) * down
                let backgroundLevel = Self.level(nearness: background, plan: plan)

                for x in 0..<spec.depthWidth {
                    let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                    if scaledInner.contains(point) {
                        row[x] = Self.level(nearness: plan.innerNearness, plan: plan)
                    } else if scaledBox.contains(point) {
                        row[x] = Self.level(nearness: plan.boxNearness, plan: plan)
                    } else {
                        row[x] = backgroundLevel
                    }
                }
            }

            // Neutral chroma. The contract says chroma is ignored, and 128 is
            // what "ignored" has to look like: anything else tints a decoder
            // that converts to RGB before the player reads the luma.
            for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
                let row = chroma.advanced(by: y * chromaStride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<(CVPixelBufferGetWidthOfPlane(buffer, 1) * 2) {
                    row[x] = 128
                }
            }

            try FrameIndexStrip.stamp(
                index: index,
                intoLuma: luma,
                bytesPerRow: lumaStride,
                width: spec.depthWidth,
                height: spec.depthHeight
            )
        }

        return buffer
    }

    /// Nearness in the film's shared space to this shot's stored 0...255.
    ///
    /// This is the per shot normalization the format asks for, and its inverse
    /// is exactly `stored / 255 * depthScale + depthOffset` with the scale and
    /// offset this clip writes into the metadata track.
    private static func level(nearness: Double, plan: ShotPlan) -> UInt8 {
        let normalized = min(max((nearness - plan.farthest) / plan.span, 0), 1)
        // Derived from the contract's own two named levels rather than from a
        // literal 255, so a change to the format cannot leave this behind.
        let floor = Double(DepthTrack.farthestLevel)
        let span = Double(DepthTrack.nearestLevel) - floor
        return UInt8((floor + normalized * span).rounded())
    }

    // MARK: Tone

    func toneChunk() throws -> CMSampleBuffer? {
        try tone?.nextChunk()
    }
}
