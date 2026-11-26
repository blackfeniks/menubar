import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	private var statusItem: NSStatusItem!
	private let panel = PanelController()
	private let hotkey = HotkeyMonitor()
	private var settings: BarPanel?
	private var permissionTimer: Timer?
	private var hotkeyOn = false

	func applicationDidFinishLaunching(_ notification: Notification) {
		Engine.shared.idleUnload = TimeInterval(Settings.shared.unloadMinutes * 60)
		if LiveTest.scenarios.isEmpty { panel.session.keep(in: .app) }
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
		statusItem.button?.target = self
		statusItem.button?.action = #selector(iconClicked)
		statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
		settings = BarPanel(statusItem: statusItem)
		hotkey.onTap = { [weak self] in self?.toggleWindow() }
		panel.onCopied = { [weak self] in self?.flashCopied() }
		startHotkey()
		refreshIcon()
		panel.session.onRelaunch = { [weak self] text in self?.relaunch(with: text) }
		if let text = Self.reopenText {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.panel.show(selection: text) }
		}
		if !LiveTest.scenarios.isEmpty { LiveTest.start(self) }
	}

	static var reopenText: String?

	private func relaunch(with text: String) {
		let cfg = NSWorkspace.OpenConfiguration()
		cfg.createsNewApplicationInstance = true
		cfg.arguments = ["--reopen", text]
		let env = ProcessInfo.processInfo.environment
		cfg.environment = ["TRANSLATOR_DIR", "TRANSLATOR_LLM"].reduce(into: [:]) { $0[$1] = env[$1] }
		hotkey.stop()
		panel.hide()
		NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
			DispatchQueue.main.async { NSApp.terminate(nil) }
		}
	}

	var panelForTests: PanelController { panel }

	func applicationWillTerminate(_ notification: Notification) {
		hotkey.stop()
		panel.session.saveNow()
	}

	private func startHotkey() {
		if Selection.accessibilityGranted, hotkey.start() {
			hotkeyOn = true
			permissionTimer?.invalidate()
			permissionTimer = nil
		} else if permissionTimer == nil {
			Selection.requestAccessibility()
			permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
				MainActor.assumeIsolated {
					guard let self, Selection.accessibilityGranted else { return }
					self.startHotkey()
					self.refreshIcon()
				}
			}
		}
	}

	private var capture: CancelToken?
	private var earlyShow: DispatchWorkItem?

	func toggleWindow() {
		if let ticket = capture {
			ticket.cancel()
			capture = nil
			earlyShow?.cancel()
			earlyShow = nil
			_ = hotkey.releaseKeys()
			panel.hide()
			return
		}
		if panel.hasKeyboard {
			panel.hide()
			return
		}
		settings?.close()
		guard Settings.shared.translateSelection else {
			panel.show(selection: nil)
			return
		}
		let ticket = CancelToken()
		capture = ticket
		hotkey.holdKeys(for: 1.5)
		let early = DispatchWorkItem { [weak self] in self?.panel.showPending() }
		earlyShow = early
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: early)
		Selection.capture(front: NSWorkspace.shared.frontmostApplication, ticket: ticket) { [weak self] text in
			guard let self, self.capture === ticket else { return }
			self.capture = nil
			early.cancel()
			self.earlyShow = nil
			self.panel.show(selection: text)
			let typed = self.hotkey.releaseKeys()
			DispatchQueue.main.async {
				for e in typed { if let event = NSEvent(cgEvent: e) { NSApp.postEvent(event, atStart: false) } }
			}
		}
	}

	private func refreshIcon(copied: Bool = false) {
		let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .light)
		let image = copied || !hotkeyOn
			? NSImage(systemSymbolName: copied ? "checkmark" : "exclamationmark.triangle", accessibilityDescription: "Translator")?
				.withSymbolConfiguration(config)
			: Self.monogram
		image?.isTemplate = true
		statusItem.button?.image = image
		statusItem.button?.toolTip = hotkeyOn ? "Translator — right ⌘" : "Translator needs Accessibility access"
	}

	private static let monogram: NSImage? = {
		let image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Translator")?
			.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .light))
		image?.isTemplate = true
		return image
	}()

	private func flashCopied() {
		refreshIcon(copied: true)
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.refreshIcon() }
	}

	@objc private func iconClicked() {
		if NSApp.currentEvent?.type == .rightMouseUp {
			settings?.close(animated: false)
			let menu = NSMenu()
			let open = NSMenuItem(title: "Open Translator", action: #selector(openFromMenu), keyEquivalent: "")
			open.target = self
			menu.addItem(open)
			menu.addItem(.separator())
			menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
			statusItem.menu = menu
			statusItem.button?.performClick(nil)
			statusItem.menu = nil
			return
		}
		toggleSettings()
	}

	@objc private func openFromMenu() {
		DispatchQueue.main.async { [weak self] in self?.panel.show(selection: nil) }
	}

	private func toggleSettings() {
		settings?.toggle { [weak self, hotkeyOn] in
			let model = SettingsModel(hotkeyOn: hotkeyOn) {
				self?.settings?.close()
				NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
			}
			var content = BarContent(width: SettingsView.width) { SettingsView(model: model) }
			content.onCancel = { model.cancel() }
			content.onKey = { event in
				guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.keyCode == 12 else { return false }
				NSApp.terminate(nil)
				return true
			}
			return content
		}
	}
}

