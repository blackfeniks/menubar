import AppKit
import SwiftUI

@Observable
final class HUDModel {
	enum Phase: Equatable { case hidden, recording, processing, done, message }

	var phase: Phase = .hidden
	var handsFree = false
	var paused = false
	var elapsedBase: TimeInterval = 0
	var resumedAt = Date()
	var buttons: [HUDButton: CGRect] = [:]
	var level: Float = 0
	var text = ""
	var draft = ""
	var message = ""
	var symbol = "checkmark"
	@ObservationIgnored var floor: CGFloat = 0
	@ObservationIgnored var pill = CGRect.zero
	@ObservationIgnored var onPillChange: (() -> Void)?
	@ObservationIgnored var glides = false
}

enum HUDButton { case pause, cancel }

final class DraggableHostingView<Content: View>: NSHostingView<Content> {
	var buttonAt: ((CGPoint) -> (() -> Void)?)?

	override func mouseDown(with event: NSEvent) {
		let p = convert(event.locationInWindow, from: nil)
		let topLeft = isFlipped ? p : CGPoint(x: p.x, y: bounds.height - p.y)
		if let action = buttonAt?(topLeft) {
			action()
			return
		}
		window?.performDrag(with: event)
	}
	override var mouseDownCanMoveWindow: Bool { true }
	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

	var onPointer: (() -> Void)?
	private var tracking: NSTrackingArea?

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let tracking { removeTrackingArea(tracking) }
		let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
		                          owner: self, userInfo: nil)
		addTrackingArea(area)
		tracking = area
	}

	override func mouseMoved(with event: NSEvent) { onPointer?() }
	override func mouseEntered(with event: NSEvent) { onPointer?() }
	override func mouseExited(with event: NSEvent) { onPointer?() }
}

@MainActor
final class HUD {
	let model = HUDModel()
	static let width: CGFloat = 480
	static let sheetHeight: CGFloat = 250
	private var panel: NSPanel?
	private var hideWork: DispatchWorkItem?
	private var hideToken = 0
	private var placing = 0
	private var moveObserver: NSObjectProtocol?
	private var saveOrigin: DispatchWorkItem?
	private var mouseMonitors: [Any] = []
	var enabled = true
	var onButton: ((HUDButton) -> Void)?
	var onFrame: ((CGRect?) -> Void)?

	private var pillFrame: NSRect? {
		guard let p = panel, p.isVisible, model.pill.height > 0 else { return nil }
		let f = p.frame
		return NSRect(x: f.minX + model.pill.minX, y: f.maxY - model.pill.maxY, width: model.pill.width, height: model.pill.height)
	}

	private func publishFrame() {
		guard let f = pillFrame, let main = NSScreen.screens.first else {
			onFrame?(nil)
			return
		}
		onFrame?(CGRect(x: f.minX, y: main.frame.height - f.maxY, width: f.width, height: f.height))
	}

	private func updatePassThrough() {
		guard let p = panel else { return }
		let through = !(pillFrame?.contains(NSEvent.mouseLocation) ?? false)
		if p.ignoresMouseEvents != through { p.ignoresMouseEvents = through }
	}

