import AppKit
import CoreGraphics
import Foundation

/// Draws the app icon.
///
/// The icon is the stereo fuse at 1024px: two rounded frames, one vermilion and
/// one cyan, offset horizontally and screen blended so the overlap resolves to
/// near white. Same story as the completion moment in the queue, same two
/// colours, same reason. On the stage colour, in the macOS icon shape.
///
/// Run `Relief --makeicon` to regenerate the asset catalog.
enum IconRenderer {

    /// macOS icons sit inside a rounded square with a margin, rather than
    /// bleeding to the edge of the canvas.
    private static let contentInsetRatio: CGFloat = 100.0 / 1024.0
    private static let cornerRadiusRatio: CGFloat = 185.0 / 1024.0

    /// Frame geometry, as fractions of the icon edge.
    private static let frameWidthRatio: CGFloat = 0.46
    private static let frameHeightRatio: CGFloat = 0.30
    private static let frameOffsetRatio: CGFloat = 0.055
    private static let frameStrokeRatio: CGFloat = 0.030
    private static let frameCornerRatio: CGFloat = 0.030

    static func render(size: Int) -> CGImage? {
        let edge = CGFloat(size)
        let colourSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colourSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .high

        // MARK: The icon plate

        let inset = edge * contentInsetRatio
        let plate = CGRect(x: inset, y: inset, width: edge - inset * 2, height: edge - inset * 2)
        let platePath = CGPath(
            roundedRect: plate,
            cornerWidth: edge * cornerRadiusRatio,
            cornerHeight: edge * cornerRadiusRatio,
            transform: nil
        )
        context.addPath(platePath)
        // stage: #101114. Off black, never pure black.
        context.setFillColor(CGColor(red: 0x10 / 255.0, green: 0x11 / 255.0, blue: 0x14 / 255.0, alpha: 1))
        context.fillPath()

        // Everything after this is clipped to the plate.
        context.saveGState()
        context.addPath(platePath)
        context.clip()

        // MARK: The two eye frames

        let frameSize = CGSize(width: edge * frameWidthRatio, height: edge * frameHeightRatio)
        let offset = edge * frameOffsetRatio
        let stroke = max(edge * frameStrokeRatio, 1)
        let corner = edge * frameCornerRatio
        let centre = CGPoint(x: edge / 2, y: edge / 2)

        func framePath(shiftedBy dx: CGFloat) -> CGPath {
            let rect = CGRect(
                x: centre.x - frameSize.width / 2 + dx,
                y: centre.y - frameSize.height / 2,
                width: frameSize.width,
                height: frameSize.height
            )
            return CGPath(
                roundedRect: rect.insetBy(dx: stroke / 2, dy: stroke / 2),
                cornerWidth: corner,
                cornerHeight: corner,
                transform: nil
            )
        }

        context.setLineWidth(stroke)
        context.setLineJoin(.round)

        // Screen blending is what does the work: where vermilion and cyan
        // overlap they resolve to near white, which is the fuse.
        context.setBlendMode(.normal)
        context.addPath(framePath(shiftedBy: -offset))
        // stereoL: #FF4F42
        context.setStrokeColor(CGColor(red: 0xFF / 255.0, green: 0x4F / 255.0, blue: 0x42 / 255.0, alpha: 1))
        context.strokePath()

        context.setBlendMode(.screen)
        context.addPath(framePath(shiftedBy: offset))
        // accent: #29C4D6
        context.setStrokeColor(CGColor(red: 0x29 / 255.0, green: 0xC4 / 255.0, blue: 0xD6 / 255.0, alpha: 1))
        context.strokePath()

        context.restoreGState()
        return context.makeImage()
    }

    // MARK: Asset catalog

