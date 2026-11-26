import AppKit
import SwiftUI

enum Look {
	static let background = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
	static let t1 = NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
	static let t2 = NSColor(white: 1, alpha: 0.62)
	static let t3 = NSColor(white: 1, alpha: 0.42)
	static let t4 = NSColor(white: 1, alpha: 0.27)
	static let selection = NSColor(white: 1, alpha: 0.085)
	static let inputSize: CGFloat = 18.5
	static let answerSize: CGFloat = 22
	static let inputFont = NSFont.systemFont(ofSize: inputSize)
	static let answerFont = NSFont.systemFont(ofSize: answerSize)
	static let answerLine: CGFloat = 31
	static let width: CGFloat = 600
	static let side: CGFloat = 24
	static let corner: CGFloat = 24
	static let inputMaxHeight: CGFloat = 7 * 23
	static let close = CGRect(x: -17, y: -17, width: 22, height: 22)

	static let margin = NSEdgeInsets(top: 30, left: 44, bottom: 64, right: 44)
	static let shadowOpacity: Double = 0.3
	static let shadowRadius: CGFloat = 24
	static let shadowY: CGFloat = 14
	static let screenGap: CGFloat = 24
}

extension NSAttributedString.Key {
	static let mark = NSAttributedString.Key("translator.mark")
	static let pick = NSAttributedString.Key("translator.pick")
}

final class MarkLayoutManager: NSLayoutManager {
	override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
		super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
		eachRun(of: .pick, in: glyphsToShow) { _, rect, _, _, _ in
			NSColor(white: 1, alpha: 0.12).setFill()
			NSBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -3, dy: 1), xRadius: 5, yRadius: 5).fill()
		}
	}

	override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
		super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
		eachRun(of: .mark, in: glyphsToShow) { value, rect, baseline, font, piece in
			guard let kind = value as? String else { return }
			if kind == "changed" {
				self.drawDots(piece: piece, baseline: origin.y + baseline, x0: origin.x, font: font,
				              color: NSColor(white: 1, alpha: 0.6))
				return
			}
			let y = origin.y + baseline - font.descender + 2.5
			let path = NSBezierPath()
			path.move(to: NSPoint(x: origin.x + rect.minX, y: y))
			path.line(to: NSPoint(x: origin.x + rect.maxX, y: y))
			NSColor(white: 1, alpha: 0.38).setStroke()
			path.lineWidth = 1
			path.stroke()
		}
	}

	private func drawDots(piece: NSRange, baseline: CGFloat, x0: CGFloat, font: NSFont, color: NSColor) {
		let depth: CGFloat = 3.2, dot: CGFloat = 1.6, step: CGFloat = 3.9
		var gaps: [ClosedRange<CGFloat>] = []
		var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
		for g in piece.location..<NSMaxRange(piece) {
			let x = x0 + lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minX + location(forGlyphAt: g).x
			let glyph = cgGlyph(at: g)
			let ink = font.boundingRect(forCGGlyph: glyph)
			let advance = font.advancement(forCGGlyph: glyph).width
			minX = min(minX, x)
			maxX = max(maxX, x + advance)
			if ink.width > 0, ink.minY < -(depth - dot / 2 - 0.4) { gaps.append((x + ink.minX - 1.6)...(x + ink.maxX + 1.6)) }
		}
		guard maxX > minX else { return }
		color.setFill()
		let y = baseline + depth
		var x = minX + dot / 2
		while x <= maxX - dot / 2 {
			if !gaps.contains(where: { $0.contains(x) }) {
				NSBezierPath(ovalIn: NSRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)).fill()
			}
			x += step
		}
	}

	private func eachRun(of key: NSAttributedString.Key, in glyphs: NSRange,
	                     _ body: @escaping (Any, NSRect, CGFloat, NSFont, NSRange) -> Void) {
		guard let storage = textStorage, let container = textContainers.first else { return }
		let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
		storage.enumerateAttribute(key, in: chars) { value, range, _ in
			guard let value else { return }
			let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? Look.inputFont
			let runGlyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
			enumerateLineFragments(forGlyphRange: runGlyphs) { fragment, _, _, lineGlyphs, _ in
				let piece = NSIntersectionRange(runGlyphs, lineGlyphs)
				guard piece.length > 0 else { return }
				let rect = self.boundingRect(forGlyphRange: piece, in: container)
				let baseline = fragment.minY + self.location(forGlyphAt: piece.location).y
				body(value, NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height), baseline, font, piece)
			}
		}
	}
}

