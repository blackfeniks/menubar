import AppKit
import SwiftUI

@MainActor
final class BarPointer {
	private(set) var x: CGFloat = 0
	private(set) var y: CGFloat = 0
	private(set) var lift: Double = 0
	private(set) var inside = false
	var held = false
	var enabled = true
	var onFrame: (() -> Void)?

	fileprivate func step(_ point: CGPoint, over: Bool, dt: Double) -> Bool {
		let wasInside = inside
		inside = over && enabled
		let up = enabled && (over || held)
		var changed = wasInside != inside
		if up {
			let nx = lift < 0.01 ? point.x : Self.follow(x, point.x)
			let ny = lift < 0.01 ? point.y : Self.follow(y, point.y)
			if nx != x || ny != y {
				(x, y) = (nx, ny)
				changed = true
			}
		}
		let goal = up ? 1.0 : 0.0
		if lift != goal {
			let rate = up ? 0.045 : 0.12
			var next = lift + (goal - lift) * (1 - exp(-dt / rate))
			if abs(goal - next) < 0.004 { next = goal }
			lift = next
			changed = true
		}
		if changed { onFrame?() }
		return changed
	}

	private static func follow(_ from: CGFloat, _ to: CGFloat) -> CGFloat {
		let d = to - from
		guard abs(d) > 0.05 else { return to }
		return from + d * min(1, 0.4 + abs(d) / 10)
	}
}

struct BarTick {
	var rect: CGRect
	var opacity: Double
	var color: BarTickColor = .white
	var rootFade: Double = 1
	var rootAtBottom = true
}

enum BarTickColor: Int {
	case white, amber

	fileprivate var components: (CGFloat, CGFloat, CGFloat) {
		switch self {
		case .white: (1, 1, 1)
		case .amber: (1, 0.71, 0.28)
		}
	}

	var color: Color {
		let c = components
		return Color(.sRGB, red: c.0, green: c.1, blue: c.2)
	}
}

struct BarTicks: NSViewRepresentable {
	let pointer: BarPointer
	let ticks: (CGSize, CGFloat, Double) -> [BarTick]

	func makeNSView(context: Context) -> TickView { TickView(pointer: pointer) }

	func updateNSView(_ view: TickView, context: Context) {
		view.ticks = ticks
		view.render()
	}

	final class TickView: NSView {
		fileprivate var ticks: ((CGSize, CGFloat, Double) -> [BarTick])?
		private let pointer: BarPointer
		private var link: CADisplayLink?
		private var fast = false
		private var marks: [Mark] = []
		private var drawnSize = CGSize.zero

		private final class Mark {
			let layer = CAGradientLayer()
			var color: BarTickColor?
			var rootFade = -1.0
			var rootAtBottom: Bool?
		}

		init(pointer: BarPointer) {
			self.pointer = pointer
			super.init(frame: .zero)
			wantsLayer = true
			layer?.masksToBounds = false
		}

		@available(*, unavailable)
		required init?(coder: NSCoder) { fatalError() }

		override var isFlipped: Bool { true }
		override func hitTest(_ point: NSPoint) -> NSView? { nil }

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			link?.invalidate()
			link = nil
			guard window != nil else { return }
			let l = displayLink(target: self, selector: #selector(frame(_:)))
			l.add(to: .main, forMode: .common)
			link = l
			setFast(false)
			render()
		}

		override func layout() {
			super.layout()
			if bounds.size != drawnSize { render() }
		}

		private func setFast(_ on: Bool) {
			fast = on
			link?.preferredFrameRateRange = on ? CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
				: CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
		}

		@objc private func frame(_ l: CADisplayLink) {
			guard let window, window.isVisible else { return }
			let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
			let over = bounds.contains(p) && window.alphaValue > 0.5
			let moved = pointer.step(p, over: over, dt: min(0.05, max(0.001, l.targetTimestamp - l.timestamp)))
			if moved { render() }
			if moved != fast { setFast(moved) }
		}

		fileprivate func render() {
			guard let ticks, let root = layer, bounds.width > 0 else { return }
			drawnSize = bounds.size
			let list = ticks(bounds.size, pointer.x, pointer.lift)
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			while marks.count < list.count {
				let mark = Mark()
				mark.layer.startPoint = CGPoint(x: 0.5, y: 0)
				mark.layer.endPoint = CGPoint(x: 0.5, y: 1)
				mark.layer.masksToBounds = true
				root.addSublayer(mark.layer)
				marks.append(mark)
			}
			for (i, mark) in marks.enumerated() {
				guard i < list.count else {
					if !mark.layer.isHidden { mark.layer.isHidden = true }
					continue
				}
				let tick = list[i]
				if mark.layer.isHidden { mark.layer.isHidden = false }
				mark.layer.frame = tick.rect
				mark.layer.cornerRadius = min(tick.rect.width, tick.rect.height) / 2
				mark.layer.opacity = Float(tick.opacity)
				if mark.color != tick.color || mark.rootFade != tick.rootFade || mark.rootAtBottom != tick.rootAtBottom {
					(mark.color, mark.rootFade, mark.rootAtBottom) = (tick.color, tick.rootFade, tick.rootAtBottom)
					let c = tick.color.components
					let tip = CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
					let rootColor = CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: CGFloat(tick.rootFade))
					mark.layer.colors = tick.rootAtBottom ? [tip, rootColor] : [rootColor, tip]
				}
			}
			CATransaction.commit()
		}
	}
}

struct BarTicksPicture: View {
	let ticks: [BarTick]

	var body: some View {
		Canvas(opaque: false) { context, _ in
			for t in ticks {
				let path = Path(roundedRect: t.rect, cornerRadius: min(t.rect.width, t.rect.height) / 2)
				if t.rootFade >= 1 {
					context.fill(path, with: .color(t.color.color.opacity(t.opacity)))
				} else {
					let tip = t.color.color.opacity(t.opacity), root = t.color.color.opacity(t.opacity * t.rootFade)
					context.fill(path, with: .linearGradient(Gradient(colors: t.rootAtBottom ? [tip, root] : [root, tip]),
					                                         startPoint: CGPoint(x: t.rect.midX, y: t.rect.minY),
					                                         endPoint: CGPoint(x: t.rect.midX, y: t.rect.maxY)))
				}
			}
		}
	}
}
