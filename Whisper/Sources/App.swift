import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	let controller = Controller()
	private var statusItem: NSStatusItem!
	private lazy var menuPanel = MenuPanelController(statusItem: statusItem, controller: controller)

	func applicationDidFinishLaunching(_ notification: Notification) {
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
		statusItem.button?.target = self
		statusItem.button?.action = #selector(iconClicked)
		statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
		controller.onChange = { [weak self] in
			guard let self else { return }
			self.refreshIcon()
			if self.controller.state == .recording { self.menuPanel.close() }
		}
		AudioDevices.observeChanges { [weak self] in self?.refreshIcon() }
		controller.start()
		refreshIcon()
	}

	func applicationWillTerminate(_ notification: Notification) {
		controller.shutdown()
	}

	private func refreshIcon() {
		guard let button = statusItem?.button else { return }
		let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
		var name = "mic"
		let tint: NSColor? = nil
		switch controller.state {
		case .recording:
			name = "record.circle.fill"
		case .processing:
			break
		case .idle:
			if !controller.accessibilityOK || !controller.microphoneOK || !ModelFiles.ready {
				name = "mic.badge.xmark"
			}
		}
		let image = NSImage(systemSymbolName: name, accessibilityDescription: "Whisper")?.withSymbolConfiguration(config)
		image?.isTemplate = tint == nil
		button.image = image
		button.contentTintColor = tint
		button.toolTip = statusLine
	}

	private var statusLine: String {
		switch controller.state {
		case .recording: return "Recording"
		case .processing: return "Transcribing…"
		case .idle:
			if !controller.microphoneOK { return "Microphone access is needed" }
			if !controller.accessibilityOK { return "Accessibility access is needed" }
			if !ModelFiles.ready { return "No models in the Models folder" }
			return "Right ⌥: hold and talk · tap for hands-free"
		}
	}

	@objc private func iconClicked() { menuPanel.toggle() }
}
