import AppKit
import CoreText
import SwiftUI

struct RowFX {
	var y: CGFloat
	var x: CGFloat = 0
	var scale: CGFloat = 1
	var tilt: Double = 0
	var opacity: Double = 1
	var blur: CGFloat = 0
}

enum Wheel {
	private static let step = 12.5 * Double.pi / 180
	private static let lean: Double = 7, leanWidth = 1.2

	static func fx(r: Double, pitch: CGFloat) -> RowFX {
		let theta = max(-1.35, min(1.35, r * step))
		let c = cos(theta)
		let g = exp(-r * r / 3)
		return RowFX(y: CGFloat(Double(pitch) / step * sin(theta)),
		             x: CGFloat(lean * exp(-r * r / leanWidth)),
		             scale: CGFloat(0.96 + 0.04 * exp(-r * r / 0.9)),
		             tilt: theta * 180 / Double.pi * 0.85,
		             opacity: (0.5 + 0.5 * g) * pow(max(0, c), 0.8),
		             blur: CGFloat((1 - c) * 1.6))
	}
}

struct WheelList<Row: View>: View, Animatable {
	var count: Int
	var x: Double
	var pitch: CGFloat
	var visible: Int
	var width: CGFloat
	var band = true
	@ViewBuilder var content: (Int) -> Row

	var animatableData: Double {
		get { x }
		set { x = newValue }
	}

	static func height(visible: Int, pitch: CGFloat) -> CGFloat { CGFloat(max(1, visible)) * pitch }

	var body: some View {
		let v = Double(max(1, min(visible, count)))
		let first = max(0, min(x - (v - 1) / 2, Double(count) - v))
		let anchor = (CGFloat(x - first) + 0.5) * pitch
		let height = Self.height(visible: visible, pitch: pitch)
		ZStack(alignment: .topLeading) {
			if band {
				RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(nsColor: Look.selection))
					.frame(width: width, height: pitch - 2)
					.offset(y: anchor - (pitch - 2) / 2)
			}
			ForEach(0..<count, id: \.self) { i in
				let r = Double(i) - x
				if r > -v - 0.5 && r < v + 0.5 {
					let fx = Wheel.fx(r: r, pitch: pitch)
					content(i)
						.environment(\.wheelOffAnchor, abs(r) > 0.01)
						.environment(\.inWheel, true)
						.frame(width: width - 8, height: pitch, alignment: .leading)
						.scaleEffect(fx.scale, anchor: .leading)
						.rotation3DEffect(.degrees(fx.tilt), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.35)
						.blur(radius: fx.blur)
						.opacity(fx.opacity)
						.offset(x: fx.x, y: anchor - pitch / 2 + fx.y)
				}
			}
		}
		.frame(width: width, height: height, alignment: .topLeading)
		.clipped()
	}
}

private struct WheelOffAnchorKey: EnvironmentKey { static let defaultValue = false }

private struct InWheelKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
	var wheelOffAnchor: Bool {
		get { self[WheelOffAnchorKey.self] }
		set { self[WheelOffAnchorKey.self] = newValue }
	}

	var inWheel: Bool {
		get { self[InWheelKey.self] }
		set { self[InWheelKey.self] = newValue }
	}
}

enum Motion {
	static let layout = Animation.smooth(duration: 0.22)
	static let select = Animation.snappy(duration: 0.3)
	static let appear = Animation.easeOut(duration: 0.3)
	static let leave = Animation.easeIn(duration: 0.16)

	static var develop: AnyTransition {
		.asymmetric(insertion: .modifier(active: DevelopFX(p: 0), identity: DevelopFX(p: 1)).animation(appear),
		            removal: .modifier(active: DissolveFX(p: 1), identity: DissolveFX(p: 0)).animation(leave))
	}
}

enum MotionFlags {
	nonisolated(unsafe) static var drop = true
	nonisolated(unsafe) static var glass = true
}

