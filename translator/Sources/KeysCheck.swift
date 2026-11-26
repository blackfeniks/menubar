import AppKit
import Carbon.HIToolbox

@MainActor
enum KeysCheck {
	private static var failed = 0
	private static var passed = 0
	private static var c: PanelController!
	private static var p: KeyPanel!
	private static var s: Session!
	private static var input: InputTextView!
	private static var board: NSPasteboard!
	private static var closed = 0
	private static var copied: [String] = []
	private static var pictures: [String] = []

	private static func check(_ ok: Bool, _ what: String) {
		if ok { passed += 1 } else { failed += 1 }
		print((ok ? "  ✓ " : "  ✗ ") + what)
	}

	static func run() -> Int32 {
		_ = NSApplication.shared
		let systemClipboard = NSPasteboard.general.changeCount
		board = NSPasteboard(name: NSPasteboard.Name("com.ilya.translator.keys-check.\(getpid())"))
		defer { board.releaseGlobally() }
		EditKeys.board = board
		c = PanelController()
		s = c.session
		s.onClose = { closed += 1 }
		s.onCopy = { copied.append($0) }
		p = c.prepare(in: NSRect(x: 0, y: 0, width: 1512, height: 944))
		spin(0.2)
		guard let field = c.inputView else {
			print("✗ no input field")
			return 1
		}
		input = field
		input.onPicture = { pictures.append("\($0.width)×\($0.height)") }
		check(NSApp.mainMenu == nil, "у приложения нет меню: сочетания разносит только окно")

		let layouts = Layout.all()
		print("Раскладки: " + layouts.map(\.name).joined(separator: ", "))
		mapping(layouts)
		for f in Field.allCases { matrix(f, layouts) }
		specials()

		check(NSPasteboard.general.changeCount == systemClipboard, "системный буфер обмена не тронут")
		print(failed == 0 ? "✓ \(passed) checks passed" : "✗ \(failed) failed, \(passed) passed")
		return failed == 0 ? 0 : 1
	}

	private static func mapping(_ layouts: [Layout]) {
		print("Какие клавиши — правка: только те, что печатают a, c, x, v, z (с ⌘), где бы они ни были")
		for l in layouts {
			var wrong: [String] = []
			for code in UInt16(0)..<UInt16(51) {
				for shift in [false, true] {
					guard let e = l.event(code: code, shift: shift) else { continue }
					let meant = l.meant(code: code, shift: shift)
					let want: EditKeys.Action? = switch meant {
					case "a": shift ? nil : .selectAll
					case "c": shift ? nil : .copy
					case "x": shift ? nil : .cut
					case "v": shift ? nil : .paste
					case "z": shift ? .redo : .undo
					default: nil
					}
					let got = EditKeys.action(for: e)
					if got != want { wrong.append("\(shift ? "⇧" : "")⌘ код \(code) «\(e.characters ?? "")»: \(got.map { "\($0)" } ?? "—") вместо \(want.map { "\($0)" } ?? "—")") }
				}
			}
			check(wrong.isEmpty, "\(l.name): \(wrong.isEmpty ? "верно для всех клавиш" : wrong.prefix(4).joined(separator: "; "))")
		}
		for (mods, name) in [(NSEvent.ModifierFlags([.command, .option]), "⌥⌘V"), ([.command, .control], "⌃⌘V"), ([.command, .shift], "⇧⌘V")] {
			let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
			                         characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
			check(EditKeys.action(for: e) == nil, "\(name) — не вставка")
		}
	}

	enum Field: String, CaseIterable {
		case input = "поле ввода", ask = "поле просьбы (AppKit)", own = "«своё слово» (SwiftUI)"
	}

	private static func open(_ f: Field) -> NSTextView? {
		switch f {
		case .input:
			s.showDemo("01-empty")
			spin(0.15)
			p.makeFirstResponder(input)
			return p.firstResponder === input ? input : nil
		case .ask:
			s.showDemo("10-simpler")
			spin(0.1)
			s.startAsk()
			spin(0.3)
			return p.firstResponder as? NSTextView
		case .own:
			s.showDemo("09-alternatives")
			spin(0.3)
			let fields = views(p.contentView!).compactMap { $0 as? NSTextField }.filter(\.isEditable)
			guard fields.count == 1, p.makeFirstResponder(fields[0]) else { return nil }
			return p.firstResponder as? NSTextView
		}
	}

