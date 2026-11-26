import AppKit
import SwiftUI

final class KeyPanel: NSPanel {
	var isOnForm: ((NSPoint) -> Bool)?
	var onMissedClick: (() -> Void)?
	var onLostPaste: (() -> Void)?
	var isGlass: ((NSPoint) -> Bool)?
	var onDragStart: (() -> Void)?
	var onDragMove: (() -> Void)?
	var onDragEnd: (() -> Void)?
	private var dragging = false

	override var canBecomeKey: Bool { true }
	override var canBecomeMain: Bool { false }

	func beginDrag() {
		guard !dragging else { return }
		dragging = true
		onDragStart?()
	}

	func endDrag() {
		guard dragging else { return }
		dragging = false
		onDragEnd?()
	}

	override func performKeyEquivalent(with event: NSEvent) -> Bool {
		if let action = EditKeys.action(for: event) {
			if EditKeys.perform(action, in: self) { return true }
			if action == .paste, let onLostPaste {
				onLostPaste()
				return true
			}
		}
		return super.performKeyEquivalent(with: event)
	}

	override func sendEvent(_ event: NSEvent) {
		if takes(event) { return }
		super.sendEvent(event)
	}

	func takes(_ event: NSEvent) -> Bool {
		switch event.type {
		case .leftMouseDown, .rightMouseDown, .otherMouseDown:
			endDrag()
			if let isOnForm, !isOnForm(event.locationInWindow) {
				onMissedClick?()
				return true
			}
			if event.type == .leftMouseDown, isGlass?(event.locationInWindow) == true { beginDrag() }
		case .leftMouseDragged where dragging:
			onDragMove?()
			return true
		case .leftMouseUp where dragging:
			endDrag()
		default:
			break
		}
		return false
	}
}

@MainActor
final class PictureDrop {
	private let onHover: (Bool) -> Void
	private let onDrop: (NSPasteboard) -> Void

	init(onHover: @escaping (Bool) -> Void, onDrop: @escaping (NSPasteboard) -> Void) {
		self.onHover = onHover
		self.onDrop = onDrop
	}

	func accepts(_ info: NSDraggingInfo) -> Bool { OCR.accepts(info.draggingPasteboard) }

	func over(_ info: NSDraggingInfo) -> NSDragOperation {
		guard accepts(info) else { return [] }
		onHover(true)
		return .copy
	}

	func left() { onHover(false) }

	func dropped(_ info: NSDraggingInfo) -> Bool {
		onHover(false)
		guard accepts(info) else { return false }
		onDrop(info.draggingPasteboard)
		return true
	}
}

final class PanelHostingView<Content: View>: NSHostingView<Content> {
	var drop: PictureDrop?

	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
	override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { drop?.over(sender) ?? [] }
	override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { drop?.over(sender) ?? [] }
	override func draggingExited(_ sender: NSDraggingInfo?) { drop?.left() }
	override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { drop?.dropped(sender) ?? false }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
	let session = Session()
	let ui = PanelUI()
	private var panel: KeyPanel?
	private var hosting: PanelHostingView<PanelRoot>?
	private weak var input: InputTextView?
	private var flagsMonitor: Any?
	private var mouseMonitors: [Any] = []
	private var hintTimer: DispatchWorkItem?
	private var previousApp: NSRunningApplication?
	private var activatedApp = false
	private var pending = false
	private(set) var formHeight: CGFloat = 0
	private var hitHeight: CGFloat = 0
	private var settle: DispatchWorkItem?
	private var pictureRun = 0
	private var room: CGFloat = 0
	private var grab: (pointer: NSPoint, origin: NSPoint, moved: Bool)?
	var screens: () -> [(frame: NSRect, visible: NSRect)] = { NSScreen.screens.map { ($0.frame, $0.visibleFrame) } }
	var pointer: () -> NSPoint = { NSEvent.mouseLocation }
	var onCopied: (() -> Void)?
	var offscreen = false
	private var openOffscreen = false
	var clipboard: (String) -> Void = { text in
		let pb = EditKeys.board
		ClipboardWatch.stop()
		pb.clearContents()
		pb.setString(text, forType: .string)
	}

	var isVisible: Bool { offscreen ? openOffscreen : panel?.isVisible ?? false }
	var hasKeyboard: Bool { offscreen ? openOffscreen : panel?.isKeyWindow ?? false }
	var window: KeyPanel? { panel }
	var inputView: InputTextView? { input }

