import AppKit
import SwiftUI

@MainActor @Observable
final class PanelUI {
	var commandHeld = false
	var thumbnail: NSImage?
	var dropping = false
	var pointerOverForm = false
	var cap: CGFloat = 100_000
	var animates = false
	@ObservationIgnored let press = PressAreas()
}

@MainActor
final class PressAreas {
	final class Area {
		var frame = CGRect.null
		var hit: ((CGPoint) -> Bool)?
		var scrolls = false
	}

	private var areas: [ObjectIdentifier: Area] = [:]
	var viewport = CGRect.null

	func add(_ area: Area) { areas[ObjectIdentifier(area)] = area }
	func remove(_ area: Area) { areas[ObjectIdentifier(area)] = nil }

	var frames: [CGRect] { areas.values.map(\.frame).filter { !$0.isNull } }

	func contains(_ p: CGPoint) -> Bool {
		areas.values.contains { a in
			guard a.frame.contains(p), !a.scrolls || viewport.contains(p) else { return false }
			return a.hit?(CGPoint(x: p.x - a.frame.minX, y: p.y - a.frame.minY)) ?? true
		}
	}
}

private struct PressAreasKey: EnvironmentKey { static let defaultValue: PressAreas? = nil }
private struct InFormScrollKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
	var pressAreas: PressAreas? {
		get { self[PressAreasKey.self] }
		set { self[PressAreasKey.self] = newValue }
	}

	var inFormScroll: Bool {
		get { self[InFormScrollKey.self] }
		set { self[InFormScrollKey.self] = newValue }
	}
}

extension View {
	func takesPress(hit: ((CGPoint) -> Bool)? = nil) -> some View { modifier(PressArea(hit: hit)) }
}

private struct PressArea: ViewModifier {
	let hit: ((CGPoint) -> Bool)?
	@Environment(\.pressAreas) private var areas
	@Environment(\.inFormScroll) private var scrolls
	@State private var area = PressAreas.Area()

	func body(content: Content) -> some View {
		let _ = (area.hit = hit, area.scrolls = scrolls)
		content
			.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(RowCheck.space)) }) { area.frame = $0 }
			.onAppear { areas?.add(area) }
			.onDisappear { areas?.remove(area) }
	}
}

private extension Color {
	static let t1 = Color(nsColor: Look.t1)
	static let t2 = Color(nsColor: Look.t2)
	static let t3 = Color(nsColor: Look.t3)
	static let t4 = Color(nsColor: Look.t4)
	static let line = Bar.hairline
}

struct PanelRoot: View {
	let session: Session
	let ui: PanelUI
	var onPicture: (CGImage) -> Void
	var registerInput: (InputTextView) -> Void
	var onFormHeight: (CGFloat) -> Void

	var body: some View {
		PanelView(session: session, ui: ui, onPicture: onPicture, registerInput: registerInput, onFormHeight: onFormHeight)
			.padding(.top, Look.margin.top)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
	}
}

struct PanelView: View {
	@Bindable var session: Session
	var ui: PanelUI
	var onPicture: (CGImage) -> Void
	var registerInput: (InputTextView) -> Void = { _ in }

	var onFormHeight: (CGFloat) -> Void = { _ in }
	@State private var shown: CGFloat?
	@State private var barHeight: CGFloat = 42

	@State private var bulge: CGFloat = 0