	private func makePanel() -> NSPanel {
		let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width + 12, height: Self.sheetHeight),
		                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
		p.level = .statusBar
		p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
		p.appearance = NSAppearance(named: .darkAqua)
		p.isOpaque = false
		p.backgroundColor = .clear
		p.hasShadow = false
		p.ignoresMouseEvents = true
		p.isMovable = true
		p.isReleasedWhenClosed = false
		p.hidesOnDeactivate = false
		p.animationBehavior = .none
		let h = DraggableHostingView(rootView: HUDSheet(model: model))
		h.sizingOptions = []
		h.buttonAt = { [weak self] point in
			MainActor.assumeIsolated {
				guard let self, self.model.phase == .recording,
				      let button = self.model.buttons.first(where: { $0.value.insetBy(dx: -5, dy: -5).contains(point) })?.key
				else { return nil }
				return { MainActor.assumeIsolated { self.onButton?(button) } }
			}
		}
		h.onPointer = { [weak self] in MainActor.assumeIsolated { self?.updatePassThrough() } }
		p.contentView = h
		model.onPillChange = { [weak self] in
			self?.publishFrame()
			self?.updatePassThrough()
		}
		moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p,
		                                                      queue: .main) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self, self.placing == 0 else { return }
				self.publishFrame()
				self.saveOrigin?.cancel()
				let work = DispatchWorkItem { [weak self] in
					if let f = self?.panel?.frame { Settings.shared.hudOrigin = f.origin }
				}
				self.saveOrigin = work
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
			}
		}
		return p
	}

	private func place(_ p: NSPanel) {
		let size = p.frame.size
		var origin: NSPoint
		var area: NSRect
		if let o = Settings.shared.hudOrigin,
		   let screen = NSScreen.screens.first(where: { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(o) }) {
			(origin, area) = (o, screen.visibleFrame)
		} else {
			let mouse = NSEvent.mouseLocation
			let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
			area = screen.visibleFrame
			origin = NSPoint(x: area.midX - size.width / 2, y: area.minY + 28)
		}
		origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
		origin.y = min(max(origin.y, area.minY), area.maxY - 90)
		placing += 1
		p.setFrameOrigin(origin)
		placing -= 1
	}

	private func show() {
		guard enabled else { return }
		hideWork?.cancel()
		hideToken += 1
		let p = panel ?? makePanel()
		panel = p
		if !p.isVisible {
			model.glides = false
			place(p)
			p.alphaValue = 0
			p.orderFrontRegardless()
			watchMouse()
			publishFrame()
			updatePassThrough()
			let token = hideToken
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
				guard let self, self.hideToken == token else { return }
				self.model.glides = true
			}
		}
		NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
	}

	private func watchMouse() {
		guard mouseMonitors.isEmpty else { return }
		mouseMonitors = [
			NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
				MainActor.assumeIsolated { self?.updatePassThrough() }
			},
		].compactMap { $0 }
	}

	private func unwatchMouse() {
		for m in mouseMonitors { NSEvent.removeMonitor(m) }
		mouseMonitors = []
	}

	func setPaused(_ paused: Bool) {
		guard model.paused != paused else { return }
		if paused {
			model.elapsedBase += Date().timeIntervalSince(model.resumedAt)
		} else {
			model.resumedAt = Date()
		}
		model.paused = paused
		model.level = 0
	}

	func setText(_ preview: DictationSession.Preview) {
		guard model.text != preview.committed || model.draft != preview.draft else { return }
		model.text = preview.committed
		model.draft = preview.draft
	}

	func recording(handsFree: Bool) {
		model.phase = .recording
		model.handsFree = handsFree
		model.paused = false
		model.elapsedBase = 0
		model.resumedAt = Date()
		model.text = ""
		model.draft = ""
		model.level = 0
		model.floor = 0
		show()
	}

	func processing() {
		model.phase = .processing
		show()
	}

	func flash(_ symbol: String, _ message: String, seconds: Double = 1.2) {
		model.phase = .message
		model.symbol = symbol
		model.message = message
		show()
		hide(after: seconds)
	}

	func done(_ text: String) {
		model.phase = .done
		model.text = text
		model.draft = ""
		show()
		hide(after: 1.6)
	}

	func hide(after seconds: Double = 0) {
		hideWork?.cancel()
		let work = DispatchWorkItem { [weak self] in
			guard let self, let p = self.panel else { return }
			if self.pillFrame?.contains(NSEvent.mouseLocation) == true {
				self.hide(after: 0.8)
				return
			}
			self.hideToken += 1
			let token = self.hideToken
			NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; p.animator().alphaValue = 0 }) {
				MainActor.assumeIsolated {
					guard token == self.hideToken else { return }
					p.orderOut(nil)
					p.ignoresMouseEvents = true
					self.model.glides = false
					self.unwatchMouse()
					self.model.phase = .hidden
					self.publishFrame()
				}
			}
		}
		hideWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
	}
}

struct HUDSheet: View {
	let model: HUDModel
	@State private var height: CGFloat?

	var body: some View {
		HUDContent(model: model)
			.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { natural in
				let target = model.phase == .recording ? max(natural, model.floor) : natural
				if model.phase == .recording { model.floor = target }
				if height == nil || !model.glides { height = target } else { withAnimation(.easeOut(duration: 0.18)) { height = target } }
			}
			.frame(height: height, alignment: .top)
			.modifier(HUDGlass())
			.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("pill")) }) { frame in
				model.pill = frame
				model.onPillChange?()
			}
			.padding(6)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
			.coordinateSpace(name: "pill")
			.environment(\.colorScheme, .dark)
			.onPreferenceChange(ButtonRectsKey.self) { rects in
				MainActor.assumeIsolated { model.buttons = rects }
			}
	}
}