struct Glass<S: Shape>: View {
	var shape: S
	var body: some View {
		if MotionFlags.glass {
			ZStack {
				BehindWindowBlur()
				Color.black.opacity(Bar.glassDim)
			}
			.clipShape(shape)
		} else {
			shape.fill(Color(nsColor: Look.background))
		}
	}
}

struct ShadowedGlass<S: Shape>: View {
	var shape: S
	var radius = Look.shadowRadius
	var y = Look.shadowY
	var opacity = Look.shadowOpacity
	var reach: CGFloat = 120

	var body: some View {
		Glass(shape: shape)
			.background {
				shape.fill(Color.black)
					.shadow(color: .black.opacity(opacity), radius: radius, y: y)
					.mask {
						Rectangle().padding(-reach)
							.overlay(shape.blendMode(.destinationOut))
							.compositingGroup()
					}
			}
	}
}

private struct BehindWindowBlur: NSViewRepresentable {
	func makeNSView(context: Context) -> NSVisualEffectView {
		let v = NSVisualEffectView()
		v.blendingMode = .behindWindow
		v.material = .hudWindow
		v.state = .active
		return v
	}

	func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct DropShape: Shape {
	var corner: CGFloat
	var bulge: CGFloat

	var animatableData: CGFloat {
		get { bulge }
		set { bulge = newValue }
	}

	func path(in r: CGRect) -> Path {
		var p = Path(roundedRect: r, cornerRadius: corner, style: .continuous)
		let b = max(0, bulge)
		guard b > 0.2 else { return p }
		var lens = Path()
		lens.move(to: CGPoint(x: r.minX + corner, y: r.maxY - 0.5))
		lens.addCurve(to: CGPoint(x: r.maxX - corner, y: r.maxY - 0.5),
		              control1: CGPoint(x: r.minX + r.width * 0.3, y: r.maxY + b * 1.33),
		              control2: CGPoint(x: r.maxX - r.width * 0.3, y: r.maxY + b * 1.33))
		lens.closeSubpath()
		p.addPath(lens)
		return p
	}
}

struct AnswerWord: Identifiable, Equatable {
	var id: Int
	var text: String
	var range: NSRange
	var breaks: Int
}

enum Words {
	static func font(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size) }

	static func width(_ s: String, _ size: CGFloat) -> CGFloat {
		ceil((s as NSString).size(withAttributes: [.font: font(size)]).width)
	}

	static func split(_ s: String) -> [(text: String, range: NSRange, breaks: Int)] {
		let ns = s as NSString
		var out: [(String, NSRange, Int)] = []
		var i = 0, breaks = 0
		while i < ns.length {
			let c = ns.character(at: i)
			if c == 10 { breaks += 1; i += 1; continue }
			if c == 32 || c == 9 || c == 13 { i += 1; continue }
			var j = i
			while j < ns.length {
				let d = ns.character(at: j)
				if d == 10 || d == 32 || d == 9 || d == 13 { break }
				j += 1
			}
			let r = NSRange(location: i, length: j - i)
			out.append((ns.substring(with: r), r, breaks))
			breaks = 0
			i = j
		}
		return out
	}

