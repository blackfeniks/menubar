import AppKit

let arguments = CommandLine.arguments
func argument(after flag: String) -> String? {
    arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
}

if arguments.contains("--mic-guard") {
    exit(0)
}
if arguments.contains("--selftest") {
    exit(Selftest.run(fineTuneSample: argument(after: "--fine-tune")))
}
if arguments.contains("--probe") {
    exit(MainActor.assumeIsolated { Probe.run() })
}
if let dir = argument(after: "--snapshot") {
    exit(MainActor.assumeIsolated {
        _ = NSApplication.shared
        return Snapshot.run(dir)
    })
}
if arguments.contains("--acoustic-test") {
    exit(MainActor.assumeIsolated { AcousticTest.run(arguments) })
}
if arguments.contains("--load-test") {
    exit(MainActor.assumeIsolated { LoadTest.run(arguments) })
}
if arguments.contains("--live-test") {
    exit(MainActor.assumeIsolated { LiveTest.run(arguments) })
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