	private struct Outcome {
		var ok = true
		var notes: [String] = []
		mutating func expect(_ cond: Bool, _ note: @autoclosure () -> String) {
			if !cond {
				ok = false
				notes.append(note())
			}
		}
	}

	private static func matrix(_ f: Field, _ layouts: [Layout]) {
		print("\(f.rawValue): ⌘A ⌘C ⌘X ⌘V ⌘V-картинка ⌘Z ⇧⌘Z в каждой раскладке")
		let steps = ["⌘A", "⌘C", "⌘X", "⌘V", "⌘V картинка", "⌘Z", "⇧⌘Z"]
		var results = [String: [(String, Outcome)]]()
		for l in layouts {
			guard let tv = open(f) else {
				check(false, "\(f.rawValue), \(l.name): поле не получило фокус")
				continue
			}
			closed = 0
			copied = []
			pictures = []
			let answer = s.answer, style = s.style
			let inputText = input.string, inputSelection = input.selectedRange()
			func untouched(_ o: inout Outcome) {
				if f != .input {
					o.expect(input.string == inputText && input.selectedRange() == inputSelection,
					         "поле ввода задето: «\(input.string.prefix(20))…» \(input.selectedRange())")
				}
				o.expect(s.answer == answer && s.style == style, "перевод изменился: «\(s.answer.prefix(30))…»")
				o.expect(closed == 0 && copied.isEmpty, "окно закрылось или скопировало перевод")
				switch f {
				case .ask: o.expect(s.askText == tv.string, "просьба в сессии «\(s.askText)» ≠ поле «\(tv.string)»")
				case .own: o.expect(s.ownWord == tv.string, "своё слово в сессии «\(s.ownWord)» ≠ поле «\(tv.string)»")
				case .input: o.expect(s.input == tv.string, "ввод в сессии «\(s.input)» ≠ поле «\(tv.string)»")
				}
			}
			func step(_ name: String, _ key: NSEvent?, _ body: (inout Outcome) -> Void) {
				var o = Outcome()
				if let key {
					deliver(key)
					spin(0.03)
					body(&o)
					untouched(&o)
				} else {
					o.expect(false, "нет такой клавиши")
				}
				results[name, default: []].append((l.name, o))
			}
			tv.insertText("abc", replacementRange: tv.selectedRange())
			spin(0.03)
			step("⌘A", l.key("a")) { o in o.expect(tv.selectedRange() == NSRange(location: 0, length: 3), "выделено \(tv.selectedRange())") }
			tv.setSelectedRange(NSRange(location: 1, length: 2))
			board.clearContents()
			step("⌘C", l.key("c")) { o in
				o.expect(board.string(forType: .string) == "bc" && tv.string == "abc", "буфер «\(board.string(forType: .string) ?? "nil")», поле «\(tv.string)»")
			}
			board.clearContents()
			step("⌘X", l.key("x")) { o in
				o.expect(board.string(forType: .string) == "bc" && tv.string == "a", "буфер «\(board.string(forType: .string) ?? "nil")», поле «\(tv.string)»")
			}
			board.clearContents()
			board.setString("XY", forType: .string)
			step("⌘V", l.key("v")) { o in o.expect(tv.string == "aXY", "поле «\(tv.string)»") }
			putPicture()
			step("⌘V картинка", l.key("v")) { o in
				if f == .input { o.expect(pictures.count == 1 && tv.string == "aXY", "картинок \(pictures.count), поле «\(tv.string)»") }
				else { o.expect(pictures.isEmpty && tv.string == "aXY", "картинка ушла в поле ввода (\(pictures.count)), поле «\(tv.string)»") }
			}
			step("⌘Z", l.key("z")) { o in
				o.expect(tv.string == "a", "после первой ⌘Z «\(tv.string)»")
				deliver(l.key("z")!)
				spin(0.03)
				o.expect(tv.string == "abc", "после второй ⌘Z «\(tv.string)»")
			}
			step("⇧⌘Z", l.key("z", shift: true)) { o in o.expect(tv.string == "a", "поле «\(tv.string)»") }
			if f == .input, let w = l.key("w") {
				deliver(w)
				spin(0.03)
				results["⌘W закрывает окно", default: []].append((l.name, {
					var o = Outcome()
					o.expect(closed == 1, "закрыто \(closed) раз")
					return o
				}()))
			}
		}
		for name in steps + (f == .input ? ["⌘W закрывает окно"] : []) {
			let all = results[name] ?? []
			let bad = all.filter { !$0.1.ok }
			check(!all.isEmpty && bad.isEmpty, "\(name): " + (bad.isEmpty ? all.map(\.0).joined(separator: ", ")
				: bad.map { "\($0.0) — \($0.1.notes.joined(separator: "; "))" }.joined(separator: " | ")))
		}
	}

