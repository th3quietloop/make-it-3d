import Foundation
import AVFoundation
import CoreMedia

/// The film, broken into shots, each with its own depth settings.
///
/// One strength dial for a whole film is one exposure for a whole film. A
/// feature cuts between a face two feet from the lens and a valley two miles
/// away, and those want different depth. The engine already found the cuts, it
/// just used them for one small job: resetting the temporal blend so depth did
/// not smear across an edit. This turns them into the unit of tuning.
struct Shot: Equatable, Sendable, Identifiable {
    let id: Int
    /// Where this shot starts and ends in the source.
    let start: CMTime
    let end: CMTime
    /// What the model saw across this shot, averaged over its samples.
    let content: DepthContent
    /// The settings solved for this shot.
    let settings: AutoTune.Result

    var duration: CMTime { end - start }

    /// A time inside this shot worth showing as its representative frame.
    var midpoint: CMTime { start + CMTimeMultiplyByFloat64(duration, multiplier: 0.5) }
}

/// The whole plan for one file.
struct ShotPlan: Equatable, Sendable {
    let shots: [Shot]
    /// How many frames were read to build it.
    let samplesTaken: Int
    /// How long the analysis ran.
    let seconds: Double

    var isEmpty: Bool { shots.isEmpty }

    /// The shot covering a given time, for the inspector and the engine.
    func shot(at time: CMTime) -> Shot? {
        shots.first { $0.start <= time && time < $0.end } ?? shots.last
    }

    /// One line summary for the UI.
    var summary: String {
        guard !shots.isEmpty else { return "No shots found." }
        if shots.count == 1 { return "One continuous shot." }
        let flat = shots.filter { $0.settings.confidence < 0.12 }.count
        if flat == 0 { return "\(shots.count) shots, each tuned on its own." }
        return "\(shots.count) shots, each tuned on its own. \(flat) with little real depth."
    }
}

/// Builds a ShotPlan by sampling a file.
///
/// Sampling, not decoding every frame. A depth pass over a whole feature is the
/// conversion itself; the plan has to be cheap enough to run before someone
/// decides whether to convert at all. Two samples a second finds any cut that
/// matters and costs seconds rather than hours.
enum ShotPlanner {

    /// How often to sample, in seconds.
    static let sampleInterval = 0.5

    /// How different two consecutive frames have to look to count as a cut.
    ///
    /// This compares luma histograms, not depth statistics. The first version
    /// compared depth spread, on the theory that a cut reorganises the depth
    /// histogram more than a camera move does. Measured on a five second
    /// handheld clip of one continuous shot, depth spread went 1.4, 3.0, 2.8,
    /// 6.3, and the planner reported four shots in a clip that has one. Depth
    /// is far too jumpy frame to frame to detect anything.
    ///
    /// Luma histogram intersection is the standard signal for this and it is
    /// stable under camera movement, which is exactly the property that was
    /// missing. The threshold is deliberately conservative: under segmenting
    /// degrades to roughly today's behaviour, one setting across a run of
    /// shots, while over segmenting makes depth change where the picture does
    /// not, which is visible and unpleasant.
    static let cutThreshold = 0.45

    /// Never plan more shots than this. A film with a cut every second is a
    /// trailer, and past a point the per shot table costs more than it earns.
    static let maximumShots = 400

