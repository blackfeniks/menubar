import AppKit
import ServiceManagement
import SwiftUI

@MainActor @Observable
final class MenuPanelModel {
	enum Choice: Hashable { case microphone, unload }

	static let collapsedRows = 3, expandedRows = 8
	static let listOutset: CGFloat = 8
	static let listWidth = MenuPanelView.width - 2 * (Bar.padding - listOutset)
	static let listStyle = BarWheelStyle(leading: listOutset, trailing: 16, bandInset: 0)

	@ObservationIgnored let controller: Controller
	@ObservationIgnored let close: () -> Void
	@ObservationIgnored let hint: (String?, CGFloat) -> Void
	@ObservationIgnored let history: BarWheel?
	@ObservationIgnored let slotHeight: CGFloat
	@ObservationIgnored let choices = BarChoices()

	var historyCount: Int
	var expanded = false
	var minutes: Int
	var microphone: String
	var slotTop: CGFloat = 0
	var settingsBottom: CGFloat = 0

	var choice: Choice? { choices.open as? Choice }
	var picker: BarWheel? { choices.picker }

	init(controller: Controller, items: [HistoryItem]? = nil, close: @escaping () -> Void, hint: @escaping (String?, CGFloat) -> Void) {
		self.controller = controller
		self.close = close
		self.hint = hint
		let items = items ?? controller.history.items
		historyCount = items.count
		minutes = controller.settings.unloadMinutes
		microphone = AudioDevices.resolve(uid: controller.settings.deviceUID)?.name ?? "none"
		let rows = items.enumerated().map { n, h in
			let oneLine = h.text.replacingOccurrences(of: "\n", with: " ")
			let key = n < 3 ? "⌘\(n + 1)" : nil
			let room = Self.listWidth - Self.listStyle.leading - Self.listStyle.trailing - (key == nil ? 0 : 30)
			let cut = (oneLine as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: Bar.text)]).width > room
			return BarWheelRow(title: String(oneLine.prefix(90)), key: key, hint: cut ? h.text : nil) { [weak controller, close] in
				controller?.copy(h)
				close()
			}
		}
		let list = rows.isEmpty ? nil : BarWheel(rows: rows, visible: Self.collapsedRows)
		history = list
		slotHeight = list?.geometry.height ?? 0
		list?.onHover = { [weak self] row in self?.hover(row, on: self?.history) }
		choices.onHover = { [weak self] list, row in self?.hover(row, on: list) }
		choices.onChange = { [weak self] open in
			self?.history?.isActive = !open
			self?.hint(nil, 0)
		}
	}

	private func hover(_ row: Int?, on list: BarWheel?) {
		guard let list, let row, !list.isTurning, let text = list.rows[row].hint, let y = list.screenY(ofRow: row) else {
			hint(nil, 0)
			return
		}
		hint(text, y)
	}

	var canExpand: Bool { historyCount > Self.collapsedRows }

	func toggleExpanded() {
		expanded.toggle()
		history?.setVisible(expanded ? Self.expandedRows : Self.collapsedRows)
		hint(nil, 0)
	}

	func copyRecent(_ index: Int) -> Bool {
		guard let rows = history?.rows, rows.indices.contains(index), historyCount > 0 else { return false }
		rows[index].pick()
		return true
	}

	func clearHistory() {
		controller.history.clear()
		historyCount = 0
		if expanded { toggleExpanded() }
	}

	func open(_ what: Choice) {
		hint(nil, 0)
		switch what {
		case .microphone:
			let current = AudioDevices.resolve(uid: controller.settings.deviceUID)
			let devices = AudioDevices.inputs()
			choices.show(what, titles: devices.map { $0.name + ($0.isBuiltIn ? " (built-in)" : "") },
			             hints: devices.map { $0.isBluetooth ? "Bluetooth headset: while recording, the sound of a call gets worse" : nil },
			             checked: devices.firstIndex { $0.uid == current?.uid }, panelWidth: MenuPanelView.width) { [weak self] i in
				self?.pickMicrophone(devices[i])
			}
		case .unload:
			let options = [1, 3, 5, 10]
			choices.show(what, titles: options.map { "\($0) min" }, checked: options.firstIndex(of: minutes),
			             panelWidth: MenuPanelView.width) { [weak self] i in
				self?.pickMinutes(options[i])
			}
		}
	}

	func dismissChoice() { choices.dismiss() }

	func pickMinutes(_ m: Int) {
		minutes = m
		controller.setUnloadMinutes(m)
	}

	private func pickMicrophone(_ device: InputDevice) {
		controller.settings.deviceUID = AudioDevices.builtIn?.uid == device.uid ? nil : device.uid
		microphone = device.name
	}

	func cancel() {
		if choice != nil {
			dismissChoice()
		} else if expanded {
			toggleExpanded()
		} else {
			close()
		}
	}

	func setLogin(_ on: Bool) {
		do {
			if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
		} catch {
			controller.hud.flash("exclamationmark.triangle", "Couldn't change it: \(error.localizedDescription)", seconds: 3)
		}
	}
}