	var body: some View {
		let shape = DropShape(corner: Look.corner, bulge: bulge)
		FormLayout(shown: shown ?? -1, cap: ui.cap) {
			inputRow
				.background(Glass(shape: Rectangle()))
				.zIndex(1)
			if hasBody {
				Rectangle().fill(Color.line).frame(height: 0.5)
					.padding(.horizontal, 16)
					.background(Glass(shape: Rectangle()))
					.zIndex(1)
				ScrollView(.vertical) {
					VStack(alignment: .leading, spacing: 0) {
						if let status = session.statusLine { statusLine(status) }
						content
					}
					.frame(maxWidth: .infinity, alignment: .leading)
					.environment(\.inFormScroll, true)
				}
				.scrollBounceBehavior(.basedOnSize)
				.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(RowCheck.space)) }) { ui.press.viewport = $0 }
				.layoutValue(key: FormPart.self, value: .scroll)
			}
			let enter = hasBody ? session.enterLabel ?? (session.canGoBack ? "" : nil) : nil
			ZStack(alignment: .bottom) {
				if let enter {
					bar(enter: enter)
						.background(Glass(shape: Rectangle()))
						.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { barHeight = $0 }
				}
			}
			.frame(height: barHeight, alignment: .bottom)
			.frame(maxWidth: .infinity)
			.layoutValue(key: FormPart.self, value: enter == nil ? .emptyBar : .bar)
		}
		.frame(width: Look.width)
		.coordinateSpace(.named(RowCheck.space))
		.environment(\.pressAreas, ui.press)
		.onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: follow)
		.frame(height: shown, alignment: .top)
		.clipShape(shape)
		.background { ShadowedGlass(shape: shape) }
		.overlay(
			shape.stroke(ui.dropping ? Color.white.opacity(0.55) : Bar.border, lineWidth: ui.dropping ? 1.25 : 0.5)
				.animation(Motion.select, value: ui.dropping)
		)
		.overlay(alignment: .topLeading) {
			ZStack {
				if ui.pointerOverForm { CloseBubble { session.onClose?() }.transition(.opacity) }
			}
			.offset(x: Look.close.minX, y: Look.close.minY)
			.animation(Motion.select, value: ui.pointerOverForm)
		}
		.environment(\.colorScheme, .dark)
	}

	private func follow(_ height: CGFloat) {
		onFormHeight(height)
		guard shown != height else { return }
		if ui.animates, let old = shown {
			let grow = height - old
			if grow > 24 && MotionFlags.drop {
				withAnimation(Motion.layout) { shown = height }
				var t = Transaction()
				t.disablesAnimations = true
				withTransaction(t) { bulge = min(5, grow * 0.03) }
				withAnimation(Motion.layout.delay(0.04)) { bulge = 0 }
			} else {
				withAnimation(Motion.layout) { shown = height }
			}
		} else {
			var t = Transaction()
			t.disablesAnimations = true
			withTransaction(t) { shown = height }
		}
	}

	private var hasBody: Bool {
		session.kind != .none || session.statusLine != nil || session.failure != nil || session.loadingModel
			|| session.overlay == .history
	}

	private var inputRow: some View {
		HStack(alignment: .top, spacing: 14) {
			InputField(session: session, text: session.input, folded: session.inputFolded, onPicture: onPicture, register: registerInput)
				.takesPress()
			rightLabel
				.font(.system(size: 12))
				.foregroundStyle(Color.t3)
				.frame(height: 23)
		}
		.padding(.horizontal, Look.side)
		.padding(.top, 22)
		.padding(.bottom, 17)
	}

	@ViewBuilder private var rightLabel: some View {
		let label = ui.dropping ? "Drop to read its text"
			: session.overlay == .history ? "History"
			: session.input.isEmpty ? (History.shared.items.isEmpty ? "⌘V picture" : "↓ history   ·   ⌘V picture")
			: (session.isStale || session.answeredInput == nil ? Direction(of: session.input) : session.direction).label
		HStack(spacing: 8) {
			if let thumb = ui.thumbnail {
				Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
					.frame(width: 26, height: 19).clipShape(RoundedRectangle(cornerRadius: 4)).opacity(0.75)
			}
			if session.canSwap && !ui.dropping { swapButton } else { Text(label).rowLabel("input", label, edge: .trailing("side")) }
		}
		.fixedSize()
	}

	private var swapButton: some View {
		let from = session.direction == .toEnglish ? "RU" : "EN", to = session.direction == .toEnglish ? "EN" : "RU"
		return Button(action: { session.swapDirection() }) {
			Text("\(from)  \(Image(systemName: "arrow.left.arrow.right"))  \(to)")
				.foregroundStyle(Color.t2)
				.rowLabel("input", from + " ⇄ " + to, edge: .trailing("side"))
				.frame(height: 23)
				.contentShape(Rectangle())
				.overlay(alignment: .top) { if ui.commandHeld { keycap("⌘R").offset(y: -19) } }
		}
		.buttonStyle(.plain)
		.takesPress()
		.help("Translate back")
	}

	private func statusLine(_ text: String) -> some View {
		Text(text)
			.font(.system(size: 13))
			.foregroundStyle(Color.t3)
			.rowWrapping("status", text, size: 13, column: Look.width - 2 * Look.side, edge: .leading("side"))
			.padding(.horizontal, Look.side)
			.padding(.top, 15)
			.frame(maxWidth: .infinity, alignment: .leading)
	}

	@ViewBuilder private var content: some View {
		if session.overlay == .history {
			historyList
		} else if let failure = session.failure {
			statusLine(failure).padding(.bottom, 6)
		} else if session.waitsForModel && session.lines.isEmpty && session.answer.isEmpty {
			VStack(alignment: .leading, spacing: 8) {
				Text(Self.loading).font(.system(size: 13)).foregroundStyle(Color.t3)
					.rowLabel("loading", Self.loading, edge: .leading("side"))
				Relief().frame(height: 46)
			}
			.padding(.horizontal, Look.side).padding(.top, 15).padding(.bottom, 14)
		} else if session.kind == .card {
			card
		} else if session.kind == .text {
			text
		}
	}

	static let loading = "Loading the model"

	private static let listRow = Look.width - 2 * 10 - 2 * 14

	private static func termColumn(_ terms: [String]) -> CGFloat {
		let widest = terms.map { WordWidth.widest($0, size: 20) }.max() ?? 0
		return min(max(220, widest), listRow - 12 - 140)
	}

	private var card: some View {
		let lines = session.lines
		let column = Self.termColumn(lines.map(\.term))
		let pitch = Self.rowPitch(lines.map { ($0.term, $0.note) }, column: column)
		let visible = min(5, session.streaming ? max(3, lines.count) : max(1, lines.count))
		return WheelList(count: lines.count, x: Double(session.selected), pitch: pitch, visible: visible, width: Look.width - 20,
		                 band: !session.isStale && !lines.isEmpty) { i in
			row("card \(i)", term: lines[i].term, note: lines[i].note, column: column, dim: session.isStale)
				.contentShape(Rectangle())
				.onTapGesture { if !session.isStale { session.copyLine(i) } }
				.transition(Motion.develop)
		}
		.animation(Motion.select, value: session.selected)
		.animation(Motion.layout, value: lines.count)
		.takesPress()
		.padding(.horizontal, 10)
		.padding(.vertical, 8)
	}

	private static func rowPitch(_ rows: [(String, String)], column: CGFloat) -> CGFloat {
		let term = NSFont.systemFont(ofSize: 20), note = NSFont.systemFont(ofSize: 13.5)
		let noteWidth = listRow - 12 - column
		let tallest = rows.map { t, n -> CGFloat in
			let tl = ceil((t as NSString).size(withAttributes: [.font: term]).width / column)
			let nl = ceil((n as NSString).size(withAttributes: [.font: note]).width / max(noteWidth, 1))
			return max(min(tl, 2) * 25, nl * 17.5)
		}.max() ?? 25
		return max(40, tallest + 14)
	}

	private func row(_ id: String, term: String, note: String, column: CGFloat, dim: Bool) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 12) {
			Text(term)
				.font(.system(size: 20))
				.foregroundStyle(dim ? Color.t3 : Color.t1)
				.lineLimit(2)
				.rowWrapping(id, term, size: 20, column: column, edge: .leading("side"))
				.frame(width: column, alignment: .leading)
			Text(note)
				.font(.system(size: 13.5))
				.foregroundStyle(Color.t3)
				.rowWrapping(id, note, size: 13.5, column: Self.listRow - 12 - column, edge: .leading("note"))
				.frame(maxWidth: .infinity, alignment: .leading)
		}
		.padding(.horizontal, 14)
	}

	private var text: some View {
		VStack(alignment: .leading, spacing: 0) {
			AnswerView(session: session, animates: ui.animates)
				.padding(.horizontal, Look.side)
				.padding(.top, 17)
				.padding(.bottom, 14)
			if session.overlay == .alternatives { alternatives }
		}
	}

	private var alternatives: some View {
		let alts = session.alternatives
		let column = Self.termColumn(alts.map(\.term))
		let pitch = Self.rowPitch(alts.map { ($0.term, $0.note) }, column: column)
		let rows = alts.count + (session.alternativesPending ? 1 : 0)
		return VStack(spacing: 0) {
			WheelList(count: alts.count, x: Double(session.altSelected), pitch: pitch, visible: min(5, max(rows, 1)),
			          width: Look.width - 20, band: session.ownWord.isEmpty && !alts.isEmpty) { i in
				row("alt \(i)", term: alts[i].term, note: alts[i].note, column: column, dim: false)
					.contentShape(Rectangle())
					.onTapGesture {
						session.altSelected = i
						session.enter()
					}
					.transition(Motion.develop)
			}
			.animation(Motion.select, value: session.altSelected)
			.animation(Motion.layout, value: alts.count)
			.overlay(alignment: .bottomLeading) {
				if session.alternativesPending {
					row("alt …", term: "…", note: "looking for alternatives", column: column, dim: true)
						.frame(height: pitch)
				}
			}
			TextField("", text: $session.ownWord, prompt: Text("your own word…").foregroundStyle(Color.t4))
				.textFieldStyle(.plain)
				.font(.system(size: 15))
				.foregroundStyle(Color.t1)
				.padding(.horizontal, 14).padding(.vertical, 8)
				.onSubmit { session.enter() }
		}
		.takesPress()
		.padding(.horizontal, 10)
		.padding(.bottom, 6)
	}

	private var historyList: some View {
		let items = session.historyRows
		let pitch: CGFloat = 34
		return WheelList(count: items.count, x: Double(session.historySelected ?? 0), pitch: pitch, visible: min(5, max(items.count, 1)),
		                 width: Look.width - 20, band: session.historySelected != nil) { i in
			SplitRow(spacing: 36) {
				Text(items[i].input).font(.system(size: 15.5)).foregroundStyle(Color.t1)
					.rowShortened("history \(i)", items[i].input, edge: .leading("side"))
				Text(items[i].summary).font(.system(size: 13.5)).foregroundStyle(Color.t3)
					.rowShortened("history \(i)", items[i].summary, edge: .trailing("side"))
			}
			.padding(.horizontal, 14)
			.contentShape(Rectangle())
			.onTapGesture {
				session.historySelected = i
				session.enter()
			}
		}
		.animation(Motion.select, value: session.historySelected)
		.takesPress()
		.padding(.horizontal, 10)
		.padding(.vertical, 8)
	}

	private static let gap: CGFloat = 16, tightGap: CGFloat = 10

	private func bar(enter: String) -> some View {
		Group {
			if session.overlay == .ask {
				HStack(spacing: 0) {
					askField
					backButton(gap: Self.gap)
					enterButton(enter, gap: Self.gap)
				}
			} else {
				ViewThatFits(in: .horizontal) {
					barLine(enter, gap: Self.gap)
					barLine(enter, gap: Self.tightGap)
					VStack(alignment: .trailing, spacing: 0) {
						if showsTweaks || session.overlay == .alternatives || session.canGoBack {
							HStack(spacing: 0) {
								leftActions(gap: Self.gap)
								Spacer(minLength: 8)
								backButton(gap: Self.gap)
							}
						}
						enterButton(enter, gap: Self.gap)
					}
					.frame(maxWidth: .infinity, alignment: .trailing)
				}
			}
		}
		.font(.system(size: 13))
		.padding(.vertical, 7)
		.overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 0.5) }
		.padding(.horizontal, 16)
	}

	private func barLine(_ enter: String, gap: CGFloat) -> some View {
		HStack(spacing: 0) {
			leftActions(gap: gap)
			Spacer(minLength: 8)
			backButton(gap: gap)
			enterButton(enter, gap: gap)
		}
		.padding(.horizontal, (Self.gap - gap) / 2)
	}

	private var showsTweaks: Bool { session.kind == .text && session.overlay == .none && !session.isStale }

	@ViewBuilder private func leftActions(gap: CGFloat) -> some View {
		if showsTweaks {
			tweak("Simpler", count: session.style.simpler, key: "⌘1", gap: gap, first: true) { session.tweak(.simpler) }
			tweak("Casual", count: session.style.casual, key: "⌘2", gap: gap) { session.tweak(.casual) }
			tweak("Polite", count: session.style.polite, key: "⌘3", gap: gap) { session.tweak(.polite) }
			tweak("Shorter", count: session.style.shorter, key: "⌘4", gap: gap) { session.tweak(.shorter) }
			tweak("Ask…", count: (session.style.request ?? "").isEmpty ? 0 : 1, key: "⌘5", showCount: false, gap: gap) { session.startAsk() }
		}
	}

	@ViewBuilder private func backButton(gap: CGFloat) -> some View {
		if session.overlay == .alternatives || session.overlay == .ask {
			button("Cancel", key: "esc", gap: gap) { session.escape() }
		} else if session.canGoBack {
			button("Back", key: "⌘Z", gap: gap) { session.back() }
		}
	}

	@ViewBuilder private func enterButton(_ enter: String, gap: CGFloat) -> some View {
		if !enter.isEmpty {
			Button(action: { session.enter() }) {
				HStack(spacing: 6) {
					enterText(enter).foregroundStyle(Color.t1)
					Text("⏎").foregroundStyle(Color.t3).rowLabel("bar", "⏎", edge: .trailing("side"))
				}
				.padding(.horizontal, gap / 2).padding(.vertical, 6)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.takesPress()
		}
	}

	@ViewBuilder private func enterText(_ enter: String) -> some View {
		if let open = enter.firstIndex(of: "“"), let close = enter.lastIndex(of: "”"), open < close {
			let head = String(enter[...open]), term = String(enter[enter.index(after: open)..<close])
			HStack(spacing: 0) {
				Text(head).rowLabel("bar", head)
				Text(term).rowShortened("bar", term, at: .middle)
				Text("”").rowLabel("bar", "”")
			}
		} else {
			Text(enter).rowLabel("bar", enter)
		}
	}

	private var askField: some View {
		HStack(spacing: 9) {
			Text("Ask:").foregroundStyle(Color.t3).rowLabel("bar", "Ask:", edge: .leading("side"))
			AskField(text: $session.askText, onSubmit: { session.enter() }, onCancel: { session.escape() })
				.takesPress()
		}
		.font(.system(size: 14))
		.padding(.horizontal, 8)
	}

	private func tweak(_ title: String, count: Int, key: String, showCount: Bool = true, gap: CGFloat, first: Bool = false,
	                   action: @escaping () -> Void) -> some View {
		Button(action: action) {
			HStack(spacing: 4) {
				Text(title).foregroundStyle(count > 0 ? Color.t1 : Color.t2).rowLabel("bar", title, edge: first ? .leading("side") : nil)
				if showCount && count > 0 { Text("×\(count)").foregroundStyle(Color.t3).rowLabel("bar", title + " ×\(count)") }
			}
			.padding(.horizontal, gap / 2).padding(.vertical, 6)
			.contentShape(Rectangle())
			.overlay(alignment: .top) { if ui.commandHeld { keycap(key).offset(y: -17) } }
		}
		.buttonStyle(.plain)
		.takesPress()
		.disabled(session.streaming || session.restyling)
	}

	private func button(_ title: String, key: String, gap: CGFloat, first: Bool = false, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Text(title).foregroundStyle(Color.t2)
				.rowLabel("bar", title, edge: first ? .leading("side") : nil)
				.padding(.horizontal, gap / 2).padding(.vertical, 6)
				.contentShape(Rectangle())
				.overlay(alignment: .top) { if ui.commandHeld { keycap(key).offset(y: -17) } }
		}
		.buttonStyle(.plain)
		.takesPress()
	}

	private func keycap(_ key: String) -> some View {
		Text(key)
			.font(.system(size: 10.5, weight: .medium))
			.foregroundStyle(Color.t1)
			.padding(.horizontal, 5).padding(.vertical, 3)
			.background(RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.17)))
			.overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
			.rowLabel("keys", key)
	}
}