struct HUDGlass: ViewModifier {
	func body(content: Content) -> some View {
		content.barGlass(corner: 24)
	}
}

struct HUDView: View {
	let model: HUDModel

	var body: some View {
		HUDContent(model: model).modifier(HUDGlass()).padding(6).environment(\.colorScheme, .dark)
	}
}

struct HUDContent: View {
	let model: HUDModel
	static let red = Color(red: 1, green: 0.3, blue: 0.28)

	var body: some View {
		VStack(alignment: .leading, spacing: 7) {
			HStack(spacing: 8) {
				leading.frame(width: 14, height: 22)
				if model.phase == .recording {
					TimelineView(.periodic(from: model.resumedAt, by: 1)) { ctx in
						Text(Self.clock(model.elapsedBase + (model.paused ? 0 : ctx.date.timeIntervalSince(model.resumedAt))))
							.font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
							.foregroundStyle(.white.opacity(model.paused ? 0.45 : 0.7))
					}
				} else {
					Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Bar.t1).lineLimit(2)
				}
				Spacer(minLength: 0)
				if model.phase == .recording {
					if model.paused {
						button(.cancel, "xmark")
					}
					button(.pause, model.paused ? "play.fill" : "pause.fill")
				}
			}
			if model.phase == .recording || model.phase == .processing {
				ReliefBand(model: model).frame(height: 76).padding(.horizontal, -20).padding(.top, -2).padding(.bottom, -14)
			}
			if let detail {
				detail.font(.system(size: 13)).lineSpacing(1.5)
					.fixedSize(horizontal: false, vertical: true)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
		}
		.padding(.horizontal, 20)
		.padding(.vertical, 14)
		.frame(width: HUD.width)
	}

	private func button(_ kind: HUDButton, _ symbol: String) -> some View {
		Image(systemName: symbol)
			.font(.system(size: 10, weight: .bold))
			.foregroundStyle(.white.opacity(0.9))
			.frame(width: 24, height: 24)
			.background(Circle().fill(.white.opacity(kind == .pause && model.paused ? 0.2 : 0.1)))
			.background(GeometryReader { g in
				Color.clear.preference(key: ButtonRectsKey.self, value: [kind: g.frame(in: .named("pill"))])
			})
	}

	@ViewBuilder private var leading: some View {
		switch model.phase {
		case .recording:
			if model.paused {
				Image(systemName: "pause.fill").foregroundStyle(.white.opacity(0.45)).font(.system(size: 9, weight: .bold))
			} else {
				ZStack {
					Circle().fill(Self.red.opacity(0.25)).frame(width: 7 + 7 * CGFloat(model.level), height: 7 + 7 * CGFloat(model.level))
					Circle().fill(Self.red).frame(width: 7, height: 7)
				}
				.animation(.easeOut(duration: 0.1), value: model.level)
			}
		case .processing: ProgressView().controlSize(.small)
		case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 18))
		case .message: Image(systemName: model.symbol).foregroundStyle(.orange).font(.system(size: 17))
		case .hidden: EmptyView()
		}
	}

	private var title: String {
		switch model.phase {
		case .recording: ""
		case .processing: "Transcribing…"
		case .done: "Inserted"
		case .message: model.message
		case .hidden: ""
		}
	}

	private var detail: Text? {
		let hasText = !model.text.isEmpty || !model.draft.isEmpty
		switch model.phase {
		case .recording where hasText, .processing where hasText, .done where hasText:
			let (bright, dim) = Self.tail(model.text, model.draft)
			return Text("\(Text(bright).foregroundStyle(Bar.t1))\(Text(dim).foregroundStyle(Bar.t2))")
		case .recording:
			let hint = model.paused ? "▶ resume · ⌥ insert · esc cancel"
				: model.handsFree ? "Tap ⌥ to insert the text · esc to cancel" : "Release ⌥ to insert the text · esc to cancel"
			return Text(hint).foregroundStyle(Bar.t3)
		default:
			return nil
		}
	}

	static func tail(_ text: String, limit: Int = tailLimit) -> String {
		guard text.count > limit else { return text }
		let end = String(text.suffix(limit))
		guard let space = end.firstIndex(of: " ") else { return "…" + end }
		return "…" + end[end.index(after: space)...]
	}

	static let tailLimit = 195

	static func tail(_ text: String, _ draft: String, limit: Int = tailLimit) -> (String, String) {
		let full = [text, draft].filter { !$0.isEmpty }.joined(separator: " ")
		let shown = tail(full, limit: limit)
		let body = shown.hasPrefix("…") && full.count > limit ? String(shown.dropFirst()) : shown
		let split = min(body.count, max(0, text.count - (full.count - body.count)))
		let mark = body == shown ? "" : "…"
		return (mark + body.prefix(split), String(body.dropFirst(split)))
	}

	static func clock(_ t: TimeInterval) -> String {
		let s = Int(t)
		return String(format: "%d:%02d", s / 60, s % 60)
	}
}

