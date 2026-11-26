import AppKit
import Carbon.HIToolbox
import SwiftUI

enum SelfTest {
	private static var failed = 0
	private static var passed = 0

	private static func check(_ ok: Bool, _ what: String, file: String = #fileID, line: Int = #line) {
		if ok { passed += 1 } else {
			failed += 1
			print("✗ \(what)  (\(file):\(line))")
		}
	}

	static func run() -> Int32 {
		direction()
		modes()
		cards()
		typos()
		styles()
		bothWays()
		pictures()
		utf8()
		hotkey()
		keyHold()
		cleaning()
		capture()
		clipboard()
		textReplies()
		cardReplies()
		edits()
		palette()
		print(failed == 0 ? "✓ \(passed) checks passed" : "\(failed) failed, \(passed) passed")
		return failed == 0 ? 0 : 1
	}

	private static func palette() {
		let pairs: [(String, NSColor, NSColor)] = [("t1", Look.t1, NSColor(Bar.t1)), ("t2", Look.t2, NSColor(Bar.t2)), ("t3", Look.t3, NSColor(Bar.t3)),
		                                           ("t4", Look.t4, NSColor(Bar.t4)), ("selection", Look.selection, NSColor(Bar.selection))]
		for (name, mine, shared) in pairs {
			guard let a = mine.usingColorSpace(.sRGB), let b = shared.usingColorSpace(.sRGB) else {
				check(false, "palette: \(name) has no sRGB form")
				continue
			}
			let same = [a.redComponent - b.redComponent, a.greenComponent - b.greenComponent, a.blueComponent - b.blueComponent,
			            a.alphaComponent - b.alphaComponent].allSatisfy { abs($0) < 0.004 }
			check(same, "palette: Look.\(name) is Bar.\(name)")
		}
	}

	private static func direction() {
		check(Direction(of: "замок") == .toEnglish, "Russian → English")
		check(Direction(of: "castle") == .toRussian, "English → Russian")
		check(Direction(of: "I want to пожаловаться about the delivery") == .toEnglish, "mixed → English")
		check(Direction(of: "Ёлка") == .toEnglish, "Ё is Cyrillic")
	}

	private static func modes() {
		for w in ["замок", "get over", "Как дела?", "take for granted", "когда делаешь вид, что не слышишь",
		          "человек, который всё откладывает на потом", "when you pretend you can't hear", "someone who always arrives late", "  bank  "] {
			check(Mode(of: w) == .word, "word: \(w)")
		}
		for t in ["Я хочу пожаловаться на доставку", "I want to пожаловаться about the delivery",
		          "Thanks for the quick reply, I really appreciate it!", "две\nстроки", "когда будешь дома, напиши мне, пожалуйста, а то я переживаю и не сплю"] {
			check(Mode(of: t) == .text, "text: \(t)")
		}
	}

	private static func cards() {
		let c = Reply.card("castle | крепость, дворец\n- lock | на двери\nLock | навесной\n\nkeystone", to: nil)
		check(c.count == 3, "card: duplicates merged, bullet and bare term kept (\(c))")
		check(c.first == CardLine(term: "castle", note: "крепость, дворец"), "card: first line")
		check(c.count > 1 && c[1].note == "на двери; навесной", "card: notes of a repeated term joined (\(c))")
		check(c.last == CardLine(term: "keystone", note: ""), "card: line without a note")
	}

	private static func typos() {
		check(WordFix.isTypo("teh", "the") && WordFix.isTypo("tomorow", "tomorrow") && WordFix.isTypo("realy", "really"), "typo: misspellings")
		check(!WordFix.isTypo("say", "tell") && !WordFix.isTypo("in", "on") && !WordFix.isTypo("go", "went"), "typo: other words are not typos")
	}

	private static func styles() {
		var s = Style()
		check(s.instruction(currentWords: 10, to: .toEnglish) == nil && s.isEmpty, "style: empty")
		s.simpler = 2
		s.shorter = 2
		let t = s.instruction(currentWords: 12, to: .toEnglish) ?? ""
		check(t.contains("much simpler") && t.contains("at most 6 words"), "style: levels and word budget (\(t))")
		s = Style(request: "как парень с улиц")
		check(s.instruction(currentWords: 5, to: .toRussian) == "как парень с улиц", "style: free request")
	}