	static func diffed(_ new: String, old: [AnswerWord], nextID: inout Int) -> [AnswerWord] {
		let parts = split(new)
		let a = old.map(\.text), b = parts.map(\.text)
		let n = a.count, m = b.count
		var keep = [Int?](repeating: nil, count: m)
		if n > 0 && m > 0 && n * m <= 250_000 {
			var t = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
			for i in stride(from: n - 1, through: 0, by: -1) {
				for j in stride(from: m - 1, through: 0, by: -1) {
					t[i][j] = a[i] == b[j] ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1])
				}
			}
			var i = 0, j = 0
			while i < n && j < m {
				if a[i] == b[j] {
					keep[j] = old[i].id
					i += 1
					j += 1
				} else if t[i + 1][j] >= t[i][j + 1] { i += 1 } else { j += 1 }
			}
		}
		return parts.enumerated().map { k, p in
			let id: Int
			if let kept = keep[k] { id = kept } else {
				nextID += 1
				id = nextID
			}
			return AnswerWord(id: id, text: p.text, range: p.range, breaks: p.breaks)
		}
	}

	struct Box {
		var x: CGFloat
		var y: CGFloat
		var width: CGFloat
		var line: Int
	}

	static func layout(_ words: [AnswerWord], size: CGFloat, width maxWidth: CGFloat, lineHeight: CGFloat) -> (boxes: [Box], lines: Int) {
		let space = width(" ", size) - 1
		var x: CGFloat = 0, line = 0
		var boxes: [Box] = []
		for (k, w) in words.enumerated() {
			let ww = min(width(w.text, size), maxWidth)
			if k > 0 && w.breaks > 0 {
				line += w.breaks
				x = 0
			} else if x > 0 && x + ww > maxWidth {
				line += 1
				x = 0
			}
			boxes.append(Box(x: x, y: CGFloat(line) * lineHeight, width: ww, line: line))
			x += ww + space
		}
		return (boxes, words.isEmpty ? 0 : line + 1)
	}
}

enum SkipInk {
	private static var cache: [String: [ClosedRange<CGFloat>]] = [:]

	static func gaps(_ word: String, size: CGFloat, depth: CGFloat, pad: CGFloat = 1.6) -> [ClosedRange<CGFloat>] {
		let key = "\(size)|\(depth)|\(word)"
		if let hit = cache[key] { return hit }
		let font = Words.font(size) as CTFont
		let line = CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: [.font: font]))
		var out: [ClosedRange<CGFloat>] = []
		for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
			let n = CTRunGetGlyphCount(run)
			var glyphs = [CGGlyph](repeating: 0, count: n)
			var pos = [CGPoint](repeating: .zero, count: n)
			CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
			CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
			var rects = [CGRect](repeating: .zero, count: n)
			CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, &rects, n)
			for i in 0..<n where rects[i].minY < -depth + 0.4 && rects[i].width > 0 {
				out.append((pos[i].x + rects[i].minX - pad)...(pos[i].x + rects[i].maxX + pad))
			}
		}
		if cache.count > 2000 { cache.removeAll() }
		cache[key] = out
		return out
	}
}

struct DottedUnderline: View {
	var word: String
	var size: CGFloat
	var width: CGFloat
	var color: Color
	var depth: CGFloat = 3.2
	var dot: CGFloat = 1.6
	var gap: CGFloat = 2.3

	var body: some View {
		let font = Words.font(size)
		let gaps = SkipInk.gaps(word, size: size, depth: depth + dot / 2)
		Canvas { ctx, _ in
			let y = font.ascender + depth
			var x = dot / 2
			while x <= width - dot / 2 {
				if !gaps.contains(where: { $0.contains(x) }) {
					ctx.fill(Path(ellipseIn: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)), with: .color(color))
				}
				x += dot + gap
			}
		}
		.frame(width: width, height: font.ascender + depth + dot + 1)
		.allowsHitTesting(false)
	}
}

struct Relief: View {
	@State private var start = Date()

	var body: some View {
		TimelineView(.animation) { tl in
			let t = tl.date.timeIntervalSince(start)
			Canvas { ctx, size in
				let progress = 1 - exp(-t / 2.6)
				let rows = 9
				for k in 0..<rows {
					let depth = Double(k) / Double(rows - 1)
					let y0 = size.height * (0.92 - 0.8 * pow(depth, 0.85))
					let amp = 11.0 * (1 - 0.6 * depth)
					var p = Path()
					let steps = 110
					for i in 0...steps {
						let u = Double(i) / Double(steps)
						let crest = progress * 1.15 - 0.08
						let d = (u - crest) / 0.11
						let bump = exp(-d * d) - 0.35 * exp(-d * d / 6)
						let swell = 0.18 * sin(u * 9 + t * 2.1 + depth * 2.4)
						let e = max(0, min(1, min(u, 1 - u) / 0.12))
						let y = y0 - CGFloat((bump + swell) * amp * e * e * (3 - 2 * e))
						let pt = CGPoint(x: CGFloat(u) * size.width, y: y)
						if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
					}
					ctx.stroke(p, with: .color(.white.opacity(0.55 - 0.42 * depth)), lineWidth: 0.8)
				}
			}
		}
	}
}

