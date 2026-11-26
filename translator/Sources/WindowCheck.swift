import AppKit
import SwiftUI

@MainActor
enum WindowCheck {
	nonisolated(unsafe) private static var latest: FormLayout.Placement?
	private static var failed = 0
	private static var passed = 0
	private static var c: PanelController!
	private static var frame0 = NSRect.zero
	private static var inputTop0: CGFloat = 0
	private static var dir: String?

	private static let laptop = NSRect(x: 0, y: 0, width: 1512, height: 944)
	private static let second = NSRect(x: 1512, y: -300, width: 1920, height: 1055)
	private static let short = NSRect(x: 0, y: 0, width: 1280, height: 520)

	private struct Frame {
		var time: TimeInterval
		var natural, fixedTop, barHeight, cap: CGFloat
		var hasBar: Bool
		var window: NSRect
		var inputTop, inputHeight: CGFloat
		var height: CGFloat
		var barTop: CGFloat?
		var light: Int?
		var field: Int?
	}

	private static func check(_ ok: Bool, _ what: String) {
		if ok { passed += 1 } else { failed += 1 }
		print((ok ? "  ✓ " : "  ✗ ") + what)
	}

	static func run(_ dir: String?) -> Int32 {
		MotionFlags.drop = false
		MotionFlags.glass = false

		_ = NSApplication.shared
		self.dir = dir
		if let dir { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
		FormLayout.probe = { latest = $0 }
		c = PanelController()
		let s = c.session
		let en = "I want to complain about the delivery — the courier was two hours late, and nobody called to say so. "

		print("Открытие с готовым ответом (первое): форма сразу своего размера")
		s.showDemo("07-text")
		opened(on: laptop)
		step("пауза после открытия", animated: false) {}

		print("Клики: форма берёт свои, остальное окно пропускает к окнам ниже")
		if let h = frame(name: nil)?.height {
			check(onForm(h / 2), "клик в середине формы — по форме")
			check(!onForm(h / 2, x: -12) && !onForm(-8), "клик в тень у края формы — мимо")
			check(!onForm(h + 40), "клик под формой (в пустом запасе окна) — мимо")
		}

		print("Esc к пустому полю: форма сжимается")
		step("сжатие к пустому", shoot: "shrink") { s.showDemo("01-empty") }

		print("Набор текста: поле растёт по строке, после 7 строк прокручивается внутри")
		var typed: [String] = []
		steadyField = false
		for i in 1...9 {
			typed.append("Строка \(i) длинного текста, вставленного в поле")
			step("строк в поле: \(i)", animated: i <= 7 ? true : nil, frames: 0.4, shoot: i == 3 ? "typing" : nil) {
				s.demoInput(typed.joined(separator: "\n"))
			}
		}
		steadyField = true
		if let field = c.inputView, let scroll = field.enclosingScrollView {
			check(abs(scroll.frame.height - Look.inputMaxHeight) < 0.5 && field.frame.height > scroll.contentSize.height + 26,
			      "9 строк: поле \(Int(scroll.frame.height)) pt, текст \(Int(field.frame.height)) pt прокручивается внутри")
		}

		print("Enter: появляется карточка слова (рост сразу на несколько строк)")
		step("пусто", animated: nil) { s.showDemo("01-empty") }
		step("пусто → карточка", shoot: "grow") { s.showDemo("03-word") }

		print("Ответ потоком: текст растёт по слову, форма следует плавно")
		step("новый ввод фразы", animated: nil) {
			s.showDemo("07-text")
			s.demoAnswer("", streaming: true)
		}
		var words: [String] = []
		var stream: [() -> Void] = []
		for w in (en + en + en).split(separator: " ") {
			words.append(String(w))
			let text = words.joined(separator: " ")
			stream.append { s.demoAnswer(text, streaming: true) }
		}
		stream.append { s.demoAnswer(words.joined(separator: " "), streaming: false) }
		flow("поток \(words.count) слов", stream, every: 0.03)

		print("Строка статуса и перевод на русский")
		step("статус «Читаю картинку…» над ответом", animated: nil) { s.demoStatus(Session.readingPicture) }
		step("перевод на русский: кнопка «наоборот»", animated: nil, shoot: "russian") { s.showDemo("13-russian") }

		print("Подсказки клавиш (⌘ зажат): размер не меняется")
		step("⌘ зажат", animated: false, shoot: "hints") { c.ui.commandHeld = true }
		step("⌘ отпущен", animated: false) { c.ui.commandHeld = false }

		print("Список замен слова: открыть и закрыть")
		step("ответ", animated: nil) { s.showDemo("07-text") }
		step("замены открыты", shoot: "alt-open") { s.showDemo("09-alternatives") }
		step("Esc: замены закрыты", shoot: "alt-close") { s.escape() }
		step("замены снова", animated: nil) { s.showDemo("09-alternatives") }
		s.escape()
		for _ in 0..<2 { _ = tick(name: nil) }
		let during = onForm(395), drawn = frame(name: nil)?.height ?? 0
		let end = Date().addingTimeInterval(0.6)
		while Date() < end { _ = tick(name: nil) }
		check(during && !onForm(395), "пока форма сжимается (нарисовано \(Int(drawn)) pt), её низ ещё берёт клики; потом — уже нет")

		print("Просьба, «Проще», история, сбой, картинка")
		step("поле просьбы", animated: nil) { s.showDemo("11-ask") }
		step("«Проще»: ответ короче", animated: nil) { s.showDemo("10-simpler") }
		step("история ↓", shoot: "history") { s.showDemo("16-history") }
		step("Esc: история закрыта", shoot: "history-close") { s.escape() }
		step("сбой", animated: nil) { s.showDemo("17-failure") }
		step("картинка в поле (миниатюра) и ответ", animated: nil) {
			c.ui.thumbnail = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { r in NSColor.gray.setFill(); r.fill(); return true }
			s.showDemo("07-text")
		}
		c.ui.thumbnail = nil

		print("Очень длинный ответ: предел высоты, прокрутка внутри, панель видна")
		let long = (1...40).map { "Line \($0): " + en }.joined()
		let tall = step("длинный ответ", shoot: "long") {
			s.showDemo("07-text")
			s.demoAnswer(long, streaming: false)
		}
		if let f = tall.last {
			check(f.natural <= f.cap + 0.5 && f.natural > f.cap - 60, "форма упёрлась в предел: \(Int(f.natural)) из \(Int(f.cap)) pt")
			check(f.barTop.map { abs($0 + f.barHeight - f.height) <= 1 } ?? false, "панель действий внизу формы, на виду")
		}

		print("Перетаскивание окна вниз: предел уменьшается, форма сжимается плавно")
		if let p = c.window {
			p.setFrameOrigin(NSPoint(x: p.frame.minX, y: p.frame.minY - 300))
			frame0 = p.frame
			step("окно ниже на 300 pt", shoot: "dragged") { c.refit(in: laptop) }
			p.setFrameOrigin(NSPoint(x: p.frame.minX, y: p.frame.minY + 300))
			frame0 = p.frame
			step("окно обратно", animated: nil) { c.refit(in: laptop) }
		}

		print("Повторное открытие на другом экране, с другим готовым ответом")
		hidden { s.reset() }
		s.showDemo("13-russian")
		opened(on: second)
		step("пауза после открытия", animated: false) {}

		print("Повторное открытие, когда скрытое окно не успело перерисоваться")
		hidden { s.showDemo("09-alternatives") }
		s.reset()
		s.showDemo("03-word")
		opened(on: laptop)
		step("пауза после открытия", animated: false) {}

		print("Открытие у края: короткий экран, длинный ответ")
		hidden { s.reset() }
		s.showDemo("07-text")
		s.demoAnswer(long, streaming: false)
		opened(on: short)
		let edge = step("пауза после открытия", animated: false) {}
		if let f = edge.last, let p = c.window {
			let formBottom = p.frame.maxY - Look.margin.top - f.height
			check(formBottom >= short.minY + Look.screenGap - 0.5, "низ формы над краем экрана: \(Int(formBottom - short.minY)) pt")
		}

		print(failed == 0 ? "✓ \(passed) checks passed" : "✗ \(failed) failed, \(passed) passed")
		return failed == 0 ? 0 : 1
	}

	private static func onForm(_ y: CGFloat, x: CGFloat = Look.width / 2) -> Bool {
		guard let p = c.window else { return false }
		let point = NSPoint(x: Look.margin.left + x, y: p.frame.height - Look.margin.top - y)
		return p.isOnForm?(point) ?? false
	}

	private static func opened(on area: NSRect) {
		let p = c.prepare(in: area)
		guard let f = frame(name: nil) else { return check(false, "открытие: нет раскладки") }
		check(c.inputView != nil, "поле ввода создано до показа окна")
		check(abs(f.height - f.natural) <= 0.5, "первый кадр: форма сразу \(Int(f.natural)) pt (нарисовано \(f.height))")
		let formTop = p.frame.maxY - Look.margin.top
		check(abs(formTop - (area.maxY - area.height * 0.24).rounded()) < 0.5 && abs(p.frame.midX - area.midX) < 1,
		      "верх формы на четверти высоты экрана, по центру")
		check(formTop - c.ui.cap >= area.minY + Look.screenGap - 0.5, "самая высокая форма помещается на экран")
		frame0 = p.frame
		inputTop0 = f.inputTop
		c.ui.animates = true
	}

	private static func hidden(_ change: () -> Void) {
		c.ui.animates = false
		change()
		let end = Date().addingTimeInterval(0.1)
		while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120)) }
	}

	private static var ticks = 0

	private static func tick(name: String?) -> Frame? {
		RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
		c.window?.contentView?.layoutSubtreeIfNeeded()
		ticks += 1
		return frame(name: name, full: name != nil || ticks % 3 == 0)
	}

	private static func frame(name: String?, full: Bool = true) -> Frame? {
		guard let p = c.window, let l = latest else { return nil }
		var top: CGFloat = -1, height: CGFloat = -1
		if let field = c.inputView?.enclosingScrollView {
			let r = field.convert(field.bounds, to: nil)
			top = p.frame.height - r.maxY
			height = r.height
		}
		guard let drawn = columns(barHeight: l.barTop == nil ? nil : l.barHeight) else { return nil }
		let whole = full ? render(height: drawn.height, fixedTop: l.fixedTop, name: name) : nil
		return Frame(time: Date().timeIntervalSinceReferenceDate, natural: l.natural, fixedTop: l.fixedTop, barHeight: l.barHeight,
		             cap: c.ui.cap, hasBar: l.barTop != nil, window: p.frame, inputTop: top, inputHeight: height,
		             height: drawn.height, barTop: drawn.barTop, light: whole?.light, field: whole?.field)
	}

	@discardableResult
	private static func step(_ title: String, animated: Bool? = true, frames seconds: Double = 0.6, shoot: String? = nil,
	                         _ change: () -> Void) -> [Frame] {
		guard let before = frame(name: nil) else {
			check(false, "\(title): нет раскладки")
			return []
		}
		change()
		changed = Date().timeIntervalSinceReferenceDate
		var frames: [Frame] = []
		let end = Date().addingTimeInterval(seconds)
		while Date() < end {
			let n = frames.count + 1
			let name = shoot.flatMap { [2, 4, 7].contains(n) ? "\($0)-\(n)" : nil }
			if let f = tick(name: name) { frames.append(f) }
		}
		if let f = frame(name: shoot.map { "\($0)-end" }) { frames.append(f) }
		verify(title, from: before, frames, animated: animated, growing: nil)
		return frames
	}

	private static func flow(_ title: String, _ changes: [() -> Void], every interval: Double) {
		guard let before = frame(name: nil) else { return }
		changed = Date().timeIntervalSinceReferenceDate
		var frames: [Frame] = []
		for (i, change) in changes.enumerated() {
			change()
			let end = Date().addingTimeInterval(interval)
			repeat {
				if let f = tick(name: i % 20 == 10 ? "stream-\(i)" : nil) { frames.append(f) }
			} while Date() < end
		}
		let end = Date().addingTimeInterval(0.6)
		while Date() < end { if let f = tick(name: nil) { frames.append(f) } }
		if let f = frame(name: nil) { frames.append(f) }
		verify(title, from: before, frames, animated: true, growing: true)
	}

	private static func verify(_ title: String, from before: Frame, _ frames: [Frame], animated: Bool?, growing: Bool?) {
		guard let last = frames.last else { return check(false, "\(title): нет кадров") }
		let from = before.height, to = last.natural
		var problems: [String] = []
		if !frames.allSatisfy({ $0.window == frame0 }) { problems.append("рамка окна менялась") }
		if !frames.allSatisfy({ abs($0.inputTop - inputTop0) < 0.01 }) {
			problems.append("поле сдвигалось: \(Set(frames.map { Int($0.inputTop) }).sorted()) вместо \(Int(inputTop0))")
		}
		if abs(last.height - last.natural) > 0.5 { problems.append("форма не пришла к размеру содержимого: нарисовано \(last.height), надо \(last.natural)") }
		if !frames.allSatisfy({ $0.inputHeight <= Look.inputMaxHeight + 0.5 }) { problems.append("поле выше 7 строк") }
		let full = frames.filter { $0.light != nil }
		let lit = full.compactMap(\.light).max() ?? 0
		if lit != 0 { problems.append("за формой нарисовано: \(lit) светлых точек") }
		if let settled = full.last?.field, full.contains(where: { $0.field != settled }), steadyField {
			problems.append("ряд поля менялся на \(full.filter { $0.field != settled }.count) из \(full.count) кадров")
		}
		for f in frames where f.hasBar && f.height - f.barHeight >= f.fixedTop + 2 && f.barTop == nil {
			problems.append("панели нет у нижнего края при форме \(f.height)")
			break
		}
		if !frames.allSatisfy({ $0.natural <= $0.cap + 0.5 && Look.margin.top + $0.height + Look.margin.bottom <= $0.window.height + 0.5 }) {
			problems.append("форма выше предела окна")
		}
		let heights = frames.map(\.height)
		let between = Set(heights.filter { $0 > min(from, to) + 0.5 && $0 < max(from, to) - 0.5 }.map { ($0 * 2).rounded() })
		var jump: CGFloat = 0
		var prev = from
		for h in heights {
			jump = max(jump, abs(h - prev))
			prev = h
		}
		let steps = zip([from] + heights.dropLast(), heights).map { $1 - $0 }
		if growing == true {
			if !steps.allSatisfy({ $0 >= -0.5 }) { problems.append("при росте высота шла назад") }
		} else {
			if (heights.min() ?? from) < min(from, to) - 0.5 || (heights.max() ?? from) > max(from, to) + 0.5 {
				problems.append("перелёт: \(Int(heights.min() ?? 0))…\(Int(heights.max() ?? 0)) при \(Int(from))→\(Int(to))")
			}
			if !(steps.allSatisfy { $0 >= -0.5 } || steps.allSatisfy { $0 <= 0.5 }) { problems.append("высота качалась туда-обратно") }
		}
		var how = ""
		let moved = abs(to - from) > 0.5
		switch animated {
		case true?:
			let inside = frames.filter { $0.time - changed < 0.22 }.count
			let need = min(abs(to - from) > 60 ? 3 : 2, max(1, inside - 1))
			if abs(to - from) > 8 && between.count < need { problems.append("скачок: промежуточных высот \(between.count) из \(need)") }
			if moved { how = ", промежуточных высот \(between.count), самый большой шаг \(Int(jump.rounded())) pt" }
		case false?:
			if !between.isEmpty || (moved && abs(heights[0] - to) > 0.5) { problems.append("должно было быть сразу, без анимации") }
		case nil:
			if moved { how = ", промежуточных высот \(between.count)" }
		}
		check(problems.isEmpty, "\(title): \(Int(from))→\(Int(to)) pt, кадров \(frames.count) (целиком \(full.count))\(how)"
			+ (problems.isEmpty ? "" : " — " + problems.joined(separator: "; ")))
	}

	private static var steadyField = true
	private static var changed: TimeInterval = 0

	private static func bitmap(_ rect: NSRect) -> NSBitmapImageRep? {
		guard let v = c.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
		v.cacheDisplay(in: rect, to: rep)
		guard rep.bitsPerSample == 8, !rep.bitmapFormat.contains(.alphaFirst), rep.bitmapData != nil else { return nil }
		return rep
	}

	private static func gray(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Int {
		let p = rep.bitmapData! + y * rep.bytesPerRow + x * rep.samplesPerPixel
		return (Int(p[0]) + Int(p[1]) + Int(p[2])) / 3
	}

	private static func columns(barHeight: CGFloat?) -> (height: CGFloat, barTop: CGFloat?)? {
		guard let v = c.window?.contentView else { return nil }
		let m = Look.margin
		let full = v.bounds.height
		func column(_ x: CGFloat) -> NSBitmapImageRep? { bitmap(NSRect(x: m.left + x, y: 0, width: 1, height: full)) }
		guard let mid = column(Look.width / 2) else { return nil }
		let scale = CGFloat(mid.pixelsHigh) / full
		let top = Int((m.top * scale).rounded())
		var bottom = top
		while bottom < mid.pixelsHigh && (mid.bitmapData! + bottom * mid.bytesPerRow)[3] == 255 { bottom += 1 }
		let height = CGFloat(bottom - top) / scale
		guard let barHeight else { return (height, nil) }
		let cols = [60, 180, 420, 540].compactMap { column(CGFloat($0)) } + [mid]
		let expected = bottom - Int((barHeight * scale).rounded())
		let bg = Int((Look.background.usingColorSpace(.sRGB)?.whiteComponentEstimate ?? 0) * 255)
		func line(_ rep: NSBitmapImageRep, _ y: Int) -> Bool {
			guard y > top, y + 4 < bottom else { return false }
			let under = (max(0, bg - 6)...(bg + 6))
			return ((bg + 10)...80).contains(max(gray(rep, 0, y), gray(rep, 0, y + 1)))
				&& under.contains(gray(rep, 0, y + 3)) && under.contains(gray(rep, 0, y + 4))
		}
		for y in expected - 2...expected + 1 where cols.filter({ line($0, y) }).count >= 2 {
			return (height, CGFloat(y - top) / scale)
		}
		return (height, nil)
	}

	private static func render(height: CGFloat, fixedTop: CGFloat, name: String?) -> (light: Int, field: Int)? {
		guard let v = c.window?.contentView, let rep = bitmap(v.bounds) else { return nil }
		if let dir, let name {
			try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
		}
		let data = rep.bitmapData!
		let scale = CGFloat(rep.pixelsWide) / v.bounds.width
		let spp = rep.samplesPerPixel, bpr = rep.bytesPerRow, w = rep.pixelsWide, h = rep.pixelsHigh
		let m = Look.margin
		let top = Int((m.top * scale).rounded())
		let x0 = Int(((m.left - 1) * scale).rounded(.down)), x1 = Int(((m.left + Look.width + 1) * scale).rounded(.up))
		let y0 = top - Int(scale), y1 = top + Int(((height + 1) * scale).rounded(.up))
		var light = 0
		for yy in 0..<h {
			let inRows = yy >= y0 && yy < y1
			let row = data + yy * bpr
			for xx in 0..<w where !(inRows && xx >= x0 && xx < x1) {
				let p = row + xx * spp
				if p[0] > 100 && p[1] > 100 && p[2] > 100 { light += 1 }
			}
		}
		var hasher = Hasher()
		let fieldRows = top + Int(((fixedTop - 1.5) * scale).rounded(.down))
		let fx0 = Int((m.left + 40) * scale), fx1 = Int((m.left + Look.width - 160) * scale)
		for yy in top..<max(top, fieldRows) {
			let row = data + yy * bpr
			for xx in fx0..<fx1 { hasher.combine(row[xx * spp]) }
		}
		return (light, hasher.finalize())
	}
}

private extension NSColor {
	var whiteComponentEstimate: CGFloat { (redComponent + greenComponent + blueComponent) / 3 }
}