	private static func bothWays() {
		check(!Prompt.system.contains("CHECK") && !Prompt.examples.contains { $0.0.contains("CHECK") }, "prompt: no checking of the user's English")
		for tag in ["[WORD to Russian] when", "[TEXT to Russian] Style: much simpler", "[TEXT to Russian] Style: more polite", "[TEXT to Russian] Style: much shorter",
		            "[TEXT to Russian] Style: more casual", "[EDIT to Russian]", "[ALT] Source: That's"] {
			check(Prompt.examples.contains { $0.0.hasPrefix(tag) }, "prompt: an example of \(tag)")
		}
		for level in 1...Style.maxLevel {
			let ru = Style(simpler: level, casual: level, polite: 0, shorter: 0).instruction(currentWords: 10, to: .toRussian) ?? ""
			check(!ru.contains("English") && !ru.contains("American") && !ru.contains("contractions"), "style to Russian names no English (\(ru))")
		}
		check(Prompt.restyle("Send it.", style: Style(simpler: 2), current: "Отправь.").contains("plain everyday Russian"), "restyle to Russian asks for Russian")
		check(Prompt.restyle("Отправь.", style: Style(simpler: 2), current: "Send it.").contains("everyday English"), "restyle to English asks for English")
	}

	private static func pictures() {
		let board = NSPasteboard(name: NSPasteboard.Name("com.ilya.translator.selftest.\(getpid())"))
		defer { board.releaseGlobally() }
		let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
		                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
		let png = rep.representation(using: .png, properties: [:])!
		func put(_ data: Data = png, as type: NSPasteboard.PasteboardType = .png, text: String? = nil) {
			board.clearContents()
			let item = NSPasteboardItem()
			item.setData(data, forType: type)
			if let text { item.setString(text, forType: .string) }
			board.writeObjects([item])
		}
		func size() -> String { OCR.image(from: board).map { "\($0.width)×\($0.height)" } ?? "нет" }

		put()
		check(size() == "64×48" && OCR.accepts(board), "picture: PNG alone (\(size()))")
		put(rep.tiffRepresentation!, as: .tiff)
		check(size() == "64×48" && OCR.accepts(board), "picture: TIFF alone (\(size()))")
		for extra in ["", "  \n ", "https://example.com/pic.png?x=1", "Снимок экрана 2026-11-09.png"] {
			put(text: extra)
			check(size() == "64×48" && OCR.accepts(board), "picture: what comes along is not text: «\(extra)» (\(size()))")
		}
		for real in ["Text from a page", "первая строка\nвторая", "https://example.com and some words"] {
			put(text: real)
			check(OCR.image(from: board) == nil && !OCR.accepts(board), "picture: real text wins: «\(real)»")
		}
		board.clearContents()
		board.setString("just text", forType: .string)
		check(OCR.image(from: board) == nil && !OCR.accepts(board), "picture: text alone is no picture")

		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("translator-selftest-\(getpid())")
		try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		func putFile(_ url: URL) {
			board.clearContents()
			let item = NSPasteboardItem()
			item.setString(url.absoluteString, forType: .fileURL)
			item.setString(url.lastPathComponent, forType: .string)
			item.setData(png, forType: .png)
			board.writeObjects([item])
		}
		let note = folder.appendingPathComponent("note.txt")
		try? Data("hello".utf8).write(to: note)
		putFile(note)
		check(OCR.image(from: board) == nil && !OCR.accepts(board), "picture: a file that is no picture is not taken by its icon")
		let big = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
		                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
		let file = folder.appendingPathComponent("shot.png")
		try? big.representation(using: .png, properties: [:])?.write(to: file)
		putFile(file)
		check(size() == "100×30" && OCR.accepts(board), "picture: the file's own picture, not its icon (\(size()))")

		let turned = folder.appendingPathComponent("turned.jpg")
		if let d = CGImageDestinationCreateWithURL(turned as CFURL, "public.jpeg" as CFString, 1, nil), let cg = rep.cgImage {
			CGImageDestinationAddImage(d, cg, [kCGImagePropertyOrientation: 6] as CFDictionary)
			CGImageDestinationFinalize(d)
		}
		putFile(turned)
		check(size() == "48×64", "picture: a photo comes upright (\(size()))")

		func line(_ text: String, _ x: CGFloat, top: CGFloat, width: CGFloat) -> OCR.Line {
			OCR.Line(text: text, box: CGRect(x: x, y: top - 0.04, width: width, height: 0.04))
		}
		let wrapped = OCR.joined([line("Курьер опоздал на два часа и", 0.1, top: 0.9, width: 0.8), line("даже не позвонил, чтобы преду-", 0.1, top: 0.85, width: 0.79),
		                          line("предить об этом.", 0.1, top: 0.8, width: 0.3)])
		check(wrapped == "Курьер опоздал на два часа и даже не позвонил, чтобы предупредить об этом.", "ocr: a wrapped paragraph is one line (\(wrapped))")
		let labels = OCR.joined([line("Файл", 0.1, top: 0.9, width: 0.06), line("Правка", 0.1, top: 0.85, width: 0.08), line("Строка во всю ширину экрана", 0.1, top: 0.7, width: 0.8)])
		check(labels == "Файл\nПравка\nСтрока во всю ширину экрана", "ocr: labels stay apart (\(labels))")
		let sentences = OCR.joined([line("Первое закончилось.", 0.1, top: 0.9, width: 0.8), line("Второе на новой строке", 0.1, top: 0.85, width: 0.8)])
		check(sentences == "Первое закончилось.\nВторое на новой строке", "ocr: after a full stop a new line (\(sentences))")
		let far = OCR.joined([line("Абзац без точки в конце", 0.1, top: 0.9, width: 0.8), line("Следующий абзац ниже", 0.1, top: 0.7, width: 0.8)])
		check(far == "Абзац без точки в конце\nСледующий абзац ниже", "ocr: a gap is a new paragraph (\(far))")
		let list = OCR.joined([line("Купить в магазине домой", 0.1, top: 0.9, width: 0.8), line("- молоко и хлеб на завтрак", 0.1, top: 0.85, width: 0.8)])
		check(list.contains("\n- молоко"), "ocr: a list item starts a line (\(list))")
	}

