import AppKit
import SwiftUI

enum Bar {
	static let corner: CGFloat = 18
	static let gap: CGFloat = 6
	static let margin: CGFloat = 16
	static let padding: CGFloat = 16

	static let glassDim: Double = 0.44

	static let t1 = Color(.sRGB, red: 0.96, green: 0.96, blue: 0.97)
	static let t2 = Color.white.opacity(0.62)
	static let t3 = Color.white.opacity(0.42)
	static let t4 = Color.white.opacity(0.27)
	static let red = Color(.sRGB, red: 1, green: 0.48, blue: 0.43)
	static let border = Color.white.opacity(0.13)
	static let hairline = Color.white.opacity(0.09)
	static let selection = Color.white.opacity(0.085)

	static let text: CGFloat = 13.5
	static let small: CGFloat = 12.5
	static let title: CGFloat = 14.5
	static let row: CGFloat = 26

	nonisolated(unsafe) static var offscreen = false
}

struct BarGlass<S: Shape>: View {
	var shape: S
	var dim = Bar.glassDim

	var body: some View {
		if Bar.offscreen {
			shape.fill(Color(white: 0.085))
		} else {
			ZStack {
				BarBlur()
				Color.black.opacity(dim)
			}
			.clipShape(shape)
		}
	}
}