struct MenuPanelView: View {
	let model: MenuPanelModel

	static let width: CGFloat = 300
	static let padding = Bar.padding

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header.padding(.bottom, 12)
			problems
			BarLine()
			historySection.zIndex(2)
			BarLine()
			settings
			BarLine()
			footer
		}
		.font(.system(size: Bar.text))
		.foregroundStyle(Bar.t1)
		.padding(Self.padding)
		.frame(width: Self.width)
		.barChoices(model.choices, width: Self.width)
		.coordinateSpace(.named("panel"))
	}

	private var header: some View {
		HStack(alignment: .firstTextBaseline) {
			Text("Whisper").font(.system(size: Bar.title, weight: .semibold))
			Spacer()
			if model.controller.state == .processing {
				Text("transcribing…").font(.system(size: Bar.small)).foregroundStyle(Bar.t3)
			}
		}
	}

	@ViewBuilder private var problems: some View {
		let c = model.controller
		if !c.microphoneOK {
			problem("Whisper needs the microphone.", action: "Allow microphone access") {
				c.requestMicrophone()
				model.close()
			}
		}
		if !c.accessibilityOK {
			problem("Whisper needs Accessibility: to catch right ⌥ and to insert the text.", action: "Open Accessibility settings") {
				c.openAccessibilitySettings()
				model.close()
			}
		}
		if !ModelFiles.ready {
			problem("No models in the Models folder.", action: nil) {}
		}
	}

	private func problem(_ text: String, action: String?, run: @escaping () -> Void) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(text).font(.system(size: Bar.small)).foregroundStyle(Bar.red).fixedSize(horizontal: false, vertical: true)
			if let action { Button(action: run) { Text(action).foregroundStyle(Bar.t1) }.buttonStyle(.plain) }
		}
		.padding(.bottom, 12)
	}

	private var historySection: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(alignment: .firstTextBaseline) {
				Text(model.historyCount == 0 ? "Your dictations will appear here" : "Click to copy")
					.font(.system(size: Bar.small)).foregroundStyle(Bar.t3).lineLimit(1)
				Spacer(minLength: 8)
				if model.canExpand {
					Button(action: model.toggleExpanded) {
						Text(model.expanded ? "Less" : "More").font(.system(size: Bar.small)).foregroundStyle(Bar.t2)
					}
					.buttonStyle(.plain)
				}
			}
			.frame(height: 18)
			if let list = model.history, model.historyCount > 0 {
				Color.clear.frame(height: model.slotHeight)
					.onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named("panel")).minY }) { model.slotTop = $0 }
					.overlay(alignment: .top) { wheel(list) }
			}
		}
		.padding(.vertical, 10)
	}

	private func wheel(_ list: BarWheel) -> some View {
		let height = list.geometry.height
		let slot = model.slotHeight
		let unrolled = height > slot + 0.5
		let fullHeight = BarWheelGeometry(count: list.rows.count, visible: Double(list.visibleTarget)).height
		let progress = min(1, (height - slot) / max(1, fullHeight - slot))
		let cover = max(model.settingsBottom - model.slotTop, height + 10)
		let glass = slot + 10 + progress * (cover - slot - 10)
		let outset = MenuPanelModel.listOutset
		return ZStack(alignment: .topLeading) {
			BarWheelRows(rows: list.rows, checked: nil, width: MenuPanelModel.listWidth, style: MenuPanelModel.listStyle, model: list.model)
			BarWheelHost(control: list)
		}
		.frame(width: MenuPanelModel.listWidth, height: height, alignment: .topLeading)
		.background(alignment: .topLeading) {
			if unrolled {
				BarGlass(shape: Rectangle())
					.frame(width: Self.width, height: glass)
					.overlay(alignment: .bottom) { BarLine().padding(.horizontal, Self.padding) }
					.contentShape(Rectangle())
					.onTapGesture {}
					.offset(x: -(Self.padding - outset))
			}
		}
		.padding(.horizontal, -outset)
	}

	private var settings: some View {
		VStack(alignment: .leading, spacing: 8) {
			BarChoiceRow(title: "Microphone", value: model.microphone, id: MenuPanelModel.Choice.microphone, choices: model.choices) {
				model.open(.microphone)
			}
			BarChoiceRow(title: "Unload after", value: "\(model.minutes) min", id: MenuPanelModel.Choice.unload, choices: model.choices) {
				model.open(.unload)
			}
			LoginRow { model.setLogin($0) }
		}
		.padding(.vertical, 12)
		.onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named("panel")).maxY + 0.5 }) { model.settingsBottom = $0 }
	}

	private var footer: some View {
		HStack {
			let clear = model.historyCount == 0 ? "History is empty" : "Clear history · \(model.historyCount)"
			Button(action: model.clearHistory) { Text(clear).foregroundStyle(model.historyCount == 0 ? Bar.t4 : Bar.t2) }
				.buttonStyle(.plain)
				.disabled(model.historyCount == 0)
			Spacer()
			Button(action: { NSApp.terminate(nil) }) { Text("Quit").foregroundStyle(Bar.t2) }
				.buttonStyle(.plain)
		}
		.padding(.top, 12)
	}
}

