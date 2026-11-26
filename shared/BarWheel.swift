import AppKit
import SwiftUI

struct BarWheelRow {
	var title: String
	var key: String?
	var hint: String?
	var pick: () -> Void
}

struct BarWheelFX {
	var y: CGFloat
	var x: CGFloat
	var scale: CGFloat
	var tilt: Double
	var opacity: Double
	var blur: CGFloat
}

struct BarWheelGeometry {
	static let pitch: CGFloat = 28
	private static let step = 12.5 * Double.pi / 180
	private static let maxAngle = 1.35

	var count: Int
	var visible: Double
	var picker = false

	private static func drumY(_ r: Double) -> CGFloat {
		CGFloat(Double(pitch) / step * sin(max(-maxAngle, min(maxAngle, r * step))))
	}

	var height: CGFloat { picker ? CGFloat(visible) * Self.pitch : 2 * (Self.drumY((visible - 1) / 2) + Self.pitch / 2) }
	var maxScroll: Double { picker ? Double(max(0, count - 1)) : max(0, Double(count) - visible) }

	private func first(_ chosen: Double) -> Double { max(0, min(chosen - (visible - 1) / 2, Double(count) - visible)) }

	func edgeFades(scroll: Double) -> (top: Double, bottom: Double) {
		if picker {
			let f = first(scroll)
			return (min(1, f), min(1, Double(count) - visible - f))
		}
		return (min(1, scroll), min(1, maxScroll - scroll))
	}

	private func fromMiddle(_ row: Double, scroll: Double) -> Double { row - scroll - (visible - 1) / 2 }

	func centerY(of row: Double, scroll: Double) -> CGFloat {
		if picker { return (CGFloat(scroll - first(scroll)) + 0.5) * Self.pitch + Self.drumY(row - scroll) }
		return height / 2 + Self.drumY(fromMiddle(row, scroll: scroll))
	}

	func range(scroll: Double) -> ClosedRange<Int> {
		if picker {
			let lo = max(0, Int((scroll - visible - 0.5).rounded(.up)))
			return lo...max(lo, min(count - 1, Int((scroll + visible + 0.5).rounded(.down))))
		}
		let lo = max(0, Int(scroll.rounded(.down)) - 1)
		return lo...max(lo, min(count - 1, Int((scroll + visible).rounded(.up))))
	}

	func row(at y: CGFloat, scroll: Double) -> Int? {
		guard count > 0, y >= 0, y < height else { return nil }
		if picker, Double(count) <= visible { return min(count - 1, Int(y / Self.pitch)) }
		return range(scroll: scroll).min { abs(centerY(of: Double($0), scroll: scroll) - y) < abs(centerY(of: Double($1), scroll: scroll) - y) }
	}

	func fx(row: Int, scroll: Double, lens: Double, lensOn: Double) -> BarWheelFX {
		if picker {
			let r = Double(row) - scroll
			let angle = max(-Self.maxAngle, min(Self.maxAngle, r * Self.step))
			let cosine = cos(angle)
			return BarWheelFX(y: centerY(of: Double(row), scroll: scroll),
			               x: CGFloat(7 * exp(-r * r / 1.2)),
			               scale: CGFloat(0.96 + 0.04 * exp(-r * r / 0.9)),
			               tilt: angle * 180 / Double.pi * 0.85,
			               opacity: (0.5 + 0.5 * exp(-r * r / 3)) * pow(max(0, cosine), 0.8),
			               blur: CGFloat((1 - cosine) * 1.6))
		}
		let theta = max(-Self.maxAngle, min(Self.maxAngle, fromMiddle(Double(row), scroll: scroll) * Self.step))
		let c = cos(theta)
		let d = Double(row) - lens
		let focus = exp(-d * d / 0.9) * lensOn
		let opacity = (1 - 0.4 * lensOn * (1 - exp(-d * d / 3))) * pow(max(0, c), 0.8)
		return BarWheelFX(y: centerY(of: Double(row), scroll: scroll),
		               x: CGFloat(7 * exp(-d * d / 1.2) * lensOn),
		               scale: CGFloat(1 - 0.04 * lensOn * (1 - exp(-d * d / 0.9))),
		               tilt: theta * 180 / Double.pi * 0.85,
		               opacity: opacity + (1 - opacity) * focus,
		               blur: CGFloat((1 - c) * 1.6 * (1 - focus)))
	}
}

@Observable
final class BarWheelModel {
	var scroll = 0.0
	var lens = 0.0
	var lensOn = 0.0
	var visible: Double
	@ObservationIgnored let picker: Bool

	init(visible: Double, picker: Bool) {
		self.visible = visible
		self.picker = picker
	}
}

struct BarWheelStyle {
	var leading: CGFloat
	var trailing: CGFloat
	var bandInset: CGFloat
}