struct CloseBubble: View {
	var action: () -> Void
	@State private var hover = false

	var body: some View {
		ZStack {
			ShadowedGlass(shape: Circle(), radius: 6, y: 3, opacity: 0.25, reach: 30)
			Circle().strokeBorder(Bar.border, lineWidth: 0.5)
			Button(action: action) {
				Image(systemName: "xmark")
					.font(.system(size: 8.5, weight: .semibold))
					.foregroundStyle(hover ? Color.t1 : Color.t2)
					.frame(width: Look.close.width, height: Look.close.height)
					.contentShape(Circle())
			}
			.buttonStyle(.plain)
			.onHover { hover = $0 }
			.help("Close")
		}
		.frame(width: Look.close.width, height: Look.close.height)
	}
}

enum FormPart: LayoutValueKey {
	static let defaultValue = Part.fixed
	enum Part { case fixed, scroll, bar, emptyBar }
}

struct FormLayout: Layout {
	var shown: CGFloat
	var cap: CGFloat

	struct Placement {
		var shown: CGFloat, natural: CGFloat, fixedTop: CGFloat
		var barTop: CGFloat?, barHeight: CGFloat
	}
	nonisolated(unsafe) static var probe: ((Placement) -> Void)?

	private struct Plan {
		var heights: [CGFloat]
		var natural: CGFloat
		var fixedTop: CGFloat
	}

