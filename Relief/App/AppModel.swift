import SwiftUI
import Observation
import AVFoundation
import UniformTypeIdentifiers

/// One file's journey through Relief.
@Observable
@MainActor
final class Conversion: Identifiable {
    enum Status: Equatable {
        case probing
        case ready
        case converting(fraction: Double, framesDone: Int)
        case done(outputURL: URL)
        case failed(String)

        var isConverting: Bool {
            if case .converting = self { return true }
            return false
        }

        var isDone: Bool {
            if case .done = self { return true }
            return false
        }

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    let id = UUID()
    let sourceURL: URL
    var status: Status = .probing
    var probe: SourceProbe?
    var thumbnail: CGImage?
    var report: VerificationReport?

    /// Live settings for this conversion. Export freezes a snapshot onto
    /// `exportedTuning`, so re-exporting with new settings is a new pass rather
    /// than a mutation of the finished one.
    var tuning: EngineTuning = .default
    var exportedTuning: EngineTuning?

    /// A finished row whose settings have since changed offers a re-export.
    var settingsChangedSinceExport: Bool {
        guard let exportedTuning, status.isDone else { return false }
        return exportedTuning != tuning
    }

    var displayName: String { sourceURL.deletingPathExtension().lastPathComponent }

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }
}

/// The root of the app: the queue, the selection, and the settings.
@Observable
@MainActor
final class AppModel {

    var conversions: [Conversion] = []
    var selectionID: Conversion.ID?

    /// Set when the depth model could not be loaded, so the UI can say so
    /// rather than failing one conversion at a time.
    var modelBanner: String?

    var outputFolder: URL = FileManager.default.urls(
        for: .moviesDirectory, in: .userDomainMask
    ).first ?? FileManager.default.homeDirectoryForCurrentUser

    /// Filename pattern for exports. `{name}` is replaced with the source name.
    var filenamePattern: String = "{name}_spatial"

    private var conversionTask: Task<Void, Never>?

    var selection: Conversion? {
        guard let selectionID else { return nil }
        return conversions.first { $0.id == selectionID }
    }

    var isConverting: Bool {
        conversions.contains { $0.status.isConverting }
    }

    static let supportedTypes: [UTType] = [.movie, .quickTimeMovie, .mpeg4Movie, .video]

    init() {
        checkModelAvailability()
    }

    private func checkModelAvailability() {
        if CoreMLDepthEstimator.bundledModelURL() == nil {
            modelBanner = "The depth model is missing. Relief can't read depth without it."
        }
    }

    // MARK: Queue

    func add(urls: [URL]) {
        for url in urls {
            guard !conversions.contains(where: { $0.sourceURL == url }) else { continue }
            let conversion = Conversion(sourceURL: url)
            conversions.append(conversion)
            if selectionID == nil { selectionID = conversion.id }
            probe(conversion)
        }
    }

    func remove(_ conversion: Conversion) {
        guard !conversion.status.isConverting else { return }
        conversions.removeAll { $0.id == conversion.id }
        if selectionID == conversion.id { selectionID = conversions.first?.id }
    }

    private func probe(_ conversion: Conversion) {
        Task { [weak self] in
            do {
                let probe = try await Ingest.probe(url: conversion.sourceURL)
                let thumbnailTime = CMTime(seconds: probe.duration.seconds * 0.25, preferredTimescale: 600)
                conversion.probe = probe
                conversion.status = .ready

                if let image = try? await Ingest.image(
                    at: thumbnailTime, url: conversion.sourceURL, maxSize: 256
                ) {
                    conversion.thumbnail = image.value
                }
            } catch {
                conversion.status = .failed(error.localizedDescription)
            }
            _ = self
        }
    }

    // MARK: Output naming

    func outputURL(for conversion: Conversion) -> URL {
        let name = filenamePattern.replacingOccurrences(of: "{name}", with: conversion.displayName)
        var candidate = outputFolder.appendingPathComponent(name).appendingPathExtension("mov")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = outputFolder
                .appendingPathComponent("\(name) \(suffix)")
                .appendingPathExtension("mov")
            suffix += 1
        }
        return candidate
    }

    // MARK: Conversion

    /// Converts everything that is Ready, one at a time. Sequential on purpose:
    /// the model and the GPU are the bottleneck, so running two at once would
    /// make both slower and the progress meaningless.
    func convertAllReady() {
        guard conversionTask == nil else { return }
        let queue = conversions.filter { $0.status.isReady || $0.settingsChangedSinceExport }
        guard !queue.isEmpty else { return }

        conversionTask = Task { [weak self] in
            for conversion in queue {
                guard let self, !Task.isCancelled else { break }
                await self.convert(conversion)
            }
            self?.conversionTask = nil
        }
    }

    func convertSelected() {
        guard let selection else { return }
        guard conversionTask == nil else { return }
        conversionTask = Task { [weak self] in
            await self?.convert(selection)
            self?.conversionTask = nil
        }
    }

    private func convert(_ conversion: Conversion) async {
        guard let probe = conversion.probe else { return }

        let request = ConversionRequest(
            probe: probe,
            tuning: conversion.tuning,
            outputURL: outputURL(for: conversion)
        )
        let frozenTuning = conversion.tuning
        conversion.status = .converting(fraction: 0, framesDone: 0)
        conversion.report = nil

        // The pipeline runs off the main actor. Events come back onto it, so
        // the UI only ever sees a consistent snapshot.
        let stream = AsyncStream<ConversionEvent> { continuation in
            Task.detached {
                await ConversionController.run(request) { event in
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }

        for await event in stream {
            switch event {
            case .started:
                conversion.status = .converting(fraction: 0, framesDone: 0)
            case .progress(let fraction, let framesDone):
                conversion.status = .converting(fraction: fraction, framesDone: framesDone)
            case .finished(let report):
                conversion.report = report
                conversion.exportedTuning = frozenTuning
                conversion.status = .done(outputURL: report.outputURL)
                print(report.text)
            case .failed(let message):
                conversion.status = .failed(message)
            case .cancelled:
                // A cancelled row returns to Ready with its settings intact.
                conversion.status = .ready
            }
        }
    }

    func cancelConversion() {
        conversionTask?.cancel()
        conversionTask = nil
    }

    // MARK: Reveal and share

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
