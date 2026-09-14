import SwiftUI
import AVFoundation

/// An expanded map of the film. The compact stage stays quiet while this sheet
/// offers recognizable frames and a measured starting point for inspection.
struct ShotReviewSheet: View {
    let sourceURL: URL
    let plan: ShotPlan
    let onSelect: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reviewFirst = true

    private var orderedShots: [Shot] {
        reviewFirst ? plan.shots.sorted {
            $0.inspectionRisk == $1.inspectionRisk ? $0.id < $1.id : $0.inspectionRisk > $1.inspectionRisk
        } : plan.shots
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                    Text("Review shots").font(.title2.weight(.semibold))
                    Text("Choose a moment to inspect at the same place in your preview.")
                        .font(Tokens.Font.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Shot order", selection: $reviewFirst) {
                Text("Review priorities").tag(true)
                Text("Film order").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Tokens.Space.l) {
                    ForEach(orderedShots) { shot in
                        ShotReviewRow(sourceURL: sourceURL, shot: shot, onSelect: onSelect)
                    }
                }
                .padding(.vertical, Tokens.Space.xs)
            }
            Text("Priorities use sampled motion and depth edges. Inspect the moving proof to judge the result.")
                .font(Tokens.Font.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Tokens.Space.l)
        .frame(minWidth: 700, idealWidth: 860, minHeight: 480, idealHeight: 660)
    }
}

private struct ShotReviewRow: View {
    let sourceURL: URL
    let shot: Shot
    let onSelect: (Double) -> Void

    private var times: [Double] {
        let start = shot.start.seconds
        let end = max(start, shot.end.seconds - 1.0 / 60.0)
        let supplied = shot.representativeSeconds.filter { $0 >= start && $0 <= end }
        let values = supplied.isEmpty ? [start, shot.midpoint.seconds, end] : supplied
        return Array(Set(values.map { min(max($0, start), end) })).sorted().prefix(4).map { $0 }
    }
    private var detail: String {
        var notes: [String] = []
        if shot.motionRisk >= 0.35 { notes.append("More motion") }
        if shot.edgeRisk >= 0.35 { notes.append("Pronounced depth edges") }
        if shot.settings.confidence < 0.2 { notes.append("Low depth confidence") }
        return notes.isEmpty ? "No standout inspection signal" : notes.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("Shot \(shot.id + 1)").font(Tokens.Font.bodyMedium)
                Text(PreviewNavigation.timecode(shot.start.seconds))
                    .font(Tokens.Font.monoCaption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(detail).font(Tokens.Font.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: Tokens.Space.xs) {
                ForEach(times, id: \.self) { seconds in
                    ShotReviewThumbnail(sourceURL: sourceURL, seconds: seconds, shotNumber: shot.id + 1) {
                        onSelect(seconds)
                    }
                }
            }
        }
    }
}

private struct ShotReviewThumbnail: View {
    let sourceURL: URL
    let seconds: Double
    let shotNumber: Int
    let action: () -> Void
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                ZStack {
                    Rectangle().fill(.black.opacity(0.2))
                    if let image {
                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    } else if failed {
                        Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(.rect(cornerRadius: Tokens.Radius.control))
                Text(PreviewNavigation.timecode(seconds))
                    .font(Tokens.Font.monoCaption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Inspect shot \(shotNumber) at \(PreviewNavigation.timecode(seconds))")
        .task(id: "\(sourceURL.path):\(seconds)") {
            do {
                let loaded = try await ShotThumbnailLoader.shared.image(url: sourceURL, seconds: seconds)
                try Task.checkCancellation()
                image = loaded.value
            } catch is CancellationError { }
            catch { failed = true }
        }
    }
}

private actor ShotThumbnailLoader {
    static let shared = ShotThumbnailLoader()
    private var generator: AVAssetImageGenerator?
    private var generatorURL: URL?
    private var cache: [String: CGImage] = [:]
    private var cacheOrder: [String] = []

    func image(url: URL, seconds: Double) async throws -> Transfer<CGImage> {
        let key = "\(url.path):\(seconds)"
        if let image = cache[key] { return Transfer(image) }
        let active: AVAssetImageGenerator
        if let generator, generatorURL == url { active = generator }
        else {
            active = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            active.appliesPreferredTrackTransform = true
            active.maximumSize = CGSize(width: 400, height: 225)
            active.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
            active.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
            generator = active
            generatorURL = url
        }
        let result = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Transfer<CGImage>, Error>) in
            active.generateCGImageAsynchronously(for: CMTime(seconds: seconds, preferredTimescale: 600)) { image, _, error in
                if let image { continuation.resume(returning: Transfer(image)) }
                else { continuation.resume(throwing: error ?? PreviewError.decodeFailed) }
            }
        }
        try Task.checkCancellation()
        cache[key] = result.value
        cacheOrder.append(key)
        while cacheOrder.count > 128 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        return result
    }
}