	override init() {
		super.init()
		session.onCopy = { [weak self] text in self?.copyAndClose(text) }
		session.onClose = { [weak self] in self?.hide() }
		session.onFocusInput = { [weak self] in self?.focusInput() }
		session.onStartOver = { [weak self] in
			self?.ui.thumbnail = nil
			self?.pictureRun += 1
		}
	}

	func showPending() {
		guard !isVisible else { return }
		previousApp = NSWorkspace.shared.frontmostApplication
		session.open(with: nil)
		let p = prepare(at: openingPlace())
		if offscreen { openOffscreen = true } else { p.orderFrontRegardless() }
		ui.animates = true
		if !offscreen { startMouseTracking() }
		pending = true
	}

	func show(selection: String?) {
		let onScreen = isVisible
		pending = false
		if !onScreen { previousApp = NSWorkspace.shared.frontmostApplication }
		session.open(with: selection)
		let p: KeyPanel
		if onScreen, let open = panel { p = open } else { p = prepare(at: openingPlace()) }
		if offscreen {
			openOffscreen = true
		} else {
			p.makeKeyAndOrderFront(nil)
		}
		focusInput()
		if !offscreen && !p.isKeyWindow {
			NSApp.activate(ignoringOtherApps: true)
			activatedApp = true
			p.makeKeyAndOrderFront(nil)
			focusInput()
		}
		ui.animates = true
		if !offscreen {
			startFlagsMonitor()
			startMouseTracking()
		}
		DispatchQueue.main.async { [weak self] in self?.focusInput() }
	}

	private func mouseScreenArea() -> NSRect {
		let all = screens(), mouse = pointer()
		return (all.first { $0.frame.contains(mouse) } ?? all.first)?.visible ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
	}

	func prepare(in area: NSRect) -> KeyPanel { prepare(at: Self.centered(in: area)) }

	private func prepare(at place: Place) -> KeyPanel {
		let p = panel ?? makePanel()
		ui.animates = false
		put(p, at: place)
		for _ in 0..<3 { hosting?.layoutSubtreeIfNeeded() }
		return p
	}

	func hide() {
		pending = false
		guard let p = panel, isVisible else { return }
		p.endDrag()
		stopFlagsMonitor()
		stopMouseTracking()
		if offscreen { openOffscreen = false } else { p.orderOut(nil) }
		ui.animates = false
		ui.pointerOverForm = false
		ui.dropping = false
		p.ignoresMouseEvents = false
		session.closed()
		Engine.shared.scheduleUnload()
		if activatedApp {
			activatedApp = false
			if NSApp.isActive, let app = previousApp {
				NSApp.yieldActivation(to: app)
				app.activate()
			}
		}
	}

	private func copyAndClose(_ text: String) {
		guard isVisible else { return }
		clipboard(text)
		session.startOver(.copied)
		hide()
		onCopied?()
	}