	private static func specials() {
		print("Особое поля ввода и ловушки")
		let abc = Layout.all().first!, ru = Layout.all().first { $0.name == "Русская" } ?? abc

		s.showDemo("07-text")
		spin(0.15)
		p.makeFirstResponder(input)
		copied = []
		board.clearContents()
		deliver(ru.key("c")!)
		spin(0.03)
		check(copied == [s.answer] && board.string(forType: .string) == nil, "⌘C без выделения в поле ввода — копирует перевод (как Enter), русская раскладка")

		s.showDemo("10-simpler")
		spin(0.15)
		p.makeFirstResponder(input)
		let before = s.answer, text = input.string
		deliver(ru.key("z")!)
		spin(0.03)
		check(s.answer != before && s.style == Style() && input.string == text, "⌘Z в поле ввода — «Назад» к прошлой версии перевода, текст поля цел")

		s.showDemo("01-empty")
		spin(0.15)
		p.makeFirstResponder(input)
		input.insertText("abc", replacementRange: input.selectedRange())
		spin(0.03)
		s.demoInput("Совсем другой текст из истории")
		spin(0.1)
		deliver(abc.key("z")!)
		spin(0.03)
		let afterReplace = input.string
		input.insertText("!", replacementRange: input.selectedRange())
		spin(0.03)
		deliver(abc.key("z")!)
		spin(0.03)
		check(afterReplace == "Совсем другой текст из истории" && input.string == afterReplace,
		      "⌘Z после замены текста сессией (история, картинка, «Наоборот») не вырезает куски нового текста: «\(afterReplace)», потом своя правка отменяется: «\(input.string)»")

		s.showDemo("01-empty")
		spin(0.15)
		p.makeFirstResponder(input)
		pictures = []
		let file = finderPicture()
		deliver(abc.key("v")!)
		spin(0.03)
		check(pictures == ["321×123"] && input.string.isEmpty, "⌘V картинки-файла, скопированной в Finder: сама картинка (\(pictures)), а не имя файла (поле «\(input.string)»)")
		try? FileManager.default.removeItem(at: file)

		pictures = []
		board.clearContents()
		let item = NSPasteboardItem()
		item.setString("text from a page", forType: .string)
		item.setData(pictureData(), forType: .png)
		board.writeObjects([item])
		deliver(abc.key("v")!)
		spin(0.03)
		check(pictures.isEmpty && input.string == "text from a page", "⌘V текста с картинкой (копия из браузера): вставлен текст «\(input.string)»")

		for (what, text) in [("ссылкой", "https://example.com/pic.png"), ("пустым текстом", ""), ("именем файла", "photo.png")] {
			s.showDemo("01-empty")
			spin(0.15)
			p.makeFirstResponder(input)
			pictures = []
			board.clearContents()
			let picture = NSPasteboardItem()
			picture.setString(text, forType: .string)
			picture.setData(pictureData(), forType: .png)
			board.writeObjects([picture])
			deliver(abc.key("v")!)
			spin(0.03)
			check(pictures == ["321×123"] && input.string.isEmpty, "⌘V картинки с \(what): картинка (\(pictures)), а не текст (поле «\(input.string)»)")
		}

		s.showDemo("01-empty")
		spin(0.15)
		p.makeFirstResponder(input)
		pictures = []
		board.clearContents()
		board.setData(pictureData(), forType: .png)
		for chars in ["\u{16}"] {
			let control = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: ProcessInfo.processInfo.systemUptime,
			                               windowNumber: p.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
			deliver(control)
		}
		spin(0.03)
		check(pictures == ["321×123"], "⌃V: то же, что ⌘V (\(pictures))")

		pictures = []
		p.makeFirstResponder(nil)
		deliver(abc.key("v")!)
		spin(0.03)
		check(pictures == ["321×123"], "⌘V без фокуса в поле: картинка всё равно читается (\(pictures))")
		p.makeFirstResponder(input)

		s.showDemo("10-simpler")
		spin(0.1)
		s.startAsk()
		spin(0.3)
		(p.firstResponder as? NSTextView)?.insertText("старая просьба", replacementRange: NSRange(location: 0, length: 0))
		spin(0.03)
		s.escape()
		spin(0.15)
		s.startAsk()
		spin(0.3)
		let again = p.firstResponder as? NSTextView
		deliver(abc.key("z")!)
		spin(0.03)
		check(again != nil && again?.string == "" && s.askText == "", "поле просьбы открыто снова: ⌘Z не возвращает старую просьбу («\(again?.string ?? "nil")»)")
		s.escape()
		spin(0.1)
	}