    /// Every size a macOS app icon set needs, as (pixel size, filename).
    private static let variants: [(points: Int, scale: Int)] = [
        (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
        (256, 1), (256, 2), (512, 1), (512, 2)
    ]

    static func writeAppIconSet(to catalogURL: URL) throws {
        let iconSet = catalogURL.appendingPathComponent("AppIcon.appiconset")
        try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

        var images: [[String: String]] = []

        for variant in variants {
            let pixels = variant.points * variant.scale
            let name = "icon_\(variant.points)x\(variant.points)\(variant.scale == 2 ? "@2x" : "").png"

            // Drawn natively at each size rather than downscaled from 1024, so
            // the stroke stays crisp at 16pt where it matters most.
            guard let image = render(size: pixels) else {
                throw IconError.renderFailed(pixels)
            }
            let representation = NSBitmapImageRep(cgImage: image)
            guard let data = representation.representation(using: .png, properties: [:]) else {
                throw IconError.encodeFailed(pixels)
            }
            try data.write(to: iconSet.appendingPathComponent(name))

            images.append([
                "size": "\(variant.points)x\(variant.points)",
                "idiom": "mac",
                "filename": name,
                "scale": "\(variant.scale)x"
            ])
        }

        let contents: [String: Any] = [
            "images": images,
            "info": ["version": 1, "author": "xcode"]
        ]
        let data = try JSONSerialization.data(
            withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: iconSet.appendingPathComponent("Contents.json"))

        // The catalog itself needs a manifest too.
        let catalogInfo: [String: Any] = ["info": ["version": 1, "author": "xcode"]]
        let catalogData = try JSONSerialization.data(
            withJSONObject: catalogInfo, options: [.prettyPrinted, .sortedKeys]
        )
        try catalogData.write(to: catalogURL.appendingPathComponent("Contents.json"))
    }

    /// Writes a 1024px master and an .iconset directory, then asks iconutil to
    /// pack it into an .icns.
    static func writeIconSetAndICNS(to directory: URL) throws {
        let iconSetURL = directory.appendingPathComponent("Relief.iconset")
        try FileManager.default.createDirectory(at: iconSetURL, withIntermediateDirectories: true)

        let iconutilSizes: [(name: String, pixels: Int)] = [
            ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
        ]

        for entry in iconutilSizes {
            guard let image = render(size: entry.pixels) else {
                throw IconError.renderFailed(entry.pixels)
            }
            let representation = NSBitmapImageRep(cgImage: image)
            guard let data = representation.representation(using: .png, properties: [:]) else {
                throw IconError.encodeFailed(entry.pixels)
            }
            try data.write(to: iconSetURL.appendingPathComponent(entry.name))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = [
            "-c", "icns", iconSetURL.path,
            "-o", directory.appendingPathComponent("Relief.icns").path
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw IconError.iconutilFailed(process.terminationStatus)
        }
    }

    enum IconError: LocalizedError {
        case renderFailed(Int)
        case encodeFailed(Int)
        case iconutilFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .renderFailed(let size): return "Couldn't draw the icon at \(size)px."
            case .encodeFailed(let size): return "Couldn't encode the icon at \(size)px."
            case .iconutilFailed(let code): return "iconutil failed with status \(code)."
            }
        }
    }

    /// `Relief --makeicon [catalog path]`
    static func runFromCommandLine() -> Bool {
        let arguments = CommandLine.arguments
        let catalogPath = arguments.firstIndex(of: "--makeicon")
            .flatMap { index -> String? in
                let next = index + 1
                guard next < arguments.count, !arguments[next].hasPrefix("--") else { return nil }
                return arguments[next]
            }

        let catalogURL = URL(fileURLWithPath: catalogPath ?? FileManager.default.currentDirectoryPath
            + "/Relief/Resources/Assets.xcassets")

        // The .iconset and .icns are build artifacts, not app resources. They
        // go beside the project rather than inside it: dropping them next to
        // the asset catalog put a second Relief.icns in the target and the
        // build failed with two commands producing the same file.
        let artifactsURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Icon", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)
            try writeAppIconSet(to: catalogURL)
            try FileManager.default.createDirectory(at: artifactsURL, withIntermediateDirectories: true)
            try writeIconSetAndICNS(to: artifactsURL)
            print("Wrote the app icon set to \(catalogURL.path)")
            print("Wrote Relief.icns to \(artifactsURL.path)")
            return true
        } catch {
            print("Icon generation failed: \(error.localizedDescription)")
            return false
        }
    }
}