private struct LoginRow: View {
	let apply: (Bool) -> Void
	@State private var isOn = SMAppService.mainApp.status == .enabled

	var body: some View {
		BarRow(title: "Launch at login") {
			BarSwitch(isOn: $isOn).onChange(of: isOn) { apply(isOn) }
		}
	}
}

@MainActor
final class MenuPanelController {
	private let panel: BarPanel
	private let controller: Controller
	private let bubble = HintBubble()

	init(statusItem: NSStatusItem, controller: Controller) {
		panel = BarPanel(statusItem: statusItem)
		self.controller = controller
	}

	var isOpen: Bool { panel.isOpen }

	func toggle() {
		panel.toggle { [weak self, controller] in
			let model = MenuPanelModel(controller: controller, close: { self?.close() }, hint: { text, y in self?.hint(text, y) })
			var content = BarContent(width: MenuPanelView.width) { MenuPanelView(model: model) }
			content.onCancel = {
				model.cancel()
				return true
			}
			content.onKey = { event in
				guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return false }
				switch event.keyCode {
				case 18: return model.copyRecent(0)
				case 19: return model.copyRecent(1)
				case 20: return model.copyRecent(2)
				case 12:
					NSApp.terminate(nil)
					return true
				default: return false
				}
			}
			content.onClose = { self?.bubble.update(nil, y: 0, beside: .zero, area: .zero) }
			return content
		}
	}

	func close() { panel.close() }

	private func hint(_ text: String?, _ y: CGFloat) {
		guard let text, let glass = panel.glassFrame else {
			bubble.update(nil, y: 0, beside: .zero, area: .zero)
			return
		}
		bubble.update(text, y: y, beside: glass, area: panel.screenArea)
	}
}