struct BarWheelRows: View {
	let rows: [BarWheelRow]
	let checked: Int?
	let width: CGFloat
	let style: BarWheelStyle
	let model: BarWheelModel

	var body: some View {
		let pitch = BarWheelGeometry.pitch
		let geometry = BarWheelGeometry(count: rows.count, visible: model.visible, picker: model.picker)
		ZStack(alignment: .topLeading) {
			RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Bar.selection)
				.frame(width: width - 2 * style.bandInset, height: pitch - 2)
				.offset(x: style.bandInset, y: geometry.centerY(of: model.lens, scroll: model.scroll) - (pitch - 2) / 2)
				.opacity(model.lensOn)
			ForEach(Array(geometry.range(scroll: model.scroll)), id: \.self) { i in
				let fx = geometry.fx(row: i, scroll: model.scroll, lens: model.lens, lensOn: model.lensOn)
				row(i)
					.frame(width: width, height: pitch, alignment: .leading)
					.scaleEffect(fx.scale, anchor: .leading)
					.rotation3DEffect(.degrees(fx.tilt), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.35)
					.blur(radius: fx.blur)
					.opacity(fx.opacity)
					.offset(x: fx.x, y: fx.y - pitch / 2)
			}
		}
		.frame(width: width, height: geometry.height, alignment: .topLeading)
		.mask(edgeFade(geometry))
	}

	private func edgeFade(_ geometry: BarWheelGeometry) -> some View {
		let fade = 14 / max(geometry.height, 1)
		let (top, bottom) = geometry.edgeFades(scroll: model.scroll)
		return LinearGradient(stops: [.init(color: .black.opacity(1 - top), location: 0), .init(color: .black, location: fade),
		                              .init(color: .black, location: 1 - fade), .init(color: .black.opacity(1 - bottom), location: 1)],
		                      startPoint: .top, endPoint: .bottom)
	}

	private func row(_ i: Int) -> some View {
		HStack(spacing: 8) {
			Text(rows[i].title).font(.system(size: Bar.text)).foregroundStyle(Bar.t1).lineLimit(1).truncationMode(.tail)
			Spacer(minLength: 0)
			if let key = rows[i].key { Text(key).font(.system(size: 12)).foregroundStyle(Bar.t4) }
			if i == checked { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Bar.t2) }
		}
		.padding(.leading, style.leading)
		.padding(.trailing, style.trailing)
	}
}

private struct BarSpring {
	var value: Double
	var velocity = 0.0
	private static let stiffness = 22.0

	mutating func step(to target: Double, dt: Double) {
		let w = Self.stiffness
		velocity += (w * w * (target - value) - 2 * w * velocity) * dt
		value += velocity * dt
		if abs(target - value) < 0.002 && abs(velocity) < 0.02 {
			value = target
			velocity = 0
		}
	}
}

private struct BarScrollSteps {
	private var carry: CGFloat = 0

	mutating func steps(_ event: NSEvent) -> Int {
		if event.phase == .began || event.phase == .mayBegin { carry = 0 }
		let dy = event.scrollingDeltaY
		guard dy != 0 else { return 0 }
		if !event.hasPreciseScrollingDeltas {
			carry = 0
			return dy > 0 ? -1 : 1
		}
		carry += dy
		let n = Int((carry / BarWheelGeometry.pitch).rounded(.towardZero))
		carry -= CGFloat(n) * BarWheelGeometry.pitch
		return -n
	}
}

final class BarWheel: NSView {
	let rows: [BarWheelRow]
	let checked: Int?
	let model: BarWheelModel
	var onHover: ((Int?) -> Void)?
	private var scroll = BarSpring(value: 0)
	private var lens = BarSpring(value: 0)
	private var lensOn = BarSpring(value: 0)
	private var shown: BarSpring
	private(set) var scrollTarget = 0
	private(set) var visibleTarget: Int
	private var lensTarget = 0.0
	private var pointerY: CGFloat?
	private var hoveredRow: Int? {
		didSet { if hoveredRow != oldValue { onHover?(hoveredRow) } }
	}
	private var steps = BarScrollSteps()
	private var link: CADisplayLink?
	var isActive = true {
		didSet { if !isActive { pointer(nil) } }
	}

	override var isFlipped: Bool { true }
	var geometry: BarWheelGeometry { BarWheelGeometry(count: rows.count, visible: model.visible, picker: model.picker) }
	var isTurning: Bool { !model.picker && scroll.value != Double(scrollTarget) }
	private var pointerTurns: Bool { model.picker && rows.count <= visibleTarget }

