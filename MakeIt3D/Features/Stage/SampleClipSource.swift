import Foundation

/// Attribution travels in the bundle and is visible from the sample's stage.
enum SampleClipSource {
    static let resourceName = "ForestMorning"
    static let resourceExtension = "mp4"
    static let title = "Forest morning · Big Buck Bunny"
    static let credit = "(c) copyright 2008, Blender Foundation / www.bigbuckbunny.org"
    static let license = "Creative Commons Attribution 3.0"
    static let sourceURL = URL(string: "https://peach.blender.org/about/")!
    static let licenseURL = URL(string: "https://creativecommons.org/licenses/by/3.0/")!

    static var bundledURL: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: resourceExtension)
            ?? Bundle.main.url(forResource: resourceName, withExtension: resourceExtension, subdirectory: "Samples")
    }

    static func isSample(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent == resourceName
    }
}
