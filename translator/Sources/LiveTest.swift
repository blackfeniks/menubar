import AppKit
import Carbon.HIToolbox

@MainActor
enum LiveTest {
	static var dir = ""
	static var scenarios: [String] = []
	private static var lines: [String] = []
	private static weak var app: AppDelegate?

	static func note(_ s: String) {
		lines.append(s)
		try? lines.joined(separator: "\n").write(toFile: dir + "/live.txt", atomically: true, encoding: .utf8)
	}

	static func start(_ delegate: AppDelegate) {
		app = delegate
		try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		note("live test \(Date()) ax=\(AXIsProcessTrusted()) scenarios=\(scenarios)")
		Task { @MainActor in
			try? await Task.sleep(nanoseconds: 800_000_000)
			for s in scenarios {
				note("== \(s)")
				await run(s)
			}
			note("done")
			NSApp.terminate(nil)
		}
	}

	private static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

	private static func wait(_ seconds: Double, _ ok: () -> Bool) async -> Bool {
		let end = Date().addingTimeInterval(seconds)
		while Date() < end {
			if ok() { return true }
			await sleep(0.02)
		}
		return ok()
	}

	private static var panel: PanelController? { app?.panelForTests }

	private static func run(_ name: String) async {
		switch name {
		case "selection": await selection(word: "курьер", sentence: false)
		case "selection-sentence": await selection(word: "", sentence: true)
		case "copy-direct":
			guard let (te, area) = await openTextEdit() else { return }
			let ns = probeText as NSString
			_ = select(area, ns.range(of: "опять опоздает"))
			await sleep(0.3)
			let pb = NSPasteboard.general
			let saved = PasteboardSnapshot(pb, budget: 2)
			let before = pb.changeCount
			Keystroke.copy()
			let ok = await wait(1.5) { pb.changeCount != before }
			note((ok ? "✓" : "✗") + " direct ⌘C: changeCount \(before) → \(pb.changeCount), text «\(pb.string(forType: .string) ?? "nil")», front \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
			saved?.restore(to: pb)
			te.terminate()
			await sleep(0.5)
		case "copy-variants":
			guard let (te, area) = await openTextEdit() else { return }
			let ns = probeText as NSString
			_ = select(area, ns.range(of: "опять опоздает"))
			await sleep(0.3)
			let pb = NSPasteboard.general
			let saved = PasteboardSnapshot(pb, budget: 2)
			note("post access: \(CGPreflightPostEventAccess())")
			for (name, state, tap, separateCmd, gap) in [("hid+combined+cmd", CGEventSourceStateID.combinedSessionState, CGEventTapLocation.cghidEventTap, true, 0.02),
			                                          ("session+combined+cmd", .combinedSessionState, .cgSessionEventTap, true, 0.02),
			                                          ("hid+hidstate+cmd", .hidSystemState, .cghidEventTap, true, 0.02),
			                                          ("session+private+nocmd", .privateState, .cgSessionEventTap, false, 0.0),
			                                          ("hid+private+cmd+gap", .privateState, .cghidEventTap, true, 0.02)] {
				_ = select(area, ns.range(of: "опять опоздает"))
				pb.clearContents()
				pb.setString("marker", forType: .string)
				let before = pb.changeCount
				let src = CGEventSource(stateID: state)
				let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08 | 0x100)
				if separateCmd, let c = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: true) {
					c.type = .flagsChanged
					c.flags = flags
					c.post(tap: tap)
					await sleep(gap)
				}
				if let d = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true) { d.flags = flags; d.post(tap: tap) }
				await sleep(gap)
				if let u = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false) { u.flags = flags; u.post(tap: tap) }
				await sleep(gap)
				if separateCmd, let c = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: false) {
					c.type = .flagsChanged
					c.flags = CGEventFlags(rawValue: 0x100)
					c.post(tap: tap)
				}
				let ok = await wait(0.8) { pb.changeCount != before }
				note((ok ? "✓ " : "✗ ") + name + ": «\(pb.string(forType: .string) ?? "nil")»")
			}
			saved?.restore(to: pb)
			te.terminate()
			await sleep(0.5)
		case "copy-exact":
			guard let (te, area) = await openTextEdit() else { return }
			let ns = probeText as NSString
			let pb = NSPasteboard.general
			let saved = PasteboardSnapshot(pb, budget: 2)
			for (name, gap, unicode, tag, noncoalesced) in [("exact", 0.0, true, true, false), ("exact+gap", 0.012, true, true, false),
			                                                ("no-unicode", 0.0, false, true, false), ("no-tag", 0.0, true, false, false),
			                                                ("noncoalesced", 0.0, true, true, true)] {
				_ = select(area, ns.range(of: "опять опоздает"))
				await sleep(0.2)
				pb.clearContents()
				pb.setString("marker", forType: .string)
				let before = pb.changeCount
				let source = CGEventSource(stateID: .privateState)
				source?.localEventsSuppressionInterval = 0
				let extra: UInt64 = noncoalesced ? 0x100 : 0
				let command = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08 | extra)
				func key(_ code: Int, down: Bool, _ flags: CGEventFlags, modifier: Bool = false) -> CGEvent? {
					guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { return nil }
					if modifier { e.type = .flagsChanged }
					e.flags = flags
					if !modifier && unicode { e.keyboardSetUnicodeString(stringLength: 1, unicodeString: [UniChar(0x63)]) }
					if tag { e.setIntegerValueField(.eventSourceUserData, value: TapRecognizer.ownEventTag) }
					return e
				}
				let events = [key(55, down: true, command, modifier: true), key(8, down: true, command),
				              key(8, down: false, command), key(55, down: false, CGEventFlags(rawValue: extra), modifier: true)]
				for e in events {
					e?.post(tap: .cgSessionEventTap)
					if gap > 0 { usleep(useconds_t(gap * 1e6)) }
				}
				let ok = await wait(0.8) { pb.changeCount != before }
				note((ok ? "✓ " : "✗ ") + name + ": «\(pb.string(forType: .string) ?? "nil")»")
			}
			saved?.restore(to: pb)
			te.terminate()
			await sleep(0.5)
		case "paste-ask": await pasteAsk()
		case "draft": await draft()
		case "film": await film()
		case "wheel-caret": await wheelAndCaret()
		case "fold": await fold()
		case "relaunch":
			guard let panel else { return }
			panel.show(selection: "замок")
			_ = await wait(20) { panel.session.failure != nil }
			note("failure: \(panel.session.failure ?? "-"), Enter: \(panel.session.enterLabel ?? "-")")
			panel.session.enter()
			_ = await wait(20) { panel.session.enterLabel == "Restart the app" }
			note("after the repair: \(panel.session.failure ?? "-"), Enter: \(panel.session.enterLabel ?? "-")")
			note("pressing Enter: a fresh copy should start with --reopen and this one quit")
			panel.session.enter()
			await sleep(3)
		case "enter-frames": await enterFrames(text: "замок")
		case "enter-frames-text": await enterFrames(text: "Хочу пожаловаться на доставку, курьер опоздал на два часа.")
		case "selection-clipboard":
			let pb = NSPasteboard.general
			let saved = PasteboardSnapshot(pb, budget: 2)
			pb.clearContents()
			pb.setString("ORIGINAL-CLIP-42", forType: .string)
			let count = pb.changeCount
			await selection(word: "опять опоздает", sentence: false)
			await sleep(1.8)
			let kept = pb.string(forType: .string) == "ORIGINAL-CLIP-42"
			note((kept ? "✓" : "✗") + " clipboard after: «\(pb.string(forType: .string) ?? "nil")» (changeCount \(count) → \(pb.changeCount))")
			saved?.restore(to: pb)
		default: note("? unknown scenario")
		}
	}

	private static func wheelAndCaret() async {
		guard let panel else { return }
		panel.show(selection: nil)
		guard await wait(2, { panel.inputView != nil && panel.isVisible }), let field = panel.inputView, let window = panel.window else { return }
		field.selectAll(nil)
		field.delete(nil)
		await sleep(0.3)
		if let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
		                               windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
		                               isARepeat: false, keyCode: 125) { window.sendEvent(down) }
		_ = await wait(2) { panel.session.overlay == .history }
		let before = panel.session.historySelected ?? -1
		let saved = NSEvent.mouseLocation
		let screenH = NSScreen.screens.first?.frame.height ?? 0
		let center = CGPoint(x: window.frame.midX, y: screenH - (window.frame.maxY - Look.margin.top - 120))
		CGWarpMouseCursorPosition(center)
		await sleep(0.2)
		for _ in 0..<3 {
			CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
			await sleep(0.25)
		}
		let after = panel.session.historySelected ?? -1
		note((after == before + 3 ? "✓" : "✗") + " mouse wheel: history row \(before) → \(after) (rows: \(panel.session.historyRows.count))")
		CGWarpMouseCursorPosition(CGPoint(x: saved.x, y: screenH - saved.y))
		panel.session.escape()
		await sleep(0.2)
		field.insertText("Это достаточно длинная строка, чтобы перенестись на вторую строку поля ввода", replacementRange: field.selectedRange())
		field.setSelectedRange(NSRange(location: 5, length: 0))
		await sleep(0.8)
		let rect = field.firstRect(forCharacterRange: NSRange(location: 5, length: 0), actualRange: nil)
		let f = Look.inputFont
		let indicator = field.subviews.first { String(describing: type(of: $0)).contains("Insertion") }
		note(String(format: "caret: rect height %.1f, indicator %@, font ascender−descender %.1f", rect.height,
		            indicator.map { String(format: "%.1f", $0.frame.height) } ?? "none", f.ascender - f.descender))
		panel.hide()
	}

	private static func fold() async {
		guard let panel else { return }
		let long = "Windows 11 портировали на «раскладушку» OnePlus\n\nРазработчик рассказал, что самостоятельно написал драйверы для железа и сенсорного экрана, а также создал кастомный UEFI, но в итоге система запустилась нативно и более-менее стабильно функционирует."
		History.shared.add(HistoryItem(input: long, kind: .text, result: "Windows 11 has been ported to the OnePlus flip phone.\n\nThe developer shared that they wrote the drivers from scratch."))
		let saved = NSEvent.mouseLocation
		let screenH = NSScreen.screens.first?.frame.height ?? 0
		func click(at p: NSPoint) async {
			let g = CGPoint(x: p.x, y: screenH - p.y)
			CGWarpMouseCursorPosition(g)
			await sleep(0.15)
			CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: g, mouseButton: .left)?.post(tap: .cghidEventTap)
			await sleep(0.15)
			CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: g, mouseButton: .left)?.post(tap: .cghidEventTap)
			await sleep(0.05)
			CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: g, mouseButton: .left)?.post(tap: .cghidEventTap)
			await sleep(0.4)
		}
		panel.show(selection: long)
		guard await wait(3, { panel.session.kind == .text && panel.inputView?.folded == true }), let field = panel.inputView,
		      let window = panel.window, let lm = field.layoutManager, let tc = field.textContainer else {
			return note("✗ fold: the field did not fold (kind \(panel.session.kind), folded \(panel.inputView?.folded == true))")
		}
		await sleep(0.5)
		let folded = field.enclosingScrollView?.frame.height ?? 0
		note("✓ folded: field \(Int(folded)) pt, one line \(Int(InputTextView.oneLine)) pt")
		await shoot(0.05)
		let word = (field.string as NSString).range(of: "раскладушку")
		let rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: word, actualCharacterRange: nil), in: tc)
		await click(at: window.convertPoint(toScreen: field.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)))
		let caret = field.selectedRange().location
		let opened = await wait(1) { panel.session.inputOpened && field.folded == false }
		note((opened && NSLocationInRange(caret, NSRange(location: word.location, length: word.length + 1)) ? "✓" : "✗")
			+ " click on «раскладушку»: opened \(opened), field \(Int(field.enclosingScrollView?.frame.height ?? 0)) pt, caret \(caret) (word at \(word.location))")
		await shoot(0.4)
		let c = Look.close
		let formTop = window.frame.maxY - Look.margin.top, formLeft = window.frame.minX + Look.margin.left
		let bubble = NSPoint(x: formLeft + c.midX, y: formTop - c.midY)
		CGWarpMouseCursorPosition(CGPoint(x: bubble.x, y: screenH - bubble.y))
		CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: bubble.x, y: screenH - bubble.y), mouseButton: .left)?
			.post(tap: .cghidEventTap)
		let shown = await wait(1) { panel.ui.pointerOverForm }
		note((shown ? "✓" : "✗") + " the bubble shows with the pointer on it")
		await shoot(0.3)
		await click(at: bubble)
		let closed = await wait(1) { !panel.isVisible }
		note((closed ? "✓" : "✗") + " a click on the bubble closed the window")
		CGWarpMouseCursorPosition(CGPoint(x: saved.x, y: screenH - saved.y))
		panel.hide()
	}

	private static var frame = 0

	private static func shoot(_ seconds: Double) async {
		guard let host = panel?.window?.contentView else { return }
		let end = Date().addingTimeInterval(seconds)
		while Date() < end {
			let t = Date()
			if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
				host.cacheDisplay(in: host.bounds, to: rep)
				try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + String(format: "/f%05d.png", frame)))
				frame += 1
			}
			await sleep(max(0.001, 1.0 / 30 - Date().timeIntervalSince(t)))
		}
	}

	private static func key(_ code: UInt16, _ chars: String = "") {
		guard let window = panel?.window,
		      let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
		                               windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
		                               isARepeat: false, keyCode: code) else { return }
		window.sendEvent(e)
	}

	private static func typeText(_ text: String) async {
		guard let field = panel?.inputView else { return }
		for ch in text {
			field.insertText(String(ch), replacementRange: field.selectedRange())
			await shoot(0.06)
		}
	}

	private static func film() async {
		guard let panel else { return }
		panel.show(selection: nil)
		_ = await wait(2) { panel.inputView != nil && panel.isVisible }
		_ = await wait(15) { Engine.shared.isLoaded }
		await shoot(0.6)
		await typeText("замок")
		await shoot(0.5)
		key(36, "\r")
		_ = await wait(15) { !panel.session.streaming && panel.session.lines.count > 2 }
		await shoot(1.2)
		key(125); await shoot(0.7)
		key(125); await shoot(0.9)
		key(126); await shoot(0.8)
		panel.inputView?.selectAll(nil)
		await typeText("Хочу пожаловаться на доставку, курьер опоздал на два часа")
		await shoot(0.6)
		key(36, "\r")
		_ = await wait(20) { !panel.session.streaming && panel.session.kind == .text && panel.session.answeredInput == panel.session.input }
		await shoot(1.6)
		let answer = panel.session.answer as NSString
		let r = answer.range(of: "complain")
		if r.location != NSNotFound {
			panel.session.pick(r)
			await shoot(2.0)
			key(125); await shoot(0.8)
			key(36, "\r")
			_ = await wait(15) { !panel.session.streaming && !panel.session.restyling }
			await shoot(1.8)
		}
		panel.inputView?.selectAll(nil)
		panel.inputView?.delete(nil)
		await shoot(0.4)
		key(125)
		await shoot(1.0)
		for _ in 0..<4 { key(125); await shoot(0.45) }
		key(126); await shoot(0.8)
		note("frames: \(frame)")
		panel.hide()
	}

	private static func draft() async {
		guard let panel else { return }
		panel.show(selection: nil)
		guard await wait(2, { panel.inputView != nil && panel.isVisible }), let field = panel.inputView else {
			note("✗ window did not open")
			return
		}
		let text = "Черновик, который нельзя терять"
		for ch in text {
			field.insertText(String(ch), replacementRange: field.selectedRange())
			await sleep(0.02)
		}
		await sleep(0.5)
		let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").isEmpty
		guard let (te, _) = await openTextEdit() else { return }
		await sleep(1)
		note((panel.isVisible && !panel.hasKeyboard ? "✓" : "✗") + " the window stayed on screen when TextEdit came to the front")
		await tapRightCommand()
		let fresh = await wait(3) { panel.hasKeyboard && panel.session.input.isEmpty }
		note((fresh ? "✓" : "✗") + " right ⌘: a new empty field with the keyboard, «\(panel.session.input)»")
		panel.session.back()
		note((panel.session.input == text ? "✓" : "✗") + " ⌘Z: the draft came back, «\(panel.session.input)»")
		panel.hide()
		await sleep(0.3)
		if !wasRunning { te.terminate() }
		await sleep(0.5)
	}

	private static func pressCommand(_ key: CGKeyCode) async {
		let src = CGEventSource(stateID: .combinedSessionState)
		let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08 | 0x100)
		if let c = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: true) { c.type = .flagsChanged; c.flags = flags; c.post(tap: .cghidEventTap) }
		await sleep(0.03)
		if let d = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true) { d.flags = flags; d.post(tap: .cghidEventTap) }
		await sleep(0.03)
		if let u = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) { u.flags = flags; u.post(tap: .cghidEventTap) }
		await sleep(0.03)
		if let c = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: false) { c.type = .flagsChanged; c.flags = CGEventFlags(rawValue: 0x100); c.post(tap: .cghidEventTap) }
	}

	private static func pasteAsk() async {
		guard let panel else { return }
		panel.show(selection: nil)
		guard await wait(2, { panel.inputView != nil && panel.isVisible }), let field = panel.inputView, let window = panel.window else {
			note("✗ window did not open")
			return
		}
		let phrase = "Хочу пожаловаться на доставку"
		for ch in phrase {
			field.insertText(String(ch), replacementRange: field.selectedRange())
			await sleep(0.02)
		}
		if let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
		                                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
		                                isARepeat: false, keyCode: 36) { window.sendEvent(enter) }
		let translated = await wait(40) {
			panel.session.kind == .text && panel.session.answeredInput == phrase && !panel.session.streaming && !panel.session.answer.isEmpty
		}
		note((translated ? "✓" : "✗") + " translated: \(panel.session.answer)")
		panel.session.startAsk()
		await sleep(0.4)
		let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
		note("   after startAsk: overlay \(panel.session.overlay), first responder \(responder)")
		let pb = NSPasteboard.general
		let saved = PasteboardSnapshot(pb, budget: 2)
		pb.clearContents()
		pb.setString("попроще и короче", forType: .string)
		await pressCommand(9)
		let pasted = await wait(1.5) { panel.session.askText == "попроще и короче" }
		note((pasted ? "✓" : "✗") + " ⌘V in «Попросить»: «\(panel.session.askText)», field still «\(panel.session.input)», key window: \(window.isKeyWindow), responder: \(String(describing: type(of: window.firstResponder as Any)))")
		saved?.restore(to: pb)
		panel.hide()
		await sleep(0.3)
	}

	private static func enterFrames(text: String) async {
		guard let panel else { return }
		panel.show(selection: nil)
		guard await wait(2, { panel.inputView != nil && panel.isVisible }), let field = panel.inputView, let window = panel.window else {
			note("✗ window did not open")
			return
		}
		for ch in text {
			field.insertText(String(ch), replacementRange: field.selectedRange())
			await sleep(0.035)
		}
		await sleep(0.4)
		guard let host = window.contentView,
		      let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
		                                   windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
		                                   isARepeat: false, keyCode: 36) else { return }
		window.sendEvent(enter)
		var heights: [CGFloat] = []
		let name = text.count < 10 ? "word" : "text"
		for f in 0..<60 {
			if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
				host.cacheDisplay(in: host.bounds, to: rep)
				try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + String(format: "/%@-%02d.png", name, f)))
			}
			heights.append(panel.formHeight)
			await sleep(0.016)
		}
		note("form heights after Enter: " + heights.map { String(format: "%.0f", $0) }.joined(separator: " "))
		note("window frame: \(window.frame), visible \(window.isVisible), key \(window.isKeyWindow)")
		note("answer: \(panel.session.kind == .card ? panel.session.lines.map(\.term).joined(separator: ", ") : panel.session.answer)")
		panel.hide()
		await sleep(0.3)
	}

	static func tapRightCommand() async {
		let src = CGEventSource(stateID: .hidSystemState)
		guard let down = CGEvent(keyboardEventSource: src, virtualKey: 54, keyDown: true),
		      let up = CGEvent(keyboardEventSource: src, virtualKey: 54, keyDown: false) else { return }
		down.type = .flagsChanged
		down.flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10 | 0x100)
		up.type = .flagsChanged
		up.flags = CGEventFlags(rawValue: 0x100)
		down.post(tap: .cghidEventTap)
		await sleep(0.07)
		up.post(tap: .cghidEventTap)
	}

	private static let probeText = "Мне кажется, курьер опять опоздает на два часа.\nI think the courier will be late again, as usual."

	private static func openTextEdit() async -> (NSRunningApplication, AXUIElement)? {
		let url = URL(fileURLWithPath: dir + "/probe.txt")
		try? probeText.write(to: url, atomically: true, encoding: .utf8)
		let cfg = NSWorkspace.OpenConfiguration()
		cfg.activates = true
		let te = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
		guard let app = try? await NSWorkspace.shared.open([url], withApplicationAt: te, configuration: cfg) else {
			note("✗ TextEdit did not open")
			return nil
		}
		var area: AXUIElement?
		let ok = await wait(8) {
			guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
			let ax = AXUIElementCreateApplication(app.processIdentifier)
			var f: CFTypeRef?
			guard AXUIElementCopyAttributeValue(ax, kAXFocusedUIElementAttribute as CFString, &f) == .success, let el = f else { return false }
			var v: CFTypeRef?
			AXUIElementCopyAttributeValue(el as! AXUIElement, kAXValueAttribute as CFString, &v)
			guard (v as? String)?.contains("курьер") == true else { return false }
			area = (el as! AXUIElement)
			return true
		}
		guard ok, let area else {
			note("✗ TextEdit text area not focused")
			return nil
		}
		return (app, area)
	}

	private static func select(_ area: AXUIElement, _ range: NSRange) -> Bool {
		var r = CFRange(location: range.location, length: range.length)
		guard let v = AXValueCreate(.cfRange, &r) else { return false }
		return AXUIElementSetAttributeValue(area, kAXSelectedTextRangeAttribute as CFString, v) == .success
	}

	private static func selection(word: String, sentence: Bool) async {
		let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").isEmpty
		guard let (te, area) = await openTextEdit(), let panel else { return }
		let ns = probeText as NSString
		let range = sentence ? ns.range(of: "I think the courier will be late again, as usual.") : ns.range(of: word)
		let expected = ns.substring(with: range)
		note("select «\(expected)»: \(select(area, range))")
		await sleep(0.3)
		let t0 = Date()
		await tapRightCommand()
		let opened = await wait(3) { panel.isVisible && panel.session.input == expected }
		note((opened ? "✓" : "✗") + String(format: " window with the selection in %.0f ms (input: «%@»)", Date().timeIntervalSince(t0) * 1000, panel.session.input))
		note("   selection: \(Selection.lastTrace); secure input: \(IsSecureEventInputEnabled())")
		let done = await wait(25) { panel.session.kind != .none && !panel.session.streaming && panel.session.failure == nil }
		let result = panel.session.kind == .card ? panel.session.lines.map(\.term).joined(separator: ", ") : panel.session.answer
		note((done ? "✓" : "✗") + String(format: " translated in %.1f s: %@", Date().timeIntervalSince(t0), result))
		panel.hide()
		await sleep(0.3)
		if !wasRunning { te.terminate() }
		await sleep(0.5)
	}
}