class MarkedTextView: NSTextView {
	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

	convenience init(font: NSFont) {
		let storage = NSTextStorage()
		let layout = MarkLayoutManager()
		storage.addLayoutManager(layout)
		let container = NSTextContainer(size: NSSize(width: Look.width - 2 * Look.side, height: .greatestFiniteMagnitude))
		container.widthTracksTextView = true
		container.lineFragmentPadding = 0
		layout.addTextContainer(container)
		self.init(frame: .zero, textContainer: container)
		drawsBackground = false
		isRichText = false
		self.font = font
		textColor = Look.t1
		textContainerInset = NSSize(width: 0, height: 0)
		isVerticallyResizable = true
		isHorizontallyResizable = false
	}

	static let paragraph = NSParagraphStyle()

}

@MainActor
final class TextHeight {
	static let shared = TextHeight()
	private let storage = NSTextStorage()
	private let layout = NSLayoutManager()
	private let container = NSTextContainer(size: .zero)
	private var cache: [String: CGFloat] = [:]

	private init() {
		container.lineFragmentPadding = 0
		layout.addTextContainer(container)
		storage.addLayoutManager(layout)
	}

	func of(_ text: String, font: NSFont, width: CGFloat, lineSpacing: CGFloat = 0) -> CGFloat {
		let width = min(max(width, 1), 100_000)
		let key = "\(font.pointSize)|\(lineSpacing)|\(width)|\(text)"
		if let h = cache[key] { return h }
		let p = NSMutableParagraphStyle()
		p.lineSpacing = lineSpacing
		storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: p]))
		container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
		layout.ensureLayout(for: container)
		let h = ceil(max(layout.usedRect(for: container).height, font.boundingRectForFont.height)) + 1
		if cache.count > 200 { cache.removeAll() }
		cache[key] = h
		return h
	}
}

final class InputTextView: MarkedTextView {
	weak var session: Session?
	var placeholder = "Word, phrase or text"

	static func height(of text: String, width: CGFloat, folded: Bool) -> CGFloat {
		let full = TextHeight.shared.of(text, font: Look.inputFont, width: width)
		return folded && full > oneLine ? oneLine : min(full, Look.inputMaxHeight)
	}

	static var oneLine: CGFloat { TextHeight.shared.of("Ag", font: Look.inputFont, width: 1000) }

	var foldWanted = false {
		didSet { if foldWanted != oldValue { needsDisplay = true } }
	}
	var folded: Bool { foldWanted && TextHeight.shared.of(string, font: Look.inputFont, width: bounds.width) > Self.oneLine }
	var onOpen: (() -> Void)?

	override var shouldDrawInsertionPoint: Bool { !folded && super.shouldDrawInsertionPoint }

	override func mouseDown(with event: NSEvent) {
		if string.isEmpty, let panel = window as? KeyPanel {
			window?.makeFirstResponder(self)
			panel.beginDrag()
			return
		}
		if folded {
			foldWanted = false
			onOpen?()
		}
		super.mouseDown(with: event)
	}

	override func selectAll(_ sender: Any?) {
		if folded {
			foldWanted = false
			onOpen?()
		}
		super.selectAll(sender)
	}

	private let firstLine = FirstLine()

	var onPicture: ((CGImage) -> Void)?
	var drop: PictureDrop?

	override var acceptsFirstResponder: Bool { true }

	override var acceptableDragTypes: [NSPasteboard.PasteboardType] { super.acceptableDragTypes + OCR.dragTypes }

	private func picture(_ info: NSDraggingInfo) -> Bool { drop?.accepts(info) == true }