	private func plan(_ width: CGFloat, _ subviews: Subviews) -> Plan {
		let proposal = ProposedViewSize(width: width, height: nil)
		var heights = subviews.map { $0[FormPart.self] == .scroll ? 0 : $0.sizeThatFits(proposal).height }
		func room(_ i: Int) -> CGFloat { subviews[i][FormPart.self] == .emptyBar ? 0 : heights[i] }
		var fixedTop: CGFloat = 0
		for (i, s) in subviews.enumerated() {
			guard s[FormPart.self] == .fixed else { break }
			fixedTop += heights[i]
		}
		let others = subviews.indices.reduce(0) { $0 + room($1) }
		for (i, s) in subviews.enumerated() where s[FormPart.self] == .scroll {
			let ideal = s.sizeThatFits(proposal).height
			heights[i] = min(ideal, max(cap - others, 60))
		}
		return Plan(heights: heights, natural: subviews.indices.reduce(0) { $0 + room($1) }, fixedTop: fixedTop)
	}

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let width = proposal.width ?? Look.width
		return CGSize(width: width, height: plan(width, subviews).natural)
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		let p = plan(bounds.width, subviews)
		var y = bounds.minY
		var placed = Placement(shown: shown, natural: p.natural, fixedTop: p.fixedTop, barTop: nil, barHeight: 0)
		for (i, s) in subviews.enumerated() {
			let h = p.heights[i]
			var top = y
			let part = s[FormPart.self]
			if part == .bar || part == .emptyBar {
				if shown >= 0 { top = bounds.minY + shown - h }
				if part == .bar {
					placed.barTop = top - bounds.minY
					placed.barHeight = h
				}
			}
			s.place(at: CGPoint(x: bounds.minX, y: top), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: h))
			if part != .emptyBar { y += h }
		}
		Self.probe?(placed)
	}
}