    static func plan(
        for probe: SourceProbe,
        estimator: CoreMLDepthEstimator,
        tuning: EngineTuning,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> ShotPlan {
        let began = Date()
        let asset = AVURLAsset(url: probe.url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return ShotPlan(shots: [], samplesTaken: 0, seconds: 0)
        }

        let duration = probe.duration
        let total = max(Int(duration.seconds / sampleInterval), 1)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: sampleInterval / 2, preferredTimescale: 600)
        // Small frames. Depth statistics do not need pixels, and this is the
        // difference between a plan that takes seconds and one that takes
        // minutes.
        generator.maximumSize = CGSize(width: 384, height: 384)
        _ = track

        let stabilizer = Stabilizer(tuning: tuning)
        var samples: [Sample] = []

        for index in 0..<total {
            if Task.isCancelled { break }
            let time = CMTime(seconds: Double(index) * sampleInterval, preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image else { continue }
            guard let buffer = pixelBuffer(from: image) else { continue }
            let luma = lumaHistogram(from: buffer)
            guard let nearness = try? estimator.nearness(from: buffer) else { continue }
            _ = stabilizer.normalize(nearness)
            samples.append(Sample(time: time, content: stabilizer.lastContent, luma: luma))
            progress(Double(index + 1) / Double(total))
        }

        guard !samples.isEmpty else {
            return ShotPlan(shots: [], samplesTaken: 0, seconds: Date().timeIntervalSince(began))
        }

        let boundaries = cuts(in: samples)
        var shots: [Shot] = []
        for (index, range) in boundaries.enumerated() {
            let slice = samples[range]
            let content = DepthContent.averaging(slice.map(\.content))
            let start = slice.first?.time ?? .zero
            let end = range.upperBound < samples.count ? samples[range.upperBound].time : duration
            shots.append(
                Shot(
                    id: index,
                    start: start,
                    end: end,
                    content: content,
                    settings: AutoTune.settings(for: content)
                )
            )
        }

        return ShotPlan(
            shots: shots,
            samplesTaken: samples.count,
            seconds: Date().timeIntervalSince(began)
        )
    }

    /// One sampled instant: when, what the depth looked like, and what the
    /// picture looked like.
    private struct Sample {
        let time: CMTime
        let content: DepthContent
        let luma: [Float]
    }

    /// Splits the samples into runs wherever the picture changes wholesale.
    private static func cuts(in samples: [Sample]) -> [Range<Int>] {
        guard samples.count > 1 else { return [0..<samples.count] }

        var boundaries: [Int] = [0]
        for index in 1..<samples.count {
            let distance = 1 - histogramIntersection(samples[index - 1].luma, samples[index].luma)
            if distance > cutThreshold {
                boundaries.append(index)
            }
            if boundaries.count >= maximumShots { break }
        }
        boundaries.append(samples.count)

        return (0..<boundaries.count - 1).map { boundaries[$0]..<boundaries[$0 + 1] }
    }

    /// How much two normalized histograms overlap, 1 identical, 0 disjoint.
    private static func histogramIntersection(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var total: Float = 0
        for index in 0..<a.count { total += min(a[index], b[index]) }
        return Double(total)
    }

    /// A 64 bin normalized luma histogram, from a BGRA buffer.
    ///
    /// Coarse on purpose. Fine bins make a histogram sensitive to exposure
    /// drift and grain, which is the opposite of what a cut detector wants.
    private static func lumaHistogram(from buffer: CVPixelBuffer) -> [Float] {
        let binCount = 64
        var histogram = [Float](repeating: 0, count: binCount)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return histogram }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        // Every fourth pixel in each direction. A histogram does not need
        // every sample and this runs on every sampled frame of a feature.
        var counted = 0
        for y in Swift.stride(from: 0, to: height, by: 4) {
            let row = pixels + y * stride
            for x in Swift.stride(from: 0, to: width, by: 4) {
                let pixel = row + x * 4
                // BGRA, Rec. 601 luma.
                let luma = 0.114 * Float(pixel[0]) + 0.587 * Float(pixel[1]) + 0.299 * Float(pixel[2])
                let bin = min(Int(luma * Float(binCount) / 256), binCount - 1)
                histogram[bin] += 1
                counted += 1
            }
        }

        guard counted > 0 else { return histogram }
        let scale = 1 / Float(counted)
        return histogram.map { $0 * scale }
    }

    /// CGImage to a pixel buffer the estimator can eat.
    private static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let width = image.width
        let height = image.height
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