struct ButtonRectsKey: PreferenceKey {
	static let defaultValue: [HUDButton: CGRect] = [:]
	static func reduce(value: inout [HUDButton: CGRect], nextValue: () -> [HUDButton: CGRect]) {
		value.merge(nextValue()) { $1 }
	}
}

final class ReliefMotion {
	var phase = 0.0
	var energy = 0.0
	var pulse = 0.0
	var lastLevel = 0.0
	var last: Date?
}

struct ReliefBand: View {
	let model: HUDModel
	@State private var motion = ReliefMotion()
	static let runoff: CGFloat = 12

	var body: some View {
		TimelineView(.animation(minimumInterval: nil, paused: model.phase == .hidden)) { timeline in
			Canvas { ctx, size in
				let m = motion
				let dt = min(0.1, m.last.map { timeline.date.timeIntervalSince($0) } ?? 0)
				m.last = timeline.date
				let calm = model.paused ? 1.0 : (model.phase == .processing ? 0.5 : 0)
				let level = calm > 0 ? 0 : Double(model.level)
				if level - m.lastLevel > 0.12 { m.pulse = min(1, m.pulse + level) }
				m.lastLevel = level
				m.energy += (level - m.energy) * (1 - exp(-dt / (level > m.energy ? 0.05 : 0.25)))
				m.pulse *= exp(-dt / 0.35)
				m.phase += dt * (0.35 + 1.4 * m.energy) * (1 - 0.6 * calm)
				Self.draw(ctx, CGSize(width: size.width, height: size.height - Self.runoff), phase: m.phase, energy: m.energy, pulse: m.pulse, calm: calm)
			}
		}
		.mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.14),
		                             .init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
		                     startPoint: .leading, endPoint: .trailing))
		.mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.8),
		                             .init(color: .clear, location: 1)],
		                     startPoint: .top, endPoint: .bottom))
	}

	static func draw(_ ctx: GraphicsContext, _ size: CGSize, phase: Double, energy: Double, pulse: Double, calm: Double) {
		let rows = 13, w = size.width, h = size.height
		for r in 0..<rows {
			let z = CGFloat(r) / CGFloat(rows - 1)
			let depth = 0.35 + 0.65 * z
			let base = 8 + z * (h - 14)
			var line = Path(), cover = Path()
			for i in 0...110 {
				let x = w * CGFloat(i) / 110
				let wx = (x - w / 2) / depth
				let dist = sqrt(wx * wx + pow((0.45 - z) * 380, 2))
				let ring = sin(Double(dist) * 0.045 - phase * 3.2) * exp(-Double(dist) / 260)
				let roll = sin(Double(wx) * 0.021 + phase * 0.54 + Double(r) * 0.4) * 0.5
				let height = CGFloat(ring) * CGFloat(4 + 15 * energy + 7 * pulse) + CGFloat(roll) * 3.5
				let u = max(0, min(1, (min(x, w - x) - 13) / (w * 0.18)))
				let point = CGPoint(x: x, y: base - height * depth * u * u * (3 - 2 * u))
				if i == 0 { line.move(to: point); cover.move(to: point) } else { line.addLine(to: point); cover.addLine(to: point) }
			}
			cover.addLine(to: CGPoint(x: w, y: h + 20))
			cover.addLine(to: CGPoint(x: 0, y: h + 20))
			cover.closeSubpath()
			var eraser = ctx
			eraser.blendMode = .destinationOut
			eraser.fill(cover, with: .color(.black))
			let lit = (1 - 0.4 * calm) * (1 + 0.22 * energy)
			if z > 0.5 {
				ctx.stroke(line, with: .color(.white.opacity(Double(z - 0.5) * (0.07 + 0.11 * energy) * (1 - 0.5 * calm))), lineWidth: 3.6)
			}
			ctx.stroke(line, with: .color(.white.opacity(min(0.96, Double(0.15 + 0.66 * z * z) * lit))), lineWidth: 0.8 + 0.4 * z)
		}
	}
}