	private func makePanel() -> KeyPanel {
		let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: Look.width + Look.margin.left + Look.margin.right, height: 400),
		                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
		p.isOpaque = false
		p.backgroundColor = .clear
		p.hasShadow = false
		p.level = .floating
		p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
		p.hidesOnDeactivate = false
		p.isMovableByWindowBackground = false
		p.isReleasedWhenClosed = false
		p.acceptsMouseMovedEvents = true
		p.appearance = NSAppearance(named: .darkAqua)
		p.delegate = self
		p.isOnForm = { [weak self] point in
			guard let self, let p = self.panel else { return true }
			return self.takesMouse(at: point, in: NSRect(origin: .zero, size: p.frame.size))
		}
		p.onMissedClick = { [weak self] in self?.updateClickThrough() }
		p.isGlass = { [weak self] point in self?.isGlass(at: point) ?? false }
		p.onDragStart = { [weak self] in self?.dragStarted() }
		p.onDragMove = { [weak self] in self?.dragMoved() }
		p.onDragEnd = { [weak self] in self?.dragEnded() }
		p.onLostPaste = { [weak self] in
			self?.focusInput()
			self?.input?.paste(nil)
		}
		let root = PanelRoot(session: session, ui: ui, onPicture: { [weak self] in self?.picture($0) },
		                     registerInput: { [weak self] field in
		                     	self?.input = field
		                     	field.drop = self?.pictureDrop
		                     	field.updateDragTypeRegistration()
		                     	DispatchQueue.main.async { if self?.isVisible == true { self?.focusInput() } }
		                     },
		                     onFormHeight: { [weak self] in self?.formHeightChanged($0) })
		let h = PanelHostingView(rootView: root)
		h.sizingOptions = []
		h.drop = pictureDrop
		h.registerForDraggedTypes(OCR.dragTypes)
		p.contentView = h
		hosting = h
		panel = p
		return p
	}

	private struct Place {
		var spot: NSPoint
		var area: NSRect
	}

	private static let head: CGFloat = 62
	private static let leastRoom: CGFloat = 160

	private static func centered(in area: NSRect) -> Place {
		Place(spot: NSPoint(x: (area.midX - Look.width / 2).rounded(), y: (area.maxY - area.height * 0.24).rounded()), area: area)
	}

	private func openingPlace() -> Place {
		if let saved = Settings.shared.windowPlace, let place = onScreen(saved) { return place }
		return Self.centered(in: mouseScreenArea())
	}

	private func onScreen(_ spot: NSPoint) -> Place? {
		let row = NSRect(x: spot.x, y: spot.y - Self.head, width: Look.width, height: Self.head)
		func share(_ frame: NSRect) -> CGFloat {
			let common = frame.intersection(row)
			return common.isNull ? 0 : common.width * common.height
		}
		guard let screen = screens().max(by: { share($0.frame) < share($1.frame) }), share(screen.frame) > 0 else { return nil }
		return Place(spot: Self.kept(spot, in: screen.visible), area: screen.visible)
	}

	static func kept(_ spot: NSPoint, in area: NSRect) -> NSPoint {
		let x = max(min(spot.x, area.maxX - Look.width - 8), area.minX + 8)
		let top = min(max(spot.y, area.minY + Look.screenGap + leastRoom), area.maxY - 8)
		return NSPoint(x: x.rounded(), y: top.rounded())
	}

	private func put(_ p: KeyPanel, at place: Place) {
		let m = Look.margin
		room = max(Self.leastRoom, place.spot.y - place.area.minY - Look.screenGap)
		ui.cap = room
		p.setFrame(NSRect(x: place.spot.x - m.left, y: place.spot.y - room - m.bottom,
		                  width: Look.width + m.left + m.right, height: m.top + room + m.bottom), display: isVisible)
	}

	private func formSpot(of p: KeyPanel) -> NSPoint {
		NSPoint(x: p.frame.minX + Look.margin.left, y: p.frame.maxY - Look.margin.top)
	}

	private func isGlass(at point: NSPoint) -> Bool {
		guard let p = panel else { return false }
		let frame = NSRect(origin: .zero, size: p.frame.size)
		guard formRect(in: frame).contains(point), !closeRect(in: frame).contains(point) else { return false }
		return !ui.press.contains(CGPoint(x: point.x - Look.margin.left, y: frame.maxY - Look.margin.top - point.y))
	}

	private func dragStarted() {
		guard let p = panel else { return }
		grab = (pointer(), p.frame.origin, false)
	}

	private func dragMoved() {
		guard let p = panel, var g = grab else { return }
		let now = pointer()
		let dx = now.x - g.pointer.x, dy = now.y - g.pointer.y
		if !g.moved {
			guard abs(dx) >= 3 || abs(dy) >= 3 else { return }
			g.moved = true
			grab = g
		}
		p.setFrameOrigin(NSPoint(x: (g.origin.x + dx).rounded(), y: (g.origin.y + dy).rounded()))
	}

	private func dragEnded() {
		guard let g = grab else { return }
		grab = nil
		guard g.moved, let p = panel else { return }
		let spot = formSpot(of: p)
		let place = onScreen(spot) ?? Place(spot: Self.kept(spot, in: mouseScreenArea()), area: mouseScreenArea())
		put(p, at: place)
		Settings.shared.windowPlace = place.spot
		updateClickThrough()
	}

	private func formRect(in frame: NSRect) -> NSRect {
		NSRect(x: frame.minX + Look.margin.left, y: frame.maxY - Look.margin.top - hitHeight, width: Look.width, height: hitHeight)
	}

	private func closeRect(in frame: NSRect) -> NSRect {
		let c = Look.close
		return NSRect(x: frame.minX + Look.margin.left + c.minX, y: frame.maxY - Look.margin.top - c.maxY, width: c.width, height: c.height)
			.insetBy(dx: -4, dy: -4)
	}

	private func takesMouse(at point: NSPoint, in frame: NSRect) -> Bool {
		formRect(in: frame).contains(point) || closeRect(in: frame).contains(point)
	}

	private func formHeightChanged(_ height: CGFloat) {
		formHeight = height
		settle?.cancel()
		if height < hitHeight && ui.animates {
			let work = DispatchWorkItem { [weak self] in
				guard let self else { return }
				self.hitHeight = self.formHeight
				self.updateClickThrough()
			}
			settle = work
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
		} else {
			hitHeight = height
		}
		updateClickThrough()
	}

	func windowDidMove(_ notification: Notification) { updateCap() }
	func windowDidChangeScreen(_ notification: Notification) { updateCap() }

	private func updateCap() {
		guard let p = panel, p.isVisible, let area = p.screen?.visibleFrame else { return }
		refit(in: area)
	}

	func refit(in area: NSRect) {
		guard let p = panel else { return }
		let cap = max(160, min(room, p.frame.maxY - Look.margin.top - area.minY - Look.screenGap))
		if ui.cap != cap { ui.cap = cap }
	}

	private func startMouseTracking() {
		stopMouseTracking()
		let kinds: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
		                                    .leftMouseUp, .rightMouseUp, .otherMouseUp]
		if let m = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] _ in
			MainActor.assumeIsolated { self?.updateClickThrough() }
		}) { mouseMonitors.append(m) }
		if let m = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { [weak self] event in
			self?.updateClickThrough()
			return event
		}) { mouseMonitors.append(m) }
		scrollSteps = ScrollSteps()
		if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
			guard let self, let p = self.panel, self.formRect(in: p.frame).contains(NSEvent.mouseLocation), self.listOnScreen else { return event }
			let n = self.scrollSteps.steps(event)
			for _ in 0..<abs(n) { _ = self.session.move(n > 0 ? 1 : -1) }
			return nil
		}) { mouseMonitors.append(m) }
		updateClickThrough()
	}

	private var scrollSteps = ScrollSteps()

	private var listOnScreen: Bool {
		switch session.overlay {
		case .history, .alternatives: return true
		case .ask: return false
		case .none: return session.kind == .card && !session.isStale && session.lines.count > 1
		}
	}

	private func stopMouseTracking() {
		for m in mouseMonitors { NSEvent.removeMonitor(m) }
		mouseMonitors = []
	}

	private func updateClickThrough() {
		guard let p = panel, p.isVisible else { return }
		let inside = takesMouse(at: pointer(), in: p.frame)
		if ui.pointerOverForm != inside { ui.pointerOverForm = inside }
		if p.ignoresMouseEvents == inside, inside || NSEvent.pressedMouseButtons == 0 {
			p.ignoresMouseEvents = !inside
		}
	}

	private func focusInput() {
		guard let p = panel, let input else { return }
		if session.overlay == .ask, let ask = Self.editableField(in: p.contentView) {
			if p.firstResponder !== ask.currentEditor() { p.makeFirstResponder(ask) }
			return
		}
		p.makeFirstResponder(input)
	}

	private static func editableField(in view: NSView?) -> NSTextField? {
		guard let view else { return nil }
		if let f = view as? NSTextField, f.isEditable { return f }
		for v in view.subviews { if let f = editableField(in: v) { return f } }
		return nil
	}

	private lazy var pictureDrop = PictureDrop(onHover: { [weak self] in self?.ui.dropping = $0 },
	                                           onDrop: { [weak self] in self?.dropped($0) })

	private func dropped(_ board: NSPasteboard) {
		if !offscreen, let p = panel, !p.isKeyWindow { p.makeKey() }
		focusInput()
		session.pictureStarted()
		pictureRun += 1
		let run = pictureRun
		OCR.read(drag: board) { [weak self] image in
			guard let self, run == self.pictureRun else { return }
			if let image { self.picture(image) } else { self.session.pictureFailed() }
		}
	}

	private func picture(_ image: CGImage) {
		let before = ui.thumbnail
		let thumb = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
		ui.thumbnail = thumb
		session.pictureStarted()
		pictureRun += 1
		let run = pictureRun
		OCR.recognize(image) { [weak self] text in
			guard let self, run == self.pictureRun else { return }
			self.session.picture(text)
			self.ui.thumbnail = text == nil ? before : thumb
			self.focusInput()
		}
	}

	private func startFlagsMonitor() {
		stopFlagsMonitor()
		flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
			guard let self else { return event }
			let held = event.type == .flagsChanged && event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
			self.hintTimer?.cancel()
			if held {
				let work = DispatchWorkItem { [weak self] in self?.ui.commandHeld = true }
				self.hintTimer = work
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
			} else {
				self.ui.commandHeld = false
			}
			return event
		}
	}

	private func stopFlagsMonitor() {
		if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
		flagsMonitor = nil
		hintTimer?.cancel()
		ui.commandHeld = false
	}

	func windowDidResignKey(_ notification: Notification) {
		hintTimer?.cancel()
		ui.commandHeld = false
		session.keyboardLeft()
	}
}