@MainActor @Observable
final class SettingsModel {
	enum Choice: Hashable { case unload }
	static let unloadOptions = [1, 3, 5, 10]

	@ObservationIgnored let hotkeyOn: Bool
	@ObservationIgnored let onOpenAccessibility: () -> Void
	@ObservationIgnored let choices = BarChoices()
	var selection = Settings.shared.translateSelection {
		didSet { Settings.shared.translateSelection = selection }
	}
	var minutes = Settings.shared.unloadMinutes
	var atLogin = SMAppService.mainApp.status == .enabled {
		didSet { if atLogin { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() } }
	}
	var historyCount: Int

	init(hotkeyOn: Bool, historyCount: Int = History.shared.items.count, onOpenAccessibility: @escaping () -> Void) {
		self.hotkeyOn = hotkeyOn
		self.historyCount = historyCount
		self.onOpenAccessibility = onOpenAccessibility
	}

	func openUnload() {
		let options = Self.unloadOptions
		choices.show(Choice.unload, titles: options.map { "\($0) min" }, checked: options.firstIndex(of: minutes),
		             panelWidth: SettingsView.width) { [weak self] i in
			self?.minutes = options[i]
			Settings.shared.unloadMinutes = options[i]
			Engine.shared.idleUnload = TimeInterval(options[i] * 60)
		}
	}

	func clearHistory() {
		History.shared.clear()
		historyCount = 0
	}

	func cancel() -> Bool {
		guard choices.open != nil else { return false }
		choices.dismiss()
		return true
	}
}

struct SettingsView: View {
	@Bindable var model: SettingsModel

	static let width: CGFloat = 300
	private static let noAccess = "The hotkey needs Accessibility: turn Translator on in the list."
	private static let openAccess = "Open Accessibility settings"

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(alignment: .firstTextBaseline) {
				Text("Translator").font(.system(size: Bar.title, weight: .semibold))
					.rowLabel("settings", "Translator", edge: .leading("side"))
				Spacer()
			}
			.padding(.bottom, 12)
			if !model.hotkeyOn {
				VStack(alignment: .leading, spacing: 6) {
					Text(Self.noAccess)
						.font(.system(size: Bar.small)).foregroundStyle(Bar.red)
						.rowWrapping("settings", Self.noAccess, size: Bar.small, column: Self.width - 2 * Bar.padding, edge: .leading("side"))
						.fixedSize(horizontal: false, vertical: true)
					Button(action: model.onOpenAccessibility) { Text(Self.openAccess).foregroundStyle(Bar.t1) }
						.buttonStyle(.plain)
						.rowLabel("settings", Self.openAccess, edge: .leading("side"))
				}
				.padding(.bottom, 12)
			}
			BarLine()
			VStack(alignment: .leading, spacing: 8) {
				setting("Translate selection") { BarRow(title: $0) { BarSwitch(isOn: $model.selection) } }
				setting("Unload after") {
					BarChoiceRow(title: $0, value: "\(model.minutes) min", id: SettingsModel.Choice.unload, choices: model.choices) { model.openUnload() }
				}
				setting("Launch at login") { BarRow(title: $0) { BarSwitch(isOn: $model.atLogin) } }
			}
			.padding(.vertical, 12)
			BarLine()
			HStack {
				let clear = model.historyCount == 0 ? "History is empty" : "Clear history · \(model.historyCount)"
				Button(action: model.clearHistory) { Text(clear).foregroundStyle(model.historyCount == 0 ? Bar.t4 : Bar.t2) }
					.buttonStyle(.plain)
					.disabled(model.historyCount == 0)
					.rowLabel("settings", clear, edge: .leading("side"))
				Spacer()
				Button(action: { NSApp.terminate(nil) }) { Text("Quit").foregroundStyle(Bar.t2) }
					.buttonStyle(.plain)
					.rowLabel("settings", "Quit", edge: .trailing("side"))
			}
			.padding(.top, 12)
		}
		.font(.system(size: Bar.text))
		.foregroundStyle(Bar.t1)
		.padding(Bar.padding)
		.frame(width: Self.width)
		.barChoices(model.choices, width: Self.width)
		.coordinateSpace(.named(RowCheck.space))
	}

	private func setting(_ title: String, @ViewBuilder row: (String) -> some View) -> some View {
		row(title).rowProbe(RowCheck.Item(row: "settings", kind: .label, text: title, edge: .leading("side")))
	}
}