final class FocusingTextField: NSTextField {
	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		guard let w = window else { return }
		DispatchQueue.main.async { [weak self] in
			guard let self, self.window === w, !self.isHiddenOrHasHiddenAncestor else { return }
			w.makeFirstResponder(self)
		}
	}
}

struct AskField: NSViewRepresentable {
	@Binding var text: String
	var onSubmit: () -> Void
	var onCancel: () -> Void

	func makeNSView(context: Context) -> NSTextField {
		let f = FocusingTextField()
		f.isBordered = false
		f.drawsBackground = false
		f.focusRingType = .none
		f.font = .systemFont(ofSize: 14)
		f.textColor = Look.t1
		f.usesSingleLineMode = true
		f.lineBreakMode = .byClipping
		f.cell?.wraps = false
		f.cell?.isScrollable = true
		f.placeholderAttributedString = NSAttributedString(string: "in a few words · for a support email · …",
		                                                    attributes: [.foregroundColor: Look.t4, .font: NSFont.systemFont(ofSize: 14)])
		f.delegate = context.coordinator
		return f
	}

	func updateNSView(_ f: NSTextField, context: Context) {
		if f.stringValue != text { f.stringValue = text }
		context.coordinator.parent = self
	}

	func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
		CGSize(width: proposal.width ?? 120, height: nsView.intrinsicContentSize.height)
	}

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	final class Coordinator: NSObject, NSTextFieldDelegate {
		var parent: AskField
		init(_ parent: AskField) { self.parent = parent }

		func controlTextDidChange(_ obj: Notification) {
			if let f = obj.object as? NSTextField { parent.text = f.stringValue }
		}

		func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
			if selector == #selector(NSResponder.insertNewline(_:)) {
				parent.onSubmit()
				return true
			}
			if selector == #selector(NSResponder.cancelOperation(_:)) {
				parent.onCancel()
				return true
			}
			return false
		}
	}
}

