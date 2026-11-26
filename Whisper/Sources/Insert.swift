import AppKit
import ApplicationServices
import Carbon.HIToolbox

struct InsertionTarget {
	let pid: pid_t
	let bundleID: String?
	let appName: String
	let element: AXUIElement?
	let window: AXUIElement?

	static func capture() -> InsertionTarget? {
		guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
		let axApp = AXUIElementCreateApplication(app.processIdentifier)
		AXUIElementSetMessagingTimeout(axApp, 0.25)
		var focused: CFTypeRef?
		var element: AXUIElement?
		if AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
		   let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() {
			element = (f as! AXUIElement)
		}
		var win: CFTypeRef?
		var window: AXUIElement?
		if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &win) == .success,
		   let w = win, CFGetTypeID(w) == AXUIElementGetTypeID() {
			window = (w as! AXUIElement)
		}
		return InsertionTarget(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
		                       appName: app.localizedName ?? "the app", element: element, window: window)
	}

	var isAlive: Bool { NSRunningApplication(processIdentifier: pid)?.isTerminated == false }

	static let pasteOnly: Set<String> = [
		"com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
		"net.kovidgoyal.kitty", "co.zeit.hyper", "io.alacritty", "com.github.wez.wezterm", "org.tabby",
	]

	var allowsDirectWrite: Bool { !(bundleID.map(Self.pasteOnly.contains) ?? false) }
}

enum InsertResult {
	case inserted
	case clipboard(String)
}