	private static func pictureData(width: Int = 321, height: Int = 123) -> Data {
		let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
		                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
		NSColor.white.setFill()
		NSRect(x: 0, y: 0, width: width, height: height).fill()
		NSGraphicsContext.restoreGraphicsState()
		return rep.representation(using: .png, properties: [:])!
	}

	private static func putPicture() {
		board.clearContents()
		board.setData(pictureData(), forType: .png)
	}

	private static func finderPicture() -> URL {
		let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("keys-check-\(getpid()).png")
		try? pictureData().write(to: url)
		board.clearContents()
		let item = NSPasteboardItem()
		item.setString(url.absoluteString, forType: .fileURL)
		item.setString(url.lastPathComponent, forType: .string)
		item.setData(pictureData(width: 32, height: 32), forType: .png)
		board.writeObjects([item])
		return url
	}

	private static func deliver(_ e: NSEvent) {
		if e.modifierFlags.contains(.command), p.performKeyEquivalent(with: e) { return }
		p.sendEvent(e)
	}

	@MainActor struct Layout {
		let name: String
		private let data: Data
		private var latinWithCommand = true

		static func all() -> [Layout] {
			var list: [Layout] = []
			for (id, name) in [("com.apple.keylayout.ABC", "ABC"), ("com.apple.keylayout.Russian", "Русская"),
			                   ("com.apple.keylayout.Russian", "Русская без латиницы под ⌘"), ("com.apple.keylayout.French", "AZERTY"),
			                   ("com.apple.keylayout.German", "QWERTZ"), ("com.apple.keylayout.Dvorak", "Dvorak")] {
				guard let data = layoutData(id) else {
					print("  (нет раскладки \(id))")
					continue
				}
				var l = Layout(name: name, data: data)
				l.latinWithCommand = !name.contains("без")
				list.append(l)
			}
			return list
		}

		private static func layoutData(_ id: String) -> Data? {
			let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
			guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource], let source = list.first,
			      let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
			return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
		}

		func type(_ code: UInt16, _ mods: Int) -> String {
			data.withUnsafeBytes { buf in
				var dead: UInt32 = 0
				var chars = [UniChar](repeating: 0, count: 4)
				var n = 0
				let status = UCKeyTranslate(buf.bindMemory(to: UCKeyboardLayout.self).baseAddress!, code, UInt16(kUCKeyActionDown),
				                            UInt32((mods >> 8) & 0xFF), UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
				                            &dead, chars.count, &n, &chars)
				return status == noErr ? String(utf16CodeUnits: chars, count: n) : ""
			}
		}

		func meant(code: UInt16, shift: Bool) -> String {
			if latinWithCommand { return type(code, cmdKey | (shift ? shiftKey : 0)).lowercased() }
			let latin = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
			guard let raw = TISGetInputSourceProperty(latin, kTISPropertyUnicodeKeyLayoutData) else { return "" }
			return Layout(name: "", data: Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data).type(code, 0).lowercased()
		}

		func event(code: UInt16, shift: Bool) -> NSEvent? {
			let plain = type(code, shift ? shiftKey : 0)
			let typed = latinWithCommand ? type(code, cmdKey | (shift ? shiftKey : 0)) : plain
			guard !typed.isEmpty else { return nil }
			return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.command, .shift] : .command,
			                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: p?.windowNumber ?? 0, context: nil,
			                        characters: typed, charactersIgnoringModifiers: plain, isARepeat: false, keyCode: code)
		}

		func key(_ letter: Character, shift: Bool = false) -> NSEvent? {
			for code in UInt16(0)..<UInt16(51) where meant(code: code, shift: false) == String(letter) {
				return event(code: code, shift: shift)
			}
			return nil
		}
	}

	private static func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }

	private static func spin(_ seconds: Double) {
		let end = Date().addingTimeInterval(seconds)
		repeat { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120)) } while Date() < end
	}
}