extension View {
	func rowLabel(_ row: String, _ text: String, edge: RowCheck.Edge? = nil) -> some View {
		lineLimit(1).fixedSize().rowProbe(RowCheck.Item(row: row, kind: .label, text: text, edge: edge))
	}

	func rowShortened(_ row: String, _ text: String, at mode: Text.TruncationMode = .tail, edge: RowCheck.Edge? = nil) -> some View {
		lineLimit(1).truncationMode(mode).rowProbe(RowCheck.Item(row: row, kind: .shortened, text: text, edge: edge))
	}

	func rowWrapping(_ row: String, _ text: String, size: CGFloat, column: CGFloat, edge: RowCheck.Edge? = nil) -> some View {
		let word = min(WordWidth.widest(text, size: size), column)
		return rowProbe(RowCheck.Item(row: row, kind: .wrapping, text: text, edge: edge, minWidth: word))
			.frame(minWidth: word, alignment: .leading)
	}
}

struct SplitRow: Layout {
	var spacing: CGFloat
	var share: CGFloat = 0.6

	private func widths(_ width: CGFloat?, _ subviews: Subviews) -> (CGFloat, CGFloat) {
		let a = subviews[0].sizeThatFits(.unspecified).width, b = subviews[1].sizeThatFits(.unspecified).width
		guard let width, width.isFinite else { return (a, b) }
		let room = max(0, width - spacing)
		if a + b <= room { return (a, b) }
		let first = min(a, max(room * share, room - b))
		return (first, room - first)
	}