	private static func utf8() {
		check(LocalLLM.completeLength([0xD0, 0xB0]) == 2, "utf8: whole Cyrillic letter")
		check(LocalLLM.completeLength([0x61, 0xD0]) == 1, "utf8: half a letter held back")
		check(LocalLLM.completeLength([0xE2, 0x80]) == 0, "utf8: half a dash held back")
		check(LocalLLM.completeLength([0xE2, 0x80, 0x94]) == 3, "utf8: whole dash")
		check(LocalLLM.completeLength(Array("ok".utf8)) == 2, "utf8: ASCII")
	}

	private static func flagsEvent(_ key: Int, _ flags: UInt64) -> CGEvent {
		let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: true)!
		e.type = .flagsChanged
		e.flags = CGEventFlags(rawValue: flags | 0x100)
		return e
	}

	private static func keyEvent(_ key: Int, down: Bool = true, ours: Bool = false) -> CGEvent {
		let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down)!
		e.flags = .maskCommand
		if ours { e.setIntegerValueField(.eventSourceUserData, value: TapRecognizer.ownEventTag) }
		return e
	}

	private static func scrollEvent(phase: Int64 = 0, momentum: Int64 = 0, delta: Int32 = 4) -> CGEvent {
		let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
		e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
		e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
		return e
	}

	private static func taps(_ steps: [(TimeInterval, CGEventType, CGEvent)], mouseHeld: Bool = false,
	                         keyPresses: [UInt32] = [5]) -> Bool {
		var r = TapRecognizer()
		var probes = 0
		var tapped = false
		for (t, type, e) in steps {
			tapped = r.feed(type, e, now: 100 + t) {
				defer { probes += 1 }
				return TapRecognizer.Probe(mouseHeld: mouseHeld, keyPresses: keyPresses[min(probes, keyPresses.count - 1)])
			}
		}
		return tapped
	}

	private static func hotkey() {
		let cmd: UInt64 = 0x100000, shift: UInt64 = 0x20000
		let rDown = flagsEvent(kVK_RightCommand, cmd | 0x10), rUp = flagsEvent(kVK_RightCommand, 0)
		func tap(_ middle: [(TimeInterval, CGEventType, CGEvent)] = [], up: TimeInterval = 0.12, first: CGEvent? = nil,
		         mouseHeld: Bool = false, keyPresses: [UInt32] = [5]) -> Bool {
			taps([(0, .flagsChanged, first ?? rDown)] + middle + [(up, .flagsChanged, rUp)], mouseHeld: mouseHeld, keyPresses: keyPresses)
		}
		check(tap(), "hotkey: a clean tap")
		check(!tap(up: 0.6), "hotkey: held too long")
		check(!tap([(0.05, .keyDown, keyEvent(kVK_ANSI_C))]), "hotkey: ⌘C is a shortcut")
		check(!tap([(0.05, .leftMouseDown, CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!)]), "hotkey: ⌘-click")
		check(!tap([(0.05, .scrollWheel, scrollEvent())]), "hotkey: ⌘ + mouse wheel")
		check(!tap([(0.05, .scrollWheel, scrollEvent(phase: 1)), (0.07, .scrollWheel, scrollEvent(phase: 2))]), "hotkey: ⌘ + trackpad scroll")
		check(tap([(0.03, .scrollWheel, scrollEvent(momentum: 2)), (0.08, .scrollWheel, scrollEvent(momentum: 3))]), "hotkey: momentum of an earlier scroll does not spoil a tap")
		check(tap([(0.03, .scrollWheel, scrollEvent(phase: 128, delta: 0)), (0.06, .scrollWheel, scrollEvent(phase: 4, delta: 0)), (0.07, .scrollWheel, scrollEvent(phase: 8, delta: 0))]), "hotkey: fingers resting or lifted on the trackpad do not spoil a tap")
		check(!tap(first: flagsEvent(kVK_RightCommand, cmd | 0x10 | shift | 0x02)), "hotkey: Shift held before")
		check(!tap([(0.05, .flagsChanged, flagsEvent(kVK_Shift, cmd | 0x10 | shift | 0x02))]), "hotkey: Shift pressed meanwhile")
		check(!tap(first: flagsEvent(kVK_RightCommand, cmd | 0x10 | 0x08)), "hotkey: left ⌘ held as well")
		check(!tap(mouseHeld: true), "hotkey: during a drag (mouse button held)")
		check(!tap(keyPresses: [5, 6]), "hotkey: a key the tap did not see (secure input) makes it a shortcut")
		check(!tap([(0.05, .tapDisabledByTimeout, rDown)]), "hotkey: tap switched off meanwhile — not trusted")
		check(taps([(0, .flagsChanged, rDown), (0.05, .tapDisabledByTimeout, rDown), (0.1, .flagsChanged, rUp),
		            (0.3, .flagsChanged, rDown), (0.4, .flagsChanged, rUp)]), "hotkey: works again after the tap is back")
		check(tap([(0.04, .keyDown, keyEvent(kVK_ANSI_C, ours: true)), (0.05, .keyUp, keyEvent(kVK_ANSI_C, down: false, ours: true)),
		           (0.06, .flagsChanged, { let e = flagsEvent(kVK_Command, cmd | 0x08); e.setIntegerValueField(.eventSourceUserData, value: TapRecognizer.ownEventTag); return e }())]),
		      "hotkey: our own ⌘C does not spoil the second press")
		check(tap(first: flagsEvent(kVK_RightCommand, cmd)), "hotkey: keyboard without left/right bits")
		check(!taps([(0, .flagsChanged, rUp)]), "hotkey: a release alone")
		check(tap([(0.05, .keyUp, keyEvent(kVK_ANSI_A, down: false))]), "hotkey: a letter let go after ⌘ went down (fast typing)")
		check(taps([(0, .flagsChanged, rDown), (0.3, .flagsChanged, rDown), (0.4, .flagsChanged, rUp)]), "hotkey: a lost release, then a tap")
	}

	private static func keyHold() {
		let hold = KeyHold()
		check(!hold.keep(.keyDown, keyEvent(kVK_ANSI_A), now: 1), "hold: nothing held before start")
		hold.start(now: 10, for: 1)
		check(hold.keep(.keyDown, keyEvent(kVK_ANSI_A), now: 10.1), "hold: a key typed while reading is kept from the app")
		check(!hold.keep(.keyDown, keyEvent(kVK_ANSI_C, ours: true), now: 10.2), "hold: our own ⌘C goes through")
		check(!hold.keep(.flagsChanged, flagsEvent(kVK_Shift, 0x20000), now: 10.2), "hold: modifiers go through")
		check(!hold.keep(.keyUp, keyEvent(kVK_ANSI_B, down: false), now: 10.3), "hold: a release whose press went to the app goes too")
		check(hold.keep(.keyUp, keyEvent(kVK_ANSI_A, down: false), now: 10.3), "hold: the release of a kept key is kept")
		check(!hold.keep(.keyDown, keyEvent(kVK_ANSI_D), now: 11.5), "hold: never longer than the limit")
		let kept = hold.finish()
		check(kept.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [Int64(kVK_ANSI_A), Int64(kVK_ANSI_A)] && kept.first?.type == .keyDown,
		      "hold: kept keys come back in order (\(kept.count))")
		check(!hold.keep(.keyDown, keyEvent(kVK_ANSI_A), now: 10.4) && hold.finish().isEmpty, "hold: nothing after finish")
	}

	private static func cleaning() {
		check(Selection.clean("a\r\nb\rc\u{2028}d\u{85}e") == "a\nb\nc\nd\ne", "clean: line breaks of every kind")
		check(Selection.clean("транс\u{AD}ляция zero\u{200B}width\u{FEFF}\u{0}") == "трансляция zerowidth", "clean: invisible characters")
		check(Selection.clean("$ ls   \nfile.txt\t\n\n") == "$ ls\nfile.txt", "clean: terminal padding")
		check(Selection.clean("  \n\t \u{200B} ") == nil, "clean: only whitespace is no text")
		check(Selection.clean("👩‍💻 ok") == "👩‍💻 ok", "clean: emoji joiners stay")
		check(Selection.clean("  две\n\nстроки ") == "две\n\nстроки", "clean: lines stay")
		let long = Selection.clean(String(repeating: "Это предложение. ", count: 2000)) ?? ""
		check(long.count <= Selection.maxLength && long.count > Selection.maxLength * 3 / 4 && long.hasSuffix("предложение."),
		      "clean: very long text cut at a sentence end (\(long.count))")
		let word = Selection.clean(String(repeating: "x", count: Selection.maxLength + 10)) ?? ""
		check(word.count == Selection.maxLength, "clean: a cut without any break (\(word.count))")
		let t0 = Date()
		let huge = Selection.clean(String(repeating: "Строка длинного лога номер сколько-то.\n", count: 250_000)) ?? ""
		let took = Date().timeIntervalSince(t0)
		check(huge.count <= Selection.maxLength && huge.hasSuffix("сколько-то.") && took < 0.5,
		      String(format: "clean: 10 MB selection cut at a line end in %.0f ms", took * 1000))
		let emoji = Selection.clean(String(repeating: "👍🏽 ", count: Selection.maxLength)) ?? ""
		check(!emoji.isEmpty && emoji.count <= Selection.maxLength && emoji.hasSuffix("👍🏽"), "clean: cut never splits a character (\(emoji.count))")
	}

	private static func capture() {
		var presses = 0
		let pb = NSPasteboard(name: NSPasteboard.Name("com.ilya.translator.selftest.capture.\(getpid())"))
		defer { pb.releaseGlobally() }
		pb.clearContents()
		pb.setString("буфер", forType: .string)
		let copier = ClipboardCopy(pasteboard: pb, press: {
			presses += 1
			pb.clearContents()
			pb.setString("  скопировано \r\n", forType: .string)
		}, wait: 0.2, watchLate: 0.1)
		func run(_ answers: [AXAnswer], tree: Bool = false, copy: ClipboardCopy? = copier, cancelled: Bool = false) -> String? {
			presses = 0
			var i = 0
			let c = SelectionCapture(read: { defer { i += 1 }; return answers[min(i, answers.count - 1)] },
			                         enableTree: { tree }, copy: copy, isCancelled: { cancelled }, treeWait: 0.2)
			return c.run()
		}
		check(run([.text("  castle\r\n")]) == "castle" && presses == 0, "capture: Accessibility first, no ⌘C")
		check(run([.nothing]) == nil && presses == 0, "capture: nothing selected in a field — no ⌘C (an editor would copy the line)")
		check(run([.secure]) == nil && presses == 0, "capture: password field — empty window, no ⌘C")
		check(run([.busy]) == nil && presses == 0, "capture: hung app — no ⌘C that would land late")
		check(run([.text(" \n ")]) == nil && presses == 0, "capture: only spaces selected — empty window")
		check(run([.unknown(role: nil), .unknown(role: nil), .text("из дерева")], tree: true) == "из дерева" && presses == 0,
		      "capture: Electron — tree turned on, second look finds it")
		check(run([.unknown(role: nil)], tree: false) == "скопировано" && presses == 1, "capture: no answer — ⌘C, text from the clipboard")
		check(pb.string(forType: .string) == "буфер", "capture: clipboard back after the ⌘C")
		check(run([.unknown(role: "AXWebArea")], tree: true) == "скопировано" && presses == 1, "capture: tree did not help — ⌘C after the wait")
		check(run([.unknown(role: kAXOutlineRole)]) == nil && presses == 0, "capture: Finder-like list — no ⌘C")
		check(run([.unknown(role: nil)], copy: nil) == nil, "capture: secure input — no ⌘C at all")
		check(run([.unknown(role: nil)], cancelled: true) == nil && presses == 0, "capture: second press cancels before the ⌘C")
	}

	private static func contents(_ pb: NSPasteboard) -> [[String: Data]] {
		(pb.pasteboardItems ?? []).map { item in
			Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t.rawValue, $0) } })
		}
	}

	private static func clipboard() {
		let pb = NSPasteboard(name: NSPasteboard.Name("com.ilya.translator.selftest.clipboard.\(getpid())"))
		defer { pb.releaseGlobally() }
		func fill() {
			pb.clearContents()
			let a = NSPasteboardItem()
			a.setString("старое", forType: .string)
			a.setData(Data("{\\rtf1 старое}".utf8), forType: .rtf)
			a.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("com.example.private"))
			let b = NSPasteboardItem()
			b.setString("второй", forType: .string)
			pb.writeObjects([a, b])
		}
		func later(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
			DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work)
		}
		fill()
		let original = contents(pb)
		check(original.count == 2 && original[0].count >= 3, "clipboard: test contents (\(original.map(\.count)))")

		var copy = ClipboardCopy(pasteboard: pb, press: { pb.clearContents(); pb.setString("выделено", forType: .string) },
		                         wait: 0.2, watchLate: 0.4)
		check(copy.run() == "выделено" && contents(pb) == original, "clipboard: copied text read, every item and type put back")

		copy.press = { later(0.05) { pb.clearContents(); later(0.03) { pb.setString("потом", forType: .string) } } }
		check(copy.run() == "потом" && contents(pb) == original, "clipboard: an app that clears first and writes a moment later")

		let count = pb.changeCount
		copy.press = {}
		let t0 = Date()
		let none = copy.run()
		let waited = Date().timeIntervalSince(t0)
		check(none == nil && waited < 0.35 && pb.changeCount == count, String(format: "clipboard: nothing copied — gives up in %.0f ms, clipboard untouched", waited * 1000))

		copy.press = { later(0.3) { pb.clearContents(); pb.setString("опоздал", forType: .string) } }
		check(copy.run() == nil, "clipboard: a copy after the wait is not used")
		Thread.sleep(forTimeInterval: 0.5)
		check(contents(pb) == original, "clipboard: …and is undone when it lands")

		copy.press = {}
		_ = copy.run()
		ClipboardWatch.stop()
		pb.clearContents()
		pb.setString("перевод", forType: .string)
		Thread.sleep(forTimeInterval: 0.3)
		check(pb.string(forType: .string) == "перевод", "clipboard: the window's own copy is never undone")
		fill()

		copy.press = { pb.clearContents(); pb.writeObjects([NSURL(fileURLWithPath: "/tmp/file.txt")]) }
		check(copy.run() == nil && contents(pb) == original, "clipboard: files (Finder) are not text, clipboard put back")
		ClipboardWatch.stop()

		copy.press = { pb.clearContents() }
		check(copy.run() == nil && contents(pb) == original, "clipboard: emptied, nothing written in time, clipboard put back")
		pb.clearContents()
		pb.setString("поздно", forType: .string)
		Thread.sleep(forTimeInterval: 0.3)
		check(contents(pb) == original, "clipboard: …and the late copy is undone when it lands")
		ClipboardWatch.stop()

		pb.clearContents()
		copy.press = { pb.clearContents(); pb.setString("из пустого", forType: .string) }
		check(copy.run() == "из пустого" && (pb.pasteboardItems ?? []).isEmpty, "clipboard: an empty clipboard stays empty")

		fill()
		var pressed = false
		copy.press = { pressed = true }
		copy.saveBudget = 0
		check(copy.run() == nil && !pressed && contents(pb) == original, "clipboard: no ⌘C when the clipboard cannot be saved in time")
		copy.saveBudget = 0.15
		check(copy.run(shouldPress: { false }) == nil && !pressed, "clipboard: no ⌘C after a cancel")
	}

	private static func textReplies() {
		let ru = "Я хочу пожаловаться на доставку, курьер опоздал на два часа."
		func en(_ raw: String, _ refs: [String] = [ru]) -> String { Reply.text(raw, like: refs) }
		check(en("I want to complain about the delivery; the courier was two hours late.") == "I want to complain about the delivery; the courier was two hours late.", "text: a plain answer stays")
		check(en("I want to complain about the delivery — the courier was two hours late.\n\nNote: В английском языке глагол \"complain\" требует предлога \"about\".") == "I want to complain about the delivery — the courier was two hours late.",
		      "text: a note after the text is cut off")
		check(en("Here's a more polite version:\nCould you please send me the report by Friday?") == "Could you please send me the report by Friday?", "text: lead-in dropped")
		check(en("\"I want to complain.\"") == "I want to complain.", "text: wrapping quotes dropped")
		check(en("\"I'll come tomorrow.\"", ["«Я приду завтра.»"]) == "\"I'll come tomorrow.\"", "text: quotes the user wrapped the text in stay")
		check(Reply.text("«Ладно», — сказал он.", like: ["\"Okay,\" he said."]) == "«Ладно», — сказал он.", "text: quotes the text has stay")
		check(en("[TEXT to English] I want to complain.") == "I want to complain.", "text: echoed tag dropped")
		check(en("Style: simpler\nI want to complain.") == "I want to complain.", "text: echoed request line dropped")
		check(en("Source: Reuters, March 3.", ["Источник: Reuters, 3 марта."]) == "Source: Reuters, March 3.", "text: a label the text has itself stays")
		check(Reply.text("Перевод: привет, как дела?", like: ["Hi, how are you?"]) == "привет, как дела?", "text: a label the text lacks goes")
		check(en("I miss you (literally: I'm bored without you)", ["Я по тебе скучаю"]) == "I miss you", "text: a note in brackets dropped")
		check(en("That's an ⟦excellent⟧ idea.", ["That's a great idea."]) == "That's an excellent idea.", "text: edit brackets dropped")
		check(en("Hey! I'll be late today.\nGo ahead without me.", ["Привет! Я опоздаю.\nНачинайте без меня."]) == "Hey! I'll be late today.\nGo ahead without me.", "text: line breaks of the source stay")
		check(en("Windows 11 was ported to the OnePlus «раскладушка».") == "Windows 11 was ported to the OnePlus «раскладушка».", "text: a Russian word left in English stays")
		check(en("Hi!\nHow are you?", ["Привет! Как дела у тебя сегодня?"]) == "Hi!\nHow are you?", "text: more lines than the source stay")
		check(en("1. I want to complain.\n2. I'd like to complain.") == "1. I want to complain.\n2. I'd like to complain.", "text: versions asked for stay")
		check(Reply.text("iPhone 15 Pro Max", like: ["iPhone 15 Pro Max"]) == "iPhone 15 Pro Max", "text: nothing to translate is fine")
		check(en("Thanks for your help! | standard\nThanks a lot for your help! | сильнее", [ru, "Thanks for your help!"])
		      == "Thanks for your help!\nThanks a lot for your help!", "text: card notes on versions go (real answer, 17.11)")
		check(en("Use a | b here.", ["Используй a | b тут."]) == "Use a | b here.", "text: a bar the source has stays")
		check(Reply.textPreview("Here's", like: [ru]) == nil, "preview: a possible lead-in is held back")
		check(Reply.textPreview("I want to complain about the delivery.\n\nNo", like: [ru]) == "I want to complain about the delivery.", "preview: lines past the text are not shown")
		check(Reply.textPreview("\"I want to", like: [ru]) == "I want to", "preview: an opening wrapper quote is not shown")
		check(Reply.textPreview("Here's the translation:\nI want", like: [ru]) == "I want", "preview: a finished lead-in line goes")
	}

	private static func cardReplies() {
		let c = Reply.card("Here are some options:\n1. castle | крепость\n2. **lock** | на двери\n3. padlock | padlock, small", to: .toEnglish)
		check(c.map(\.term) == ["castle", "lock", "padlock"] && c.last?.note == "", "card: lead-in, numbering and an English note dropped (\(c))")
		check(Reply.card("castle | крепость\nlo", to: .toEnglish, partial: true).map(\.term) == ["castle"], "card: a line in progress waits for its bar")
		let alt = Reply.card("amazing | то же\ngreat | проще\nbrilliant | сильнее", to: .toEnglish, excluding: "Amazing").map(\.term)
		check(alt == ["great", "brilliant"], "alt: the current wording is left out (\(alt))")
		check(Reply.card("amazing | то же", to: .toEnglish, excluding: "amazing").isEmpty, "alt: none left is fine")
		check(Reply.card("сделать | do", to: .toRussian).first == CardLine(term: "сделать", note: ""), "card: Russian term, English note dropped")
		check(Reply.card("API | программный интерфейс", to: .toRussian).map(\.term) == ["API"], "card: a term in the source's language stays when it is all there is")
		check(Reply.card("This word means a building.", to: .toEnglish).map(\.term) == ["This word means a building."], "card: prose alone is shown as it is")
	}

	private static func edits() {
		let text = "I like your idea, and your sister likes it too."
		let ns = text as NSString
		let second = NSRange(location: ns.range(of: "your sister").location, length: 4)
		let q = Query<String>.edit(source: "Мне нравится твоя идея, и твоей сестре тоже.", text: text, range: second, with: "his")
		check(q.request.contains("⟦your⟧ → his") && q.request.contains("idea, and ⟦your⟧ sister") && !q.request.contains("like ⟦your⟧"), "edit: the very occurrence is marked")
		func zone(_ t: String, _ word: String) -> String {
			let n = t as NSString
			return n.substring(with: Reply.zone(of: t, around: n.range(of: word)))
		}
		check(zone("These important documents need to be signed.", "documents") == "These important documents", "edit zone: determiner and adjective before")
		check(zone("There are many cars on the street.", "cars") == "There are many cars", "edit zone: there are many")
		check(zone("That's a great idea.", "great") == "That's a great", "edit zone: article")
		check(zone("I like old cars.", "cars") == "cars", "edit zone: a lone adjective stays out")
		check(zone("Yes, documents are ready.", "documents") == "documents", "edit zone: not across punctuation")
		check(zone("У нас большая проблема с доставкой.", "проблема") == "большая проблема", "edit zone: a Russian adjective agrees (\(zone("У нас большая проблема с доставкой.", "проблема")))")
		check(zone("Эти важные документы нужно подписать.", "документы") == "Эти важные документы", "edit zone: Russian demonstrative and adjective")
		check(zone("Я подписал твои документы вчера.", "документы") == "твои документы", "edit zone: Russian possessive")
		check(zone("Вчера я подписал документы.", "документы") == "документы", "edit zone: a Russian verb stays out")
		let d = "These documents need to be signed by Friday."
		let dq = Query<String>.edit(source: "Эти документы нужно подписать до пятницы.", text: d, range: (d as NSString).range(of: "documents"), with: "contract")
		check(dq.request.contains("⟦These documents⟧ → These contract\n") && dq.request.contains("Text: ⟦These documents⟧ need"), "edit: the place and its word-for-word new wording")
		check(Prompt.alternatives(source: "…", text: text, range: second).contains("and ⟦your⟧ sister"), "alt: the very occurrence is marked")
		let marks = Reply.changedWords(old: "That's a great idea.", new: "That's an excellent idea.")
		check(marks.map { ("That's an excellent idea." as NSString).substring(with: $0) } == ["an excellent"], "edit: changed words marked together (\(marks))")
		let two = "The courier was late. I want to complain about it."
		check(Reply.lead(of: two, before: (two as NSString).range(of: "complain").location) == "The courier was late.", "edit: earlier sentences are kept")
		check(Reply.lead(of: two, before: 4) == "", "edit: the first sentence is free")
		check(Reply.same("Hello, world!", "hello world") && !Reply.same("Hello", "Hi"), "same: case and punctuation ignored")
	}
}