	override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
		picture(sender) ? drop?.over(sender) ?? [] : super.draggingEntered(sender)
	}

	override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
		picture(sender) ? drop?.over(sender) ?? [] : super.draggingUpdated(sender)
	}

	override func draggingExited(_ sender: NSDraggingInfo?) {
		drop?.left()
		super.draggingExited(sender)
	}

	override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
		picture(sender) || super.prepareForDragOperation(sender)
	}

	override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
		picture(sender) ? drop?.dropped(sender) ?? false : super.performDragOperation(sender)
	}

	override func concludeDragOperation(_ sender: NSDraggingInfo?) {
		if let sender, picture(sender) { return }
		super.concludeDragOperation(sender)
	}

	override func setFrameSize(_ newSize: NSSize) {
		let old = frame.height
		super.setFrameSize(newSize)
		if abs(old - newSize.height) > 0.01 { enclosingScrollView?.invalidateIntrinsicContentSize() }
	}

	override func draw(_ dirtyRect: NSRect) {
		if folded { return firstLine.draw(string, width: bounds.width, at: NSPoint(x: 0, y: visibleRect.minY)) }
		super.draw(dirtyRect)
		guard string.isEmpty else { return }
		let attrs: [NSAttributedString.Key: Any] = [.font: Look.inputFont, .foregroundColor: Look.t4]
		(placeholder as NSString).draw(at: NSPoint(x: 1, y: 0), withAttributes: attrs)
	}

	override func keyDown(with event: NSEvent) {
		guard let session else { return super.keyDown(with: event) }
		let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
		switch Int(event.keyCode) {
		case 36, 76:
			if mods == .shift || mods == .option { insertNewlineIgnoringFieldEditor(nil) }
			else if mods.isEmpty { session.enter() }
			else { super.keyDown(with: event) }
		case 53:
			session.escape()
		case 9 where mods == .control:
			paste(nil)
		case 126:
			if !(mods.isEmpty && onFirstLine && session.move(-1)) { super.keyDown(with: event) }
		case 125:
			if !(mods.isEmpty && onLastLine && session.move(1)) { super.keyDown(with: event) }
		default:
			super.keyDown(with: event)
		}
	}

	override func performKeyEquivalent(with event: NSEvent) -> Bool {
		guard event.type == .keyDown, let session else { return super.performKeyEquivalent(with: event) }
		let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
		guard mods.contains(.command) else { return super.performKeyEquivalent(with: event) }
		switch Int(event.keyCode) {
		case 18, 19, 20, 21, 23:
			let n = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5][Int(event.keyCode)]!
			if n == 5 { session.startAsk() }
			else { session.tweak([.simpler, .casual, .polite, .shorter][n - 1]) }
		default:
			switch EditKeys.letter(of: event) {
			case "w": session.onClose?()
			case "r": session.swapDirection()
			default: return super.performKeyEquivalent(with: event)
			}
		}
		return true
	}

	override func paste(_ sender: Any?) {
		if let image = OCR.image(from: EditKeys.board) { onPicture?(image) }
		else if EditKeys.board === NSPasteboard.general { pasteAsPlainText(sender) }
		else { _ = readSelection(from: EditKeys.board, type: .string) }
	}

	override func copy(_ sender: Any?) {
		if selectedRange().length > 0 { _ = writeSelection(to: EditKeys.board, types: writablePasteboardTypes) } else { session?.copy() }
	}

	override func cut(_ sender: Any?) {
		guard selectedRange().length > 0, writeSelection(to: EditKeys.board, types: writablePasteboardTypes) else { return }
		delete(sender)
	}

	@objc func undo(_ sender: Any?) {
		if let session, session.canGoBack { session.back() } else { undoManager?.undo() }
	}

	@objc func redo(_ sender: Any?) {
		undoManager?.redo()
	}

	private var caretLine: (first: Bool, last: Bool) {
		guard let layout = layoutManager, let container = textContainer, !string.isEmpty else { return (true, true) }
		let caret = selectedRange().location
		let glyph = layout.glyphIndexForCharacter(at: min(caret, (string as NSString).length - 1))
		let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
		let all = layout.usedRect(for: container)
		return (line.minY <= all.minY + 1, line.maxY >= all.maxY - 1 || caret >= (string as NSString).length)
	}

	private var onFirstLine: Bool { caretLine.first }
	private var onLastLine: Bool { caretLine.last }
}

@MainActor
final class FirstLine {
	private let storage = NSTextStorage()
	private let layout = NSLayoutManager()
	private let container = NSTextContainer(size: .zero)
	private var last: (key: String, line: String)?

	init() {
		container.lineFragmentPadding = 0
		layout.addTextContainer(container)
		storage.addLayoutManager(layout)
	}

