import SwiftUI

@main
struct ReliefApp: App {
    @State private var model = AppModel()

    init() {
        // Headless gate. `Relief --selftest [clip ...]` converts the synthetic
        // clip, checks the stereo sign convention, prints the verification
        // report, and exits without ever showing a window.
        //
        // The run loop has to keep turning while this happens: AVFoundation
        // delivers plenty of its work through the main queue, so blocking the
        // main thread on a semaphore here would deadlock the very APIs the test
        // is exercising. Instead the work goes to a detached task and exit()
        // ends the process when it finishes.
        if SelfTest.shouldRun() {
            setvbuf(stdout, nil, _IOLBF, 0)
            let writerProbeOnly = CommandLine.arguments.contains("--writerprobe")
            Task.detached {
                let passed = writerProbeOnly
                    ? await WriterProbe.run()
                    : await SelfTest.run()
                exit(passed ? 0 : 1)
            }
            RunLoop.main.run()
        }
    }

    var body: some Scene {
        Window("Relief", id: "main") {
            RootView(model: model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
    }
}