	private func tops(_ w: (CGFloat, CGFloat), _ subviews: Subviews) -> (CGFloat, CGFloat, height: CGFloat) {
		let d0 = subviews[0].dimensions(in: ProposedViewSize(width: w.0, height: nil))
		let d1 = subviews[1].dimensions(in: ProposedViewSize(width: w.1, height: nil))
		let base = max(d0[.firstTextBaseline], d1[.firstTextBaseline])
		let y0 = base - d0[.firstTextBaseline], y1 = base - d1[.firstTextBaseline]
		return (y0, y1, max(y0 + d0.height, y1 + d1.height))
	}

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		guard subviews.count == 2 else { return .zero }
		let w = widths(proposal.width, subviews)
		let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? w.0 + spacing + w.1
		return CGSize(width: width, height: tops(w, subviews).height)
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		guard subviews.count == 2 else { return }
		let w = widths(bounds.width, subviews)
		let t = tops(w, subviews)
		subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + t.0), anchor: .topLeading,
		                  proposal: ProposedViewSize(width: w.0, height: nil))
		subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.minY + t.1), anchor: .topTrailing,
		                  proposal: ProposedViewSize(width: w.1, height: nil))
	}
}

enum RowCheck {
	enum Kind { case label, shortened, wrapping }
	enum Edge: Hashable { case leading(String), trailing(String) }
	struct Item {
		var row: String
		var kind: Kind
		var text: String
		var edge: Edge?
		var minWidth: CGFloat = 0
		var ideal = CGSize.zero
		var frame = CGRect.null
	}
	static let space = "rows"
	nonisolated(unsafe) static var items: [String: Item]?
}

extension View {
	func rowProbe(_ item: RowCheck.Item) -> some View { modifier(RowProbe(item: item)) }
}

private struct RowProbe: ViewModifier {
	let item: RowCheck.Item
	@Environment(\.wheelOffAnchor) private var offAnchor
	@Environment(\.inWheel) private var inWheel

	func body(content: Content) -> some View {
		if RowCheck.items == nil || offAnchor {
			content
		} else {
			let key = item.row + "|" + item.text
			var item = self.item
			let _ = inWheel ? (item.edge = nil) : ()
			ProbeLayout(item: item, key: key) { content }
				.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(RowCheck.space)) }) { frame in
					var it = RowCheck.items?[key] ?? item
					it.frame = frame
					RowCheck.items?[key] = it
				}
		}
	}
}

private struct ProbeLayout: Layout {
	let item: RowCheck.Item
	let key: String

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		subviews.first?.sizeThatFits(proposal) ?? .zero
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		guard let s = subviews.first else { return }
		s.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
		var it = RowCheck.items?[key] ?? item
		it.ideal = s.sizeThatFits(.unspecified)
		RowCheck.items?[key] = it
	}
}

enum WordWidth {
	static func widest(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
		let font = NSFont.systemFont(ofSize: size, weight: weight)
		let widths = text.split(whereSeparator: \.isWhitespace).map { (String($0) as NSString).size(withAttributes: [.font: font]).width }
		return ((widths.max() ?? 0) * 2).rounded(.up) / 2
	}
}