	func draw(_ text: String, width: CGFloat, at origin: NSPoint) {
		container.size = NSSize(width: max(width, 1), height: .greatestFiniteMagnitude)
		set(line(of: text, width: width))
		layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: origin)
	}

	private func set(_ s: String) {
		storage.setAttributedString(NSAttributedString(string: s, attributes: InputField.base))
	}

	private func fits(_ s: String) -> Bool {
		set(s)
		var lines = 0
		layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, stop in
			lines += 1
			if lines > 1 { stop.pointee = true }
		}
		return lines <= 1
	}

	private func line(of text: String, width: CGFloat) -> String {
		let key = "\(width)|\(text)"
		if let last, last.key == key { return last.line }
		let rows = text.components(separatedBy: "\n")
		var line = ""
		if let i = rows.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
			let more = rows[(i + 1)...].contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
			line = rows[i] + (more ? " …" : "")
			if !fits(line) {
				let chars = Array(rows[i])
				func cut(_ n: Int) -> String {
					var s = String(chars[..<n])
					while let l = s.last, l.isWhitespace { s.removeLast() }
					return s + "…"
				}
				var lo = 0, hi = chars.count
				while hi - lo > 1 {
					let mid = (lo + hi) / 2
					if fits(cut(mid)) { lo = mid } else { hi = mid }
				}
				line = cut(lo)
			}
		}
		last = (key, line)
		return line
	}
}

final class InputScrollView: NSScrollView {
	var textView: InputTextView? { documentView as? InputTextView }

	override func scrollWheel(with event: NSEvent) {
		if textView?.folded == true { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
	}

	override func tile() {
		super.tile()
		guard let t = textView else { return }
		let h = contentSize.height
		if t.minSize.height != h {
			t.minSize = NSSize(width: 0, height: h)
			t.sizeToFit()
		}
	}
}

struct InputField: NSViewRepresentable {
	let session: Session
	var text: String
	var folded: Bool
	var onPicture: (CGImage) -> Void
	var register: (InputTextView) -> Void = { _ in }

	func makeCoordinator() -> Coordinator { Coordinator(session) }

	func makeNSView(context: Context) -> InputScrollView {
		let v = InputTextView(font: Look.inputFont)
		v.autoresizingMask = [.width]
		v.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
		v.session = session
		v.delegate = context.coordinator
		v.insertionPointColor = Look.t1
		v.allowsUndo = true
		v.isAutomaticQuoteSubstitutionEnabled = false
		v.isAutomaticDashSubstitutionEnabled = false
		v.isAutomaticTextReplacementEnabled = false
		v.isContinuousSpellCheckingEnabled = false
		v.isAutomaticSpellingCorrectionEnabled = false
		v.typingAttributes = Self.base
		v.onPicture = onPicture
		v.onOpen = { [weak session] in session?.openInput() }
		context.coordinator.view = v
		let scroll = InputScrollView()
		scroll.drawsBackground = false
		scroll.borderType = .noBorder
		scroll.hasVerticalScroller = true
		scroll.autohidesScrollers = true
		scroll.scrollerStyle = .overlay
		scroll.verticalScrollElasticity = .none
		scroll.horizontalScrollElasticity = .none
		scroll.documentView = v
		register(v)
		return scroll
	}

	static var base: [NSAttributedString.Key: Any] {
		[.font: Look.inputFont, .foregroundColor: Look.t1, .paragraphStyle: MarkedTextView.paragraph]
	}

	func updateNSView(_ scroll: InputScrollView, context: Context) {
		guard let v = scroll.textView else { return }
		if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
		let c = context.coordinator
		if c.version != session.inputVersion || v.string != session.input {
			c.version = session.inputVersion
			if v.string != session.input {
				v.undoManager?.removeAllActions()
				v.string = session.input
				v.textStorage?.setAttributes(Self.base, range: NSRange(location: 0, length: v.textStorage?.length ?? 0))
				v.typingAttributes = Self.base
				v.setSelectedRange(NSRange(location: (session.input as NSString).length, length: 0))
				scroll.invalidateIntrinsicContentSize()
				v.breakUndoCoalescing()
				c.undo.removeAllActions()
				v.needsDisplay = true
			}
		}
		if v.foldWanted != folded {
			v.foldWanted = folded
			scroll.invalidateIntrinsicContentSize()
		}
		if folded { v.scroll(.zero) }
	}

	func sizeThatFits(_ proposal: ProposedViewSize, nsView: InputScrollView, context: Context) -> CGSize? {
		let width = proposal.width ?? 400
		return CGSize(width: width, height: InputTextView.height(of: text, width: width, folded: folded))
	}

