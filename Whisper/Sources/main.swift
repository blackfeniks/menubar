import AppKit

setvbuf(stdout, nil, _IOLBF, 0)
if let code = CLI.run(CommandLine.arguments) {
	exit(code)
}
MainActor.assumeIsolated {
	let app = NSApplication.shared
	let delegate = AppDelegate()
	app.delegate = delegate
	app.setActivationPolicy(.accessory)
	withExtendedLifetime(delegate) { app.run() }
}
