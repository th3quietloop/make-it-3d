import Foundation
import Metal

// The Mac side of the workbench.
//
// It writes fixtures and runs the gates, against exactly the same format and
// engine code the headset app compiles. That sharing is the whole point: a gate
// that runs against a copy of the code proves something about the copy.
//
// Line buffered so its output appears as it happens rather than in one lump at
// the end, which matters when it is running as a build phase and Xcode is
// deciding whether to show you anything at all.
setvbuf(stdout, nil, _IOLBF, 0)

struct Arguments {
    let command: String
    private let values: [String: String]
    private let flags: Set<String>

    init(_ raw: [String]) {
        var values = [String: String]()
        var flags = Set<String>()
        var command = "gate"

        var index = 0
        var sawCommand = false
        while index < raw.count {
            let token = raw[index]
            if token.hasPrefix("--") {
                let key = String(token.dropFirst(2))
                if index + 1 < raw.count && !raw[index + 1].hasPrefix("--") {
                    values[key] = raw[index + 1]
                    index += 2
                } else {
                    flags.insert(key)
                    index += 1
                }
            } else {
                if !sawCommand {
                    command = token
                    sawCommand = true
                }
                index += 1
            }
        }

        self.command = command
        self.values = values
        self.flags = flags
    }

    func string(_ key: String) -> String? { values[key] }
    func int(_ key: String) -> Int? { values[key].flatMap(Int.init) }
    func flag(_ key: String) -> Bool { flags.contains(key) }
}

func report(_ results: [CheckResult]) -> Bool {
    for result in results { print(result.line) }
    let failures = results.filter { !$0.passed }
    if failures.isEmpty {
        print("\n\(results.count) checks, all passed.")
        return true
    }
    print("\n\(failures.count) of \(results.count) checks failed.")
    return false
}

func workingDirectory(_ arguments: Arguments) throws -> URL {
    if let path = arguments.string("out") {
        let url = URL(filePath: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    let url = URL.temporaryDirectory.appending(path: "makeit3d-gate", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func spec(from arguments: Arguments, defaultFrames: Int) -> DepthTrackSpec {
    DepthTrackSpec(
        width: arguments.int("width") ?? 1920,
        height: arguments.int("height") ?? 1080,
        frameRate: arguments.int("fps") ?? 30,
        frameCount: arguments.int("frames") ?? defaultFrames,
        includeTone: arguments.flag("tone")
    )
}

/// The Metal device and the engine's shaders, compiled from the same source
/// file the app bundles.
func engine(_ arguments: Arguments) throws -> (MTLDevice, MTLLibrary) {
    guard let device = MTLCreateSystemDefaultDevice() else { throw EngineError.noDevice }
    guard let path = arguments.string("metal") else {
        throw CheckAborted(
            check: "Engine",
            reason: "no --metal <path> given, and the gate will not run against a guess."
        )
    }
    let library = try ShaderLibrary.compiling(
        source: URL(filePath: path), device: device
    )
    return (device, library)
}

func usage() {
    print("""
        Usage: DepthTrackTool <command> [options]

        Commands:
          fixture           write a depth track file and stop
          check-format      Phase 0 gate: the file exists and conforms
          check-sign        the stereo sign convention, measured in pixels
          check-alignment   colour and depth stay frame aligned
          gate              every check, in order

        Options:
          --out <dir>       where to work, default a temporary directory
          --width <n>       source width, default 1920
          --height <n>      source height, default 1080
          --fps <n>         frame rate, default 30
          --frames <n>      frame count
          --tone            include an audio tone track
          --metal <path>    the engine's Metal source, needed by check-sign
        """)
}

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
let directory = try workingDirectory(arguments)

switch arguments.command {

case "fixture":
    let clip = try SyntheticDepthClip(spec: spec(from: arguments, defaultFrames: 150))
    let name = arguments.string("name") ?? "fixture.mov"
    let url = directory.appending(path: name)
    _ = try await DepthTrackWriter.write(to: url, source: clip)
    print(url.path(percentEncoded: false))

case "check-format":
    let passed = report(try await FormatCheck.run(
        in: directory, spec: spec(from: arguments, defaultFrames: 150)
    ))
    exit(passed ? 0 : 1)

case "check-sign":
    let (device, library) = try engine(arguments)
    let passed = report(try SignConventionCheck.run(library: library, device: device))
    exit(passed ? 0 : 1)

case "check-alignment":
    let passed = report(try await FrameAlignmentCheck.run(
        in: directory,
        spec: spec(from: arguments, defaultFrames: FrameAlignmentCheck.defaultFrameCount)
    ))
    exit(passed ? 0 : 1)

case "check-pairing":
    let passed = report(try await CompositorPairingCheck.run(
        in: directory, spec: spec(from: arguments, defaultFrames: 300)
    ))
    exit(passed ? 0 : 1)

case "gate":
    let (device, library) = try engine(arguments)
    var results = try await FormatCheck.run(
        in: directory, spec: spec(from: arguments, defaultFrames: 150)
    )
    results += try SignConventionCheck.run(library: library, device: device)
    results += try await CompositorPairingCheck.run(in: directory)
    results += try await FrameAlignmentCheck.run(
        in: directory,
        spec: spec(from: arguments, defaultFrames: FrameAlignmentCheck.defaultFrameCount)
    )
    exit(report(results) ? 0 : 1)

case "help", "--help", "-h":
    usage()

default:
    print("Unknown command \"\(arguments.command)\".\n")
    usage()
    exit(2)
}