@MainActor @Observable
final class HintModel {
	var text: String?
	var top: CGFloat = 0
	var trailing = true
}

private struct HintText: View {
	let text: String

	var body: some View {
		Text(text)
			.font(.system(size: Bar.text))
			.foregroundStyle(Bar.t1)
			.lineSpacing(2.5)
			.lineLimit(18)
			.truncationMode(.tail)
			.fixedSize(horizontal: false, vertical: true)
			.padding(.horizontal, 14)
			.padding(.vertical, 11)
			.frame(width: HintView.width, alignment: .leading)
	}
}

struct HintView: View {
	static let width: CGFloat = 300
	static let corner: CGFloat = 14
	let text: String

	var body: some View {
		HintText(text: text).barGlass(corner: Self.corner).environment(\.colorScheme, .dark)
	}
}

private struct HintLane: View {
	let model: HintModel

	var body: some View {
		ZStack(alignment: model.trailing ? .topTrailing : .topLeading) {
			Color.clear
			if let text = model.text {
				ZStack(alignment: .topLeading) {
					HintText(text: text).id(text).transition(.opacity)
				}
				.barGlass(corner: HintView.corner)
				.padding(.top, model.top)
				.transition(.barDevelop)
			}
		}
		.padding(HintBubble.margin)
		.environment(\.colorScheme, .dark)
		.animation(.smooth(duration: 0.26), value: model.top)
		.animation(.easeOut(duration: 0.18), value: model.text)
	}
}

@MainActor
final class HintBubble {
	private static let delay = 0.14
	private static let gap: CGFloat = 8
	static let margin: CGFloat = 12

	private let model = HintModel()
	private var panel: NSPanel?
	private var pending: DispatchWorkItem?
	private var hiding: DispatchWorkItem?

	func update(_ text: String?, y: CGFloat, beside glass: NSRect, area: NSRect) {
		pending?.cancel()
		pending = nil
		guard let text else {
			hide()
			return
		}
		if model.text != nil {
			present(text, y: y, beside: glass, area: area)
			return
		}
		let work = DispatchWorkItem { [weak self] in
			MainActor.assumeIsolated { self?.present(text, y: y, beside: glass, area: area) }
		}
		pending = work
		DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
	}

	private func present(_ text: String, y: CGFloat, beside glass: NSRect, area: NSRect) {
		hiding?.cancel()
		hiding = nil
		let width = HintView.width + 2 * Self.margin
		let left = glass.minX - Self.gap - HintView.width
		let onLeft = left >= area.minX + 8
		let x = onLeft ? left - Self.margin : glass.maxX + Self.gap - Self.margin
		let lane = NSRect(x: x, y: area.minY, width: width, height: area.height)
		let top = max(0, min(area.maxY - y - 20, area.height - 120) - Self.margin)
		let p = panel ?? makePanel()
		panel = p
		if model.text == nil {
			var still = Transaction()
			still.disablesAnimations = true
			withTransaction(still) {
				model.trailing = onLeft
				model.top = top
			}
			p.setFrame(lane, display: false)
			p.orderFrontRegardless()
		}
		model.top = top
		model.text = text
	}

	private func hide() {
		guard model.text != nil else { return }
		model.text = nil
		let work = DispatchWorkItem { [weak self] in
			MainActor.assumeIsolated { self?.panel?.orderOut(nil) }
		}
		hiding = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
	}

	private func makePanel() -> NSPanel {
		let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
		p.isOpaque = false
		p.backgroundColor = .clear
		p.hasShadow = false
		p.level = .popUpMenu
		p.ignoresMouseEvents = true
		p.isReleasedWhenClosed = false
		p.animationBehavior = .none
		p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
		p.appearance = NSAppearance(named: .darkAqua)
		let host = NSHostingView(rootView: HintLane(model: model))
		host.sizingOptions = []
		p.contentView = host
		return p
	}
}