@MainActor
final class Inserter {
	static func textBeforeCaret(_ element: AXUIElement?, maxLength: Int = 40) -> String? {
		guard let element else { return nil }
		var rangeValue: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
		      let rv = rangeValue, CFGetTypeID(rv) == AXValueGetTypeID() else { return nil }
		var range = CFRange()
		guard AXValueGetValue(rv as! AXValue, .cfRange, &range) else { return nil }
		if range.location == 0 { return "" }
		var want = CFRange(location: max(0, range.location - maxLength), length: min(maxLength, range.location))
		guard let param = AXValueCreate(.cfRange, &want) else { return nil }
		var out: CFTypeRef?
		guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
		                                                 param, &out) == .success else { return nil }
		return out as? String
	}

	static var isWord: (String) -> Bool = { _ in false }

	static func adapt(_ text: String, before: String?) -> String {
		guard let before, let last = before.last else { return text }
		var t = text
		let trailing = before.reversed().prefix(while: \.isWhitespace)
		if let solid = before.last(where: { !$0.isWhitespace }), !".!?…".contains(solid), !trailing.contains("\n") {
			t = TextPolish.lowercasedStart(t, isWord: isWord)
		}
		if last.isWhitespace || "([«\"'/–—-".contains(last) { return t }
		return " " + t
	}

	func insert(_ text: String, into target: InsertionTarget?) async -> InsertResult {
		guard !text.isEmpty else { return .inserted }
		guard let target, target.isAlive else {
			copyToClipboard(text, transient: false)
			return .clipboard("The window is gone — text is on the clipboard")
		}
		let front = NSWorkspace.shared.frontmostApplication
		let frontPid = front?.processIdentifier
		let current = frontPid.flatMap { Self.focusedElement(of: $0) }
		if frontPid == target.pid, Self.same(current, target.element) {
			let ok = await paste(Self.adapt(text, before: Self.textBeforeCaret(current ?? target.element))) {
				NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
			}
			if ok { return .inserted }
			copyToClipboard(text, transient: false)
			return .clipboard("The window changed while inserting — text is on the clipboard")
		}
		if target.allowsDirectWrite, let element = target.element,
		   await Self.setSelectedText(element, Self.adapt(text, before: Self.textBeforeCaret(element))) {
			return .inserted
		}
		let backWindow = frontPid.flatMap { Self.focusedWindow(of: $0) }
		let otherApp = frontPid != target.pid
		let otherWindow = otherApp || !Self.same(backWindow, target.window)
		func putUserBack() {
			if let front, !front.isTerminated, otherWindow {
				Self.bringToFront(pid: front.processIdentifier, window: backWindow)
			}
			if let current {
				AXUIElementSetAttributeValue(current, kAXFocusedAttribute as CFString, kCFBooleanTrue)
			}
		}
		func atTarget() -> Bool {
			guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { return false }
			guard let element = target.element else { return true }
			guard let focused = Self.focusedElement(of: target.pid) else { return false }
			return CFEqual(focused, element)
		}
		if otherWindow { Self.bringToFront(pid: target.pid, window: target.window) }
		if let element = target.element {
			AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
		}
		var ok = false
		for _ in 0..<40 {
			if atTarget() {
				ok = true
				break
			}
			try? await Task.sleep(nanoseconds: 25_000_000)
		}
		if ok {
			try? await Task.sleep(nanoseconds: 60_000_000)
			ok = await paste(Self.adapt(text, before: Self.textBeforeCaret(target.element)), stillThere: atTarget)
		}
		putUserBack()
		guard ok else {
			copyToClipboard(text, transient: false)
			return .clipboard("Couldn't get back to \(target.appName) — text is on the clipboard")
		}
		return .inserted
	}

	static func same(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
		guard let a, let b else { return true }
		return CFEqual(a, b)
	}

	static func bringToFront(pid: pid_t, window: AXUIElement?) {
		let axApp = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(axApp, 0.5)
		AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
		if let window {
			AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
			AXUIElementPerformAction(window, kAXRaiseAction as CFString)
		}
		NSRunningApplication(processIdentifier: pid)?.activate()
	}

	static func focusedWindow(of pid: pid_t) -> AXUIElement? {
		let axApp = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(axApp, 0.25)
		var win: CFTypeRef?
		guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &win) == .success,
		      let w = win, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
		return (w as! AXUIElement)
	}

	static func focusedElement(of pid: pid_t) -> AXUIElement? {
		let axApp = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(axApp, 0.25)
		var focused: CFTypeRef?
		guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
		      let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
		return (f as! AXUIElement)
	}

	static func setSelectedText(_ element: AXUIElement, _ text: String) async -> Bool {
		var settable: DarwinBoolean = false
		guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
		      settable.boolValue else { return false }
		func value() -> String? {
			var v: CFTypeRef?
			guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &v) == .success else { return nil }
			return v as? String
		}
		guard let before = value() else { return false }
		guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
			return false
		}
		if let after = value(), after != before { return true }
		try? await Task.sleep(nanoseconds: 150_000_000)
		guard let after = value() else { return false }
		return after != before
	}

	private struct SavedItem {
		let types: [NSPasteboard.PasteboardType]
		let data: [NSPasteboard.PasteboardType: Data]
	}

	private var userClipboard: [SavedItem] = []
	private var restorePending = false
	private var restoreToken = 0
	private var lastOurChange = -1

	func copyToClipboard(_ text: String, transient: Bool) {
		let pb = NSPasteboard.general
		pb.clearContents()
		let item = NSPasteboardItem()
		item.setString(text, forType: .string)
		if transient {
			item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
			item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
		}
		pb.writeObjects([item])
	}

	private static func snapshot(_ pb: NSPasteboard) -> [SavedItem] {
		pb.pasteboardItems?.map { item in
			SavedItem(types: item.types, data: Dictionary(uniqueKeysWithValues: item.types.compactMap { t in
				item.data(forType: t).map { (t, $0) }
			}))
		} ?? []
	}

	private func paste(_ text: String, stillThere: () -> Bool) async -> Bool {
		let pb = NSPasteboard.general
		if !restorePending || pb.changeCount != lastOurChange {
			userClipboard = Self.snapshot(pb)
		}
		restorePending = true
		restoreToken += 1
		copyToClipboard(text, transient: true)
		let ours = pb.changeCount
		lastOurChange = ours
		let held: CGEventFlags = [.maskAlternate, .maskShift, .maskControl, .maskCommand]
		var waited = 0
		while waited < 40, !CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty {
			try? await Task.sleep(nanoseconds: 25_000_000)
			waited += 1
		}
		let ok = stillThere()
		if ok {
			Self.postCommandV()
			try? await Task.sleep(nanoseconds: 250_000_000)
		}
		scheduleRestore(ours)
		return ok
	}

	private func scheduleRestore(_ ours: Int) {
		let token = restoreToken
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
			MainActor.assumeIsolated {
				guard let self, self.restoreToken == token else { return }
				self.restorePending = false
				let saved = self.userClipboard
				self.userClipboard = []
				let pb = NSPasteboard.general
				guard pb.changeCount == ours else { return }
				pb.clearContents()
				let items = saved.map { s in
					let item = NSPasteboardItem()
					for t in s.types {
						if let d = s.data[t] { item.setData(d, forType: t) }
					}
					return item
				}
				if !items.isEmpty { pb.writeObjects(items) }
			}
		}
	}

	static func postCommandV() {
		let src = CGEventSource(stateID: .privateState)
		let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
		let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
		down?.flags = .maskCommand
		up?.flags = .maskCommand
		down?.post(tap: .cgSessionEventTap)
		up?.post(tap: .cgSessionEventTap)
	}
}