struct DevelopFX: ViewModifier {
	var p: Double
	func body(content: Content) -> some View {
		content
			.blur(radius: CGFloat((1 - p) * 6))
			.opacity(p)
			.offset(y: CGFloat((1 - p) * 7))
	}
}

struct DissolveFX: ViewModifier {
	var p: Double
	func body(content: Content) -> some View {
		content
			.blur(radius: CGFloat(p * 5))
			.opacity(1 - p)
			.offset(y: CGFloat(-5 * p))
	}
}

struct AnswerFlow: View {
	var words: [AnswerWord]
	var marked: Set<Int>
	var picked: Set<Int>
	var dim: Bool
	var pickable: Bool
	var lift: Bool
	var animates = true
	var size: CGFloat
	var lineHeight: CGFloat
	var width: CGFloat
	var onPick: (AnswerWord) -> Void

	@State private var pointer: CGPoint?
	@State private var pressed: Int?

	var body: some View {
		let layout = Words.layout(words, size: size, width: width, lineHeight: lineHeight)
		let hovered = pointer.flatMap { word(at: $0, layout.boxes) }
		ZStack(alignment: .topLeading) {
			ForEach(Array(words.enumerated()), id: \.element.id) { k, w in
				let b = layout.boxes[k]
				let next = k + 1 < words.count ? words[k + 1] : nil
				let joinsNext = marked.contains(w.id) && next.map { marked.contains($0.id) && layout.boxes[k + 1].line == b.line } == true
				let wave = lift(b, hovered: hovered == k, pressed: pressed == k)
				word(w, box: b, joinsNext: joinsNext, gapToNext: next.map { _ in layout.boxes[k + 1].x - b.x - b.width } ?? 0)
					.scaleEffect(wave.scale, anchor: .bottom)
					.offset(x: b.x, y: b.y + wave.rise)
					.animation(wave.rise == 0 && wave.scale == 1 && pointer == nil ? nil : Motion.select, value: wave)
					.transition(Motion.develop)
			}
		}
		.animation(animates ? Motion.layout : nil, value: words)
		.frame(width: width, height: CGFloat(max(1, layout.lines)) * lineHeight, alignment: .topLeading)
		.contentShape(Rectangle())
		.takesPress { word(at: $0, layout.boxes) != nil }
		.onContinuousHover(coordinateSpace: .local) { phase in
			switch phase {
			case let .active(p): pointer = pickable ? p : nil
			case .ended: pointer = nil
			}
		}
		.gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
			.onChanged { v in if pressed == nil, pickable { pressed = word(at: v.startLocation, layout.boxes) } }
			.onEnded { v in
				defer { pressed = nil }
				guard pickable, let k = word(at: v.location, layout.boxes), k == pressed else { return }
				onPick(words[k])
			})
		.pointerStyle(pickable && hovered != nil ? .link : .default)
	}

	private func word(at p: CGPoint, _ boxes: [Words.Box]) -> Int? {
		boxes.firstIndex { p.x >= $0.x - 2 && p.x <= $0.x + $0.width + 2 && p.y >= $0.y && p.y < $0.y + lineHeight }
	}

	private func word(_ w: AnswerWord, box: Words.Box, joinsNext: Bool, gapToNext: CGFloat) -> some View {
		ZStack(alignment: .topLeading) {
			if picked.contains(w.id) {
				RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.12))
					.frame(width: box.width + 8, height: lineHeight - 4)
					.offset(x: -4, y: -1)
			}
			Text(w.text)
				.font(.system(size: size))
				.foregroundStyle(dim ? Color.white.opacity(0.36) : Color(nsColor: Look.t1))
				.fixedSize()
			if marked.contains(w.id) {
				let span = box.width + (joinsNext ? gapToNext : 0)
				DottedUnderline(word: joinsNext ? w.text + " " : w.text, size: size, width: span,
				                color: Color.white.opacity(dim ? 0.25 : 0.6))
			}
		}
	}

	struct Wave: Equatable {
		var rise: CGFloat = 0
		var scale: CGFloat = 1
	}

	private func lift(_ b: Words.Box, hovered: Bool, pressed: Bool) -> Wave {
		if pressed { return Wave(rise: 1, scale: 0.985) }
		guard lift, let p = pointer else { return Wave() }
		let dx = Double(max(0, abs(b.x + b.width / 2 - p.x) - b.width / 2))
		let lines = Double(abs(b.y + lineHeight / 2 - p.y) / lineHeight)
		let onLine = exp(-lines * lines * 4)
		guard onLine > 0.02, dx < 240 else { return Wave() }
		let crest = exp(-pow(dx / 38, 2)), dip = 0.45 * (exp(-pow(dx / 95, 2)) - crest)
		let rise = CGFloat(-(crest - dip) * 3.2 * onLine)
		return Wave(rise: (rise * 4).rounded() / 4, scale: hovered ? 1.03 : 1)
	}

	static func height(_ words: [AnswerWord], size: CGFloat, width: CGFloat, lineHeight: CGFloat) -> CGFloat {
		CGFloat(max(1, Words.layout(words, size: size, width: width, lineHeight: lineHeight).lines)) * lineHeight
	}
}