	final class Coordinator: NSObject, NSTextViewDelegate {
		let session: Session
		var version = -1
		weak var view: InputTextView?
		let undo = UndoManager()
		init(_ session: Session) { self.session = session }

		func undoManager(for view: NSTextView) -> UndoManager? { undo }

		func textDidChange(_ notification: Notification) {
			guard let v = view else { return }
			v.enclosingScrollView?.invalidateIntrinsicContentSize()
			MainActor.assumeIsolated { session.edited(v.string) }
		}
	}
}

final class AnswerTextView: MarkedTextView {
	var onPick: ((NSRange) -> Void)?
	var pickable = true
	private var hover: NSRange?
	private var area: NSTrackingArea?

	override var acceptsFirstResponder: Bool { false }

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let area { removeTrackingArea(area) }
		let a = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
		addTrackingArea(a)
		area = a
	}

	private func word(at point: NSPoint) -> NSRange? {
		guard let layout = layoutManager, let container = textContainer, !string.isEmpty else { return nil }
		var fraction: CGFloat = 0
		let glyph = layout.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
		let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
		guard rect.insetBy(dx: -2, dy: -3).contains(point) else { return nil }
		let index = layout.characterIndexForGlyph(at: glyph)
		let ns = string as NSString
		var found: NSRange?
		ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { _, range, _, stop in
			if NSLocationInRange(index, range) {
				found = range
				stop.pointee = true
			}
		}
		return found
	}

	override func mouseMoved(with event: NSEvent) {
		let w = pickable ? word(at: convert(event.locationInWindow, from: nil)) : nil
		guard w != hover else { return }
		setHover(w)
	}

	override func mouseExited(with event: NSEvent) { setHover(nil) }

	private func setHover(_ range: NSRange?) {
		guard let storage = textStorage else { return }
		if let old = hover, NSMaxRange(old) <= storage.length, storage.attribute(.mark, at: old.location, effectiveRange: nil) as? String == "hover" {
			storage.removeAttribute(.mark, range: old)
		}
		hover = range
		if let range, NSMaxRange(range) <= storage.length, storage.attribute(.mark, at: range.location, effectiveRange: nil) == nil {
			storage.addAttribute(.mark, value: "hover", range: range)
		}
		NSCursor.pointingHand.set()
		if range == nil { NSCursor.arrow.set() }
		needsDisplay = true
	}

	override func mouseDown(with event: NSEvent) {
		guard pickable, let w = word(at: convert(event.locationInWindow, from: nil)) else { return }
		setHover(nil)
		onPick?(w)
	}
}

struct AnswerText: NSViewRepresentable {
	var text: String
	var dim: Bool
	var marks: [NSRange]
	var picked: NSRange?
	var font: NSFont = Look.answerFont
	var color: NSColor = Look.t1
	var pickable: Bool
	var onPick: (NSRange) -> Void

	func makeNSView(context: Context) -> AnswerTextView {
		let v = AnswerTextView(font: font)
		v.isEditable = false
		v.isSelectable = false
		return v
	}

	private var lineSpacing: CGFloat { max(0, Look.answerLine - ceil(font.ascender - font.descender + font.leading)) }

	func updateNSView(_ v: AnswerTextView, context: Context) {
		v.pickable = pickable
		v.onPick = onPick
		let paragraph = NSMutableParagraphStyle()
		paragraph.lineSpacing = lineSpacing
		let s = NSMutableAttributedString(string: text, attributes: [
			.font: font, .foregroundColor: dim ? NSColor(white: 1, alpha: 0.36) : color,
			.paragraphStyle: paragraph,
		])
		let length = s.length
		for m in marks where NSMaxRange(m) <= length { s.addAttribute(.mark, value: "changed", range: m) }
		if let p = picked, NSMaxRange(p) <= length { s.addAttribute(.pick, value: true, range: p) }
		if v.textStorage?.isEqual(to: s) != true {
			v.textStorage?.setAttributedString(s)
			v.needsDisplay = true
		}
	}

	func sizeThatFits(_ proposal: ProposedViewSize, nsView: AnswerTextView, context: Context) -> CGSize? {
		let width = proposal.width ?? 400
		return CGSize(width: width, height: TextHeight.shared.of(text, font: font, width: width, lineSpacing: lineSpacing))
	}
}