private final class BarBlurView: NSVisualEffectView {
	override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct BarBlur: NSViewRepresentable {
	func makeNSView(context: Context) -> NSVisualEffectView {
		let v = BarBlurView()
		v.blendingMode = .behindWindow
		v.material = .hudWindow
		v.state = .active
		v.appearance = NSAppearance(named: .darkAqua)
		return v
	}

	func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

extension View {
	func barGlass(corner: CGFloat = Bar.corner, dim: Double = Bar.glassDim) -> some View {
		let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
		return background(BarGlass(shape: shape, dim: dim))
			.clipShape(shape)
			.overlay(shape.strokeBorder(Bar.border, lineWidth: 0.5))
	}
}

struct BarLine: View {
	var body: some View { Rectangle().fill(Bar.hairline).frame(height: 0.5) }
}

struct BarSwitch: View {
	@Binding var isOn: Bool
	var disabled = false

	var body: some View {
		Toggle("", isOn: $isOn)
			.labelsHidden()
			.toggleStyle(.switch)
			.controlSize(.small)
			.tint(Color(white: 0.8))
			.disabled(disabled)
	}
}

struct BarRow<Control: View>: View {
	let title: String
	@ViewBuilder var control: Control

	var body: some View {
		HStack(spacing: 0) {
			Text(title).lineLimit(1).fixedSize()
			Spacer(minLength: 12)
			control
		}
		.frame(height: Bar.row)
	}
}

private struct BarDevelopFX: ViewModifier {
	var p: Double

	func body(content: Content) -> some View {
		content.blur(radius: CGFloat((1 - p) * 5)).opacity(p).offset(y: CGFloat((1 - p) * 5))
	}
}

extension AnyTransition {
	static var barDevelop: AnyTransition {
		.asymmetric(insertion: .modifier(active: BarDevelopFX(p: 0), identity: BarDevelopFX(p: 1)).animation(.easeOut(duration: 0.26)),
		            removal: .modifier(active: BarDevelopFX(p: 0), identity: BarDevelopFX(p: 1)).animation(.easeIn(duration: 0.14)))
	}
}

struct BarContent {
	var view: AnyView
	var width: CGFloat
	var spare: CGFloat = 0
	var onCancel: (() -> Bool)?
	var onKey: ((NSEvent) -> Bool)?
	var onScroll: ((NSEvent) -> Bool)?
	var onClose: (() -> Void)?
	var staysForDrags = false

	init<V: View>(width: CGFloat, spare: CGFloat = 0, @ViewBuilder view: () -> V) {
		self.view = AnyView(view())
		self.width = width
		self.spare = spare
	}
}

private struct BarChrome: View {
	let content: BarContent
	let onResize: (CGSize) -> Void

	var body: some View {
		content.view
			.frame(width: content.width, alignment: .topLeading)
			.fixedSize(horizontal: false, vertical: true)
			.barGlass()
			.onGeometryChange(for: CGSize.self, of: { $0.size }) { onResize($0) }
			.padding(.top, Bar.gap)
			.padding([.horizontal, .bottom], Bar.margin)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
			.environment(\.colorScheme, .dark)
	}
}

private final class BarWindow: NSPanel {
	init(content: NSView) {
		super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
		contentView = content
		isFloatingPanel = true
		level = .popUpMenu
		isOpaque = false
		backgroundColor = .clear
		ignoresMouseEvents = true
		acceptsMouseMovedEvents = true
		hasShadow = false
		hidesOnDeactivate = false
		isReleasedWhenClosed = false
		animationBehavior = .none
		collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
		appearance = NSAppearance(named: .darkAqua)
	}

	override var canBecomeKey: Bool { true }
	override var canBecomeMain: Bool { false }
}

@MainActor
final class BarPanel {
	private let statusItem: NSStatusItem
	private var window: BarWindow?
	private var content: BarContent?
	private var monitors: [Any] = []
	private var glassSize = CGSize.zero
	private var shrinkWork: DispatchWorkItem?
	private var latency: NSObjectProtocol?
	private var dismissed: (at: TimeInterval, point: NSPoint)?
	private var pressedAt: NSPoint?

	init(statusItem: NSStatusItem) {
		self.statusItem = statusItem
		let workspace = NSWorkspace.shared.notificationCenter
		workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
			let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
			guard app?.processIdentifier != getpid() else { return }
			MainActor.assumeIsolated {
				guard let self, self.content?.staysForDrags != true else { return }
				self.dismiss()
			}
		}
		workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.close(animated: false) }
		}
		NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.close(animated: false) }
		}
	}

	var isOpen: Bool { window != nil }

	func toggle(_ make: () -> BarContent?) {
		if isOpen {
			close()
		} else if wasDismissedByThisClick {
			dismissed = nil
		} else if let content = make() {
			open(content)
		}
	}

	private var wasDismissedByThisClick: Bool {
		guard let d = dismissed else { return false }
		let p = NSEvent.mouseLocation
		return ProcessInfo.processInfo.systemUptime - d.at < 1 && abs(p.x - d.point.x) < 4 && abs(p.y - d.point.y) < 4
	}

	private var screen: NSScreen? { statusItem.button?.window?.screen ?? NSScreen.main }

	private var iconFrame: NSRect? {
		guard let button = statusItem.button, let window = button.window else { return nil }
		return window.convertToScreen(button.convert(button.bounds, to: nil))
	}

	private var iconColumn: NSRect? {
		guard let icon = iconFrame, let screen else { return nil }
		let bottom = min(icon.minY, screen.visibleFrame.maxY)
		return NSRect(x: icon.minX - Self.itemPadding, y: bottom, width: icon.width + 2 * Self.itemPadding,
		              height: screen.frame.maxY - bottom + 1)
	}

	private static let itemPadding: CGFloat = 7

	private func frame(glassWidth: CGFloat, height: CGFloat, under icon: NSRect) -> NSRect {
		let area = screen?.visibleFrame ?? icon
		let scale = screen?.backingScaleFactor ?? 2
		let glassX = min(max(icon.midX - glassWidth / 2, area.minX + 8), area.maxX - glassWidth - 8)
		let top = min(icon.minY, area.maxY)
		let x = ((glassX - Bar.margin) * scale).rounded() / scale
		let whole = height.rounded(.up)
		return NSRect(x: x, y: top.rounded() - whole, width: glassWidth + 2 * Bar.margin, height: whole)
	}

	var glassFrame: NSRect? {
		guard let window else { return nil }
		let w = window.frame
		return NSRect(x: w.minX + Bar.margin, y: w.maxY - Bar.gap - glassSize.height, width: glassSize.width, height: glassSize.height)
	}

	var screenArea: NSRect { screen?.visibleFrame ?? .zero }

	func open(_ content: BarContent) {
		guard window == nil, let icon = iconFrame else { return }
		dismissed = nil
		let hosting = NSHostingController(rootView: BarChrome(content: content) { [weak self] size in
			self?.glassResized(size)
		})
		hosting.sizingOptions = []
		let window = BarWindow(content: hosting.view)
		let fitting = hosting.sizeThatFits(in: .zero)
		guard fitting.width > 0, fitting.height > 0 else { return }
		glassSize = CGSize(width: content.width, height: fitting.height - Bar.gap - Bar.margin)
		let target = frame(glassWidth: content.width, height: fitting.height + content.spare, under: icon)
		window.setFrame(target.offsetBy(dx: 0, dy: 8), display: false)

		self.window = window
		self.content = content
		latency = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
		                                                reason: "Menu-bar panel open")
		updatePassThrough()
		window.alphaValue = 0
		window.makeKeyAndOrderFront(nil)
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.26
			context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
			window.animator().alphaValue = 1
			window.animator().setFrame(target, display: false)
		}
		statusItem.button?.highlight(true)

		monitors = [
			NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
				MainActor.assumeIsolated { self?.updatePassThrough() }
			},
			NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
				MainActor.assumeIsolated { self?.updatePassThrough() }
				return event
			},
			NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
				MainActor.assumeIsolated {
					guard let self, !(self.iconColumn?.contains(NSEvent.mouseLocation) ?? false) else { return }
					if self.content?.staysForDrags == true {
						self.pressedAt = NSEvent.mouseLocation
					} else {
						self.dismiss()
					}
				}
			},
			NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]) { [weak self] _ in
				MainActor.assumeIsolated {
					guard let self, let pressed = self.pressedAt else { return }
					self.pressedAt = nil
					let p = NSEvent.mouseLocation
					if abs(p.x - pressed.x) < 4, abs(p.y - pressed.y) < 4 { self.dismiss() }
				}
			},
			NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
				let used = MainActor.assumeIsolated { self?.key(event) ?? false }
				return used ? nil : event
			},
			NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
				let used = MainActor.assumeIsolated {
					guard let self, let window = self.window, event.window === window else { return false }
					return self.content?.onScroll?(event) ?? false
				}
				return used ? nil : event
			},
		].compactMap { $0 }
	}

	private func key(_ event: NSEvent) -> Bool {
		guard let window, event.window === window else { return false }
		if event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
			if content?.onCancel?() != true { close() }
			return true
		}
		return content?.onKey?(event) ?? false
	}

	private func dismiss() {
		guard isOpen else { return }
		dismissed = (ProcessInfo.processInfo.systemUptime, NSEvent.mouseLocation)
		close()
	}

	func close(animated: Bool = true) {
		guard let window else { return }
		let content = self.content
		self.window = nil
		self.content = nil
		shrinkWork?.cancel()
		shrinkWork = nil
		pressedAt = nil
		if let latency { ProcessInfo.processInfo.endActivity(latency) }
		latency = nil
		for monitor in monitors { NSEvent.removeMonitor(monitor) }
		monitors = []
		statusItem.button?.highlight(false)
		window.ignoresMouseEvents = true
		content?.onClose?()
		guard animated else { return Self.discard(window) }
		NSAnimationContext.runAnimationGroup({ context in
			context.duration = 0.18
			context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.8, 0.6)
			window.animator().alphaValue = 0
			window.animator().setFrame(window.frame.offsetBy(dx: 0, dy: 5), display: false)
		}, completionHandler: {
			MainActor.assumeIsolated { Self.discard(window) }
		})
	}

	private static func discard(_ window: BarWindow) {
		window.orderOut(nil)
		window.contentView = nil
	}

	private func updatePassThrough() {
		guard let window, let glass = glassFrame else { return }
		let through = !glass.contains(NSEvent.mouseLocation)
		if window.ignoresMouseEvents != through { window.ignoresMouseEvents = through }
	}

	private func glassResized(_ size: CGSize) {
		guard size.width > 0, size.height > 0 else { return }
		shrinkWork?.cancel()
		shrinkWork = nil
		if size.height < glassSize.height {
			let work = DispatchWorkItem { [weak self] in
				MainActor.assumeIsolated {
					self?.glassSize = size
					self?.updatePassThrough()
				}
			}
			shrinkWork = work
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.36, execute: work)
			return
		}
		glassSize = size
		updatePassThrough()
		DispatchQueue.main.async { [weak self] in
			MainActor.assumeIsolated {
				guard let self, let window = self.window else { return }
				let needed = self.glassSize.height + Bar.gap + Bar.margin
				guard needed > window.frame.height else { return }
				var frame = window.frame
				frame.origin.y = frame.maxY - needed
				frame.size.height = needed
				window.setFrame(frame, display: true)
			}
		}
	}
}