struct AnswerView: View {
	let session: Session
	var animates = true
	@State private var cache = WordCache()

	private var visible: String {
		let a = session.answer
		guard session.streaming, let last = a.last, !last.isWhitespace else { return a }
		if let cut = a.lastIndex(where: \.isWhitespace) { return String(a[..<cut]) }
		return ""
	}

	static let perWordLimit = 90

	var body: some View {
		let words = cache.words(for: visible)
		let marks = session.answerMarks, picked = session.picked
		let pickable = !session.isStale && !session.streaming && !session.restyling
		if words.count > Self.perWordLimit {
			AnswerText(text: visible, dim: session.isStale || session.restyling, marks: marks, picked: picked,
			           pickable: pickable, onPick: { session.pick($0) })
				.takesPress()
		} else {
			flow(words, marks: marks, picked: picked, pickable: pickable)
		}
	}

	private func flow(_ words: [AnswerWord], marks: [NSRange], picked: NSRange?, pickable: Bool) -> some View {
		AnswerFlow(words: words,
		           marked: Set(words.filter { w in marks.contains { NSIntersectionRange($0, w.range).length > 0 } }.map(\.id)),
		           picked: Set(words.filter { w in picked.map { NSIntersectionRange($0, w.range).length > 0 } ?? false }.map(\.id)),
		           dim: session.isStale || session.restyling,
		           pickable: pickable,
		           lift: true, animates: animates, size: Look.answerSize, lineHeight: Look.answerLine,
		           width: Look.width - 2 * Look.side, onPick: { session.pick($0.range) })
	}
}

@MainActor final class WordCache {
	private var text: String?
	private var words: [AnswerWord] = []
	private var nextID = 0

	func words(for new: String) -> [AnswerWord] {
		guard new != text else { return words }
		let old = words
		var id = nextID
		let fresh = Words.diffed(new, old: old, nextID: &id)
		nextID = id
		words = fresh
		text = new
		return fresh
	}
}