	init(rows: [BarWheelRow], visible: Int, checked: Int? = nil, picker: Bool = false) {
		self.rows = rows
		self.checked = checked
		visibleTarget = max(1, min(rows.count, visible))
		shown = BarSpring(value: Double(visibleTarget))
		model = BarWheelModel(visible: Double(visibleTarget), picker: picker)
		super.init(frame: .zero)
		addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
		                               owner: self, userInfo: nil))
		if picker {
			scrollTo(checked ?? 0, animated: false)
			model.lens = model.scroll
			model.lensOn = 1
		} else if let checked {
			scrollTo(checked - (visibleTarget - 1) / 2, animated: false)
		}
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
	override func hitTest(_ point: NSPoint) -> NSView? { isActive ? super.hitTest(point) : nil }

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		if window == nil { stopFrames() }
	}

	func screenY(ofRow row: Int) -> CGFloat? {
		guard let window else { return nil }
		let y = geometry.centerY(of: Double(row), scroll: model.scroll)
		return window.convertPoint(toScreen: convert(NSPoint(x: 0, y: y), to: nil)).y
	}

	private func y(of event: NSEvent) -> CGFloat { convert(event.locationInWindow, from: nil).y }

	func pointer(_ y: CGFloat?) {
		pointerY = y
		if model.picker {
			steer()
		} else {
			updateLens()
		}
		startFrames()
	}

	private func steer() {
		hoveredRow = pointerY.flatMap { geometry.row(at: $0, scroll: model.scroll) }
		guard pointerTurns else { return }
		scrollTarget = hoveredRow ?? checked ?? scrollTarget
	}

	func scrollBy(_ rowsDown: Int) {
		scrollTo(scrollTarget + rowsDown, animated: true)
	}

	func setVisible(_ count: Int) {
		visibleTarget = max(1, min(rows.count, count))
		scrollTo(scrollTarget, animated: true)
	}

	private func scrollTo(_ top: Int, animated: Bool) {
		scrollTarget = max(0, min(model.picker ? rows.count - 1 : max(0, rows.count - visibleTarget), top))
		if animated {
			startFrames()
		} else {
			scroll = BarSpring(value: Double(scrollTarget))
			model.scroll = scroll.value
		}
	}

	private func updateLens() {
		guard let pointerY, let row = geometry.row(at: pointerY, scroll: model.scroll) else {
			hoveredRow = nil
			return
		}
		lensTarget = Double(row)
		hoveredRow = row
		if lensOn.value < 0.01 { lens = BarSpring(value: lensTarget) }
	}

	override func mouseEntered(with event: NSEvent) { pointer(isActive ? y(of: event) : nil) }
	override func mouseMoved(with event: NSEvent) { pointer(isActive ? y(of: event) : nil) }
	override func mouseDragged(with event: NSEvent) { pointer(isActive ? y(of: event) : nil) }
	override func mouseExited(with event: NSEvent) { pointer(nil) }
	override func mouseDown(with event: NSEvent) {}

	override func mouseUp(with event: NSEvent) {
		guard var row = geometry.row(at: y(of: event), scroll: model.scroll) else { return }
		if pointerTurns { row = scrollTarget }
		DispatchQueue.main.async(execute: rows[row].pick)
	}

	override func scrollWheel(with event: NSEvent) {
		let n = steps.steps(event)
		if n != 0 { scrollBy(n) }
	}

	private func startFrames() {
		guard link == nil, window != nil else { return }
		let l = displayLink(target: self, selector: #selector(frame(_:)))
		l.add(to: .main, forMode: .common)
		link = l
	}

	private func stopFrames() {
		link?.invalidate()
		link = nil
	}

	@objc private func frame(_ l: CADisplayLink) {
		if !advance(l.targetTimestamp - l.timestamp) { stopFrames() }
	}

	@discardableResult
	func advance(_ seconds: Double) -> Bool {
		let dt = min(seconds, 1.0 / 30)
		if model.picker {
			scroll.step(to: Double(scrollTarget), dt: dt)
			model.scroll = scroll.value
			model.lens = scroll.value
			return scroll.value != Double(scrollTarget)
		}
		let on = pointerY == nil ? 0.0 : 1.0
		updateLens()
		scroll.step(to: Double(scrollTarget), dt: dt)
		lens.step(to: lensTarget, dt: dt)
		lensOn.step(to: on, dt: dt)
		shown.step(to: Double(visibleTarget), dt: dt)
		model.scroll = scroll.value
		model.lens = lens.value
		model.lensOn = lensOn.value
		model.visible = shown.value
		return scroll.value != Double(scrollTarget) || lens.value != lensTarget || lensOn.value != on || shown.value != Double(visibleTarget)
	}
}

struct BarWheelHost: NSViewRepresentable {
	let control: BarWheel
	func makeNSView(context: Context) -> BarWheel { control }
	func updateNSView(_ view: BarWheel, context: Context) {}
}
