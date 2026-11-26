import AppKit
import Carbon.HIToolbox

@MainActor
enum EditKeys {
	enum Action: CaseIterable {
		case selectAll, copy, cut, paste, undo, redo

		var selector: Selector {
			switch self {
			case .selectAll: #selector(NSResponder.selectAll(_:))
			case .copy: #selector(NSText.copy(_:))
			case .cut: #selector(NSText.cut(_:))
			case .paste: #selector(NSText.paste(_:))
			case .undo: Selector(("undo:"))
			case .redo: Selector(("redo:"))
			}
		}
	}

	static var board: NSPasteboard = .general

	nonisolated static func action(for event: NSEvent) -> Action? {
		guard event.type == .keyDown else { return nil }
		let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
		guard mods == .command || mods == [.command, .shift] else { return nil }
		let shift = mods.contains(.shift)
		switch letter(of: event) {
		case "a": return shift ? nil : .selectAll
		case "c": return shift ? nil : .copy
		case "x": return shift ? nil : .cut
		case "v": return shift ? nil : .paste
		case "z": return shift ? .redo : .undo
		default: return nil
		}
	}

	nonisolated static func letter(of event: NSEvent) -> Character? {
		guard event.type == .keyDown || event.type == .keyUp else { return nil }
		let typed = [event.characters, event.charactersIgnoringModifiers].compactMap { $0 }
		for s in typed {
			let lower = s.lowercased()
			if lower.count == 1, let c = lower.first, c.isASCII, c.isLetter { return c }
		}
		guard let s = typed.first(where: { !$0.isEmpty }), !s.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
		return latinLetter(keyCode: event.keyCode)
	}

	nonisolated private static func latinLetter(keyCode: UInt16) -> Character? {
		if let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
		   let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
			let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
			let typed: String? = data.withUnsafeBytes { buf in
				guard let layout = buf.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
				var dead: UInt32 = 0
				var chars = [UniChar](repeating: 0, count: 4)
				var n = 0
				let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
				                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &n, &chars)
				return status == noErr ? String(utf16CodeUnits: chars, count: n) : nil
			}
			if let typed {
				let lower = typed.lowercased()
				return lower.count == 1 && lower.first!.isASCII && lower.first!.isLetter ? lower.first : nil
			}
		}
		return usLetters[keyCode]
	}

	nonisolated private static let usLetters: [UInt16: Character] = [
		0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e",
		15: "r", 16: "y", 17: "t", 31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m",
	]

	static func perform(_ action: Action, in window: NSWindow) -> Bool {
		var responder = window.firstResponder
		while let r = responder, !r.responds(to: action.selector) { responder = r.nextResponder }
		guard let target = responder else { return false }
		if action == .copy || action == .cut { ClipboardWatch.stop() }
		if board !== NSPasteboard.general, !(target is InputTextView), let field = target as? NSTextView,
		   [.copy, .cut, .paste].contains(action) {
			let types = field.writablePasteboardTypes
			switch action {
			case .copy: _ = field.writeSelection(to: board, types: types)
			case .cut: if field.isEditable, field.writeSelection(to: board, types: types) { field.delete(nil) }
			default: _ = field.readSelection(from: board)
			}
			return true
		}
		let editor = window.firstResponder as? NSTextView
		let before = editor?.string
		NSApp.sendAction(action.selector, to: target, from: window)
		if action == .undo || action == .redo, let editor, editor.isFieldEditor, editor.string != before { editor.didChangeText() }
		return true
	}
}
