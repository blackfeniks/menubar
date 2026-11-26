import AppKit
import Carbon.HIToolbox

private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

struct TapRecognizer {
	static let maxTap: TimeInterval = 0.5
	static let ownEventTag: Int64 = 0x7472_616E_736C
	private static let rightCommandBit: UInt64 = 0x10
	private static let leftCommandBit: UInt64 = 0x08
	private static let otherModifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]

	struct Probe {
		var mouseHeld: Bool
		var keyPresses: UInt32
	}

	private var downAt: TimeInterval?
	private var clean = false
	private var keyPressesAtDown: UInt32 = 0

	mutating func feed(_ type: CGEventType, _ event: CGEvent, now: TimeInterval, probe: () -> Probe) -> Bool {
		if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
			downAt = nil
			return false
		}
		if event.getIntegerValueField(.eventSourceUserData) == Self.ownEventTag { return false }
		switch type {
		case .flagsChanged:
			guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_RightCommand) else {
				if downAt != nil { clean = false }
				return false
			}
			let flags = event.flags
			let raw = flags.rawValue
			let pressed = raw & Self.rightCommandBit != 0 || (flags.contains(.maskCommand) && raw & Self.leftCommandBit == 0)
			if pressed {
				let p = probe()
				downAt = now
				keyPressesAtDown = p.keyPresses
				clean = flags.intersection(Self.otherModifiers).isEmpty && raw & Self.leftCommandBit == 0 && !p.mouseHeld
				return false
			}
			guard let t = downAt else { return false }
			downAt = nil
			guard clean, now - t < Self.maxTap else { return false }
			let p = probe()
			return p.keyPresses == keyPressesAtDown && !p.mouseHeld
		case .scrollWheel:
			if downAt != nil, Self.isUserScroll(event) { clean = false }
		case .keyUp:
			break
		default:
			if downAt != nil { clean = false }
		}
		return false
	}

	static func isUserScroll(_ e: CGEvent) -> Bool {
		if e.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 { return false }
		let phase = e.getIntegerValueField(.scrollWheelEventScrollPhase)
		if phase != 0 { return phase == 1 || phase == 2 }
		return e.getIntegerValueField(.scrollWheelEventDeltaAxis1) != 0 || e.getIntegerValueField(.scrollWheelEventDeltaAxis2) != 0
			|| e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) != 0 || e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) != 0
	}
}

final class KeyHold: @unchecked Sendable {
	private let lock = NSLock()
	private var until: TimeInterval = 0
	private var kept: [CGEvent] = []
	private var down = Set<Int64>()

	func start(now: TimeInterval, for seconds: TimeInterval) {
		lock.lock()
		defer { lock.unlock() }
		until = now + seconds
		kept = []
		down = []
	}

	func keep(_ type: CGEventType, _ event: CGEvent, now: TimeInterval) -> Bool {
		guard type == .keyDown || type == .keyUp,
		      event.getIntegerValueField(.eventSourceUserData) != TapRecognizer.ownEventTag else { return false }
		let code = event.getIntegerValueField(.keyboardEventKeycode)
		lock.lock()
		defer { lock.unlock() }
		if type == .keyDown {
			guard now < until else { return false }
			down.insert(code)
		} else if down.remove(code) == nil {
			return false
		}
		kept.append(event.copy() ?? event)
		return true
	}

	func finish() -> [CGEvent] {
		lock.lock()
		defer { lock.unlock() }
		until = 0
		down = []
		let events = kept
		kept = []
		return events
	}
}

final class HotkeyMonitor {
	var onTap: (() -> Void)?
	let hold = KeyHold()
	private var tap: CFMachPort?
	private var source: CFRunLoopSource?
	private var runLoop: CFRunLoop?
	private var recognizer = TapRecognizer()

	@discardableResult
	func start() -> Bool {
		guard tap == nil else { return true }
		let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
		let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
		let ref = Unmanaged.passUnretained(self).toOpaque()
		guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
		                                eventsOfInterest: mask, callback: { _, type, event, refcon in
			let me = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
			return me.handle(type, event) ? Unmanaged.passUnretained(event) : nil
		}, userInfo: ref) else { return false }
		tap = t
		let src = CFMachPortCreateRunLoopSource(nil, t, 0)!
		let ready = DispatchSemaphore(value: 0)
		var loop: CFRunLoop?
		let thread = Thread {
			loop = CFRunLoopGetCurrent()
			CFRunLoopAddSource(loop, src, .commonModes)
			ready.signal()
			CFRunLoopRun()
		}
		thread.name = "translator.hotkey"
		thread.qualityOfService = .userInteractive
		thread.start()
		ready.wait()
		source = src
		runLoop = loop
		CGEvent.tapEnable(tap: t, enable: true)
		return true
	}

	func stop() {
		if let tap {
			CGEvent.tapEnable(tap: tap, enable: false)
			CFMachPortInvalidate(tap)
		}
		if let runLoop, let source {
			CFRunLoopRemoveSource(runLoop, source, .commonModes)
			CFRunLoopStop(runLoop)
		}
		tap = nil
		source = nil
		runLoop = nil
	}

	func holdKeys(for seconds: TimeInterval) {
		hold.start(now: uptime, for: seconds)
	}

	func releaseKeys() -> [CGEvent] {
		hold.finish()
	}

	private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
		let now = uptime
		if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput, let tap {
			CGEvent.tapEnable(tap: tap, enable: true)
		}
		if recognizer.feed(type, event, now: now, probe: Self.probe) {
			DispatchQueue.main.async { [weak self] in self?.onTap?() }
		}
		return !hold.keep(type, event, now: now)
	}

	private static func probe() -> TapRecognizer.Probe {
		let buttons: [CGMouseButton] = [.left, .right, .center]
		return TapRecognizer.Probe(mouseHeld: buttons.contains { CGEventSource.buttonState(.hidSystemState, button: $0) },
		                           keyPresses: CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown))
	}
}

enum AXAnswer: Equatable {
	case text(String)
	case nothing
	case secure
	case busy
	case unknown(role: String?)
}

struct SelectionCapture {
	var read: () -> AXAnswer
	var enableTree: () -> Bool
	var copy: ClipboardCopy?
	var isCancelled: () -> Bool = { false }
	var treeWait: TimeInterval = 0.3

	static let noCopyRoles: Set<String> = [kAXListRole, kAXOutlineRole, kAXTableRole, kAXBrowserRole, kAXButtonRole,
	                                       kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole,
	                                       kAXSliderRole, kAXIncrementorRole, kAXDisclosureTriangleRole, kAXColorWellRole]

	func run() -> String? { traced().text }

	func traced() -> (text: String?, how: String) {
		var answer = read()
		var how = "ax"
		if case .unknown = answer, !isCancelled(), enableTree() {
			how = "tree"
			let end = uptime + treeWait
			while !isCancelled() && uptime < end {
				Thread.sleep(forTimeInterval: 0.03)
				answer = read()
				if case .text = answer { break }
				if answer == .secure || answer == .busy { break }
			}
		}
		switch answer {
		case let .text(s):
			return (Selection.clean(s), how)
		case .nothing:
			return (nil, how + ": nothing selected")
		case .secure:
			return (nil, "password field")
		case .busy:
			return (nil, "app not answering")
		case let .unknown(role):
			if let role, Self.noCopyRoles.contains(role) { return (nil, "focus on \(role), no copy") }
			guard let copy, !isCancelled() else { return (nil, isCancelled() ? "cancelled" : "no copy here") }
			return (copy.run(shouldPress: { !isCancelled() }).flatMap(Selection.clean), "copy")
		}
	}
}

struct AXReader {
	let deadline: TimeInterval
	private struct Busy: Error {}
	private struct Late: Error {}
	private static let textEntryRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
	private static let timeout: Void = { AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.2) }()

	init(seconds: TimeInterval) { deadline = uptime + seconds }

	func read(app: NSRunningApplication?) -> AXAnswer {
		_ = Self.timeout
		do {
			return try answer(app)
		} catch is Busy {
			return .busy
		} catch {
			return .unknown(role: nil)
		}
	}

	private func answer(_ app: NSRunningApplication?) throws -> AXAnswer {
		var focused = try element(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
		if focused == nil, let app, app.processIdentifier != getpid() {
			focused = try element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute)
		}
		guard let el = focused else { return .unknown(role: nil) }
		var pid: pid_t = 0
		if AXUIElementGetPid(el, &pid) == .success, pid == getpid() { return .nothing }
		let role = try string(el, kAXRoleAttribute)
		if try string(el, kAXSubroleAttribute) == kAXSecureTextFieldSubrole { return .secure }
		let selected = try string(el, kAXSelectedTextAttribute)
		if let s = selected, !s.isEmpty { return .text(s) }
		let range = try selectedRange(el)
		if let r = range, r.length > 0 {
			if let s = try stringForRange(el, r), !s.isEmpty { return .text(s) }
			if let all = try string(el, kAXValueAttribute), let s = Self.substring(all, r), !s.isEmpty { return .text(s) }
		}
		if let role, Self.textEntryRoles.contains(role) {
			return selected != nil || range?.length == 0 ? .nothing : .unknown(role: role)
		}
		var node: AXUIElement? = el
		var nodeRole = role
		for level in 0..<12 {
			guard let n = node else { break }
			if let s = try markedText(n) {
				if !s.isEmpty { return .text(s) }
				if nodeRole == "AXWebArea" { return .nothing }
			}
			if nodeRole == "AXWebArea" {
				if level > 0, let s = try string(n, kAXSelectedTextAttribute), !s.isEmpty { return .text(s) }
				break
			}
			if nodeRole == kAXWindowRole || nodeRole == kAXApplicationRole { break }
			node = try element(n, kAXParentAttribute)
			nodeRole = try node.flatMap { try string($0, kAXRoleAttribute) }
		}
		return .unknown(role: role)
	}

	private func value(_ e: AXUIElement, _ name: String) throws -> CFTypeRef? {
		if uptime > deadline { throw Late() }
		var v: CFTypeRef?
		let err = AXUIElementCopyAttributeValue(e, name as CFString, &v)
		if err == .cannotComplete { throw Busy() }
		return err == .success ? v : nil
	}

	private func parameterized(_ e: AXUIElement, _ name: String, _ parameter: CFTypeRef) throws -> CFTypeRef? {
		if uptime > deadline { throw Late() }
		var v: CFTypeRef?
		let err = AXUIElementCopyParameterizedAttributeValue(e, name as CFString, parameter, &v)
		if err == .cannotComplete { throw Busy() }
		return err == .success ? v : nil
	}

	private func string(_ e: AXUIElement, _ name: String) throws -> String? {
		try value(e, name) as? String
	}

	private func element(_ e: AXUIElement, _ name: String) throws -> AXUIElement? {
		guard let v = try value(e, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
		return (v as! AXUIElement)
	}

	private func selectedRange(_ e: AXUIElement) throws -> CFRange? {
		guard let v = try value(e, kAXSelectedTextRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
		var r = CFRange()
		return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
	}

	private func stringForRange(_ e: AXUIElement, _ r: CFRange) throws -> String? {
		var range = r
		guard let param = AXValueCreate(.cfRange, &range) else { return nil }
		return try parameterized(e, kAXStringForRangeParameterizedAttribute, param) as? String
	}

	private func markedText(_ e: AXUIElement) throws -> String? {
		guard let range = try value(e, "AXSelectedTextMarkerRange") else { return nil }
		return try parameterized(e, "AXStringForTextMarkerRange", range) as? String
	}

	private static func substring(_ s: String, _ r: CFRange) -> String? {
		let ns = s as NSString
		guard r.location >= 0, r.length > 0, r.location + r.length <= ns.length else { return nil }
		return ns.substring(with: NSRange(location: r.location, length: r.length))
	}
}

enum AccessibilityTree {
	private static var asked = Set<pid_t>()

	static func enable(_ pid: pid_t) -> Bool {
		guard pid > 0, pid != getpid(), asked.insert(pid).inserted else { return false }
		return AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
	}
}

struct PasteboardSnapshot {
	let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]

	init?(_ pb: NSPasteboard, budget: TimeInterval) {
		let end = uptime + budget
		var all: [[(type: NSPasteboard.PasteboardType, data: Data)]] = []
		for item in pb.pasteboardItems ?? [] {
			var entries: [(type: NSPasteboard.PasteboardType, data: Data)] = []
			for type in item.types {
				if uptime > end { return nil }
				if let data = item.data(forType: type) { entries.append((type, data)) }
			}
			all.append(entries)
		}
		if uptime > end { return nil }
		items = all
	}

	func restore(to pb: NSPasteboard) {
		pb.clearContents()
		let objects: [NSPasteboardItem] = items.map { entries in
			let item = NSPasteboardItem()
			for e in entries { item.setData(e.data, forType: e.type) }
			return item
		}
		if !objects.isEmpty { pb.writeObjects(objects) }
	}
}

struct ClipboardCopy {
	var pasteboard: NSPasteboard = .general
	var press: () -> Void = Keystroke.copy
	var wait: TimeInterval = 0.3
	var saveBudget: TimeInterval = 0.15
	var watchLate: TimeInterval = 1.5

	func run(shouldPress: () -> Bool = { true }) -> String? {
		ClipboardWatch.stop()
		let before = pasteboard.changeCount
		guard let saved = PasteboardSnapshot(pasteboard, budget: saveBudget),
		      pasteboard.changeCount == before, shouldPress() else { return nil }
		press()
		let deadline = uptime + wait
		while pasteboard.changeCount == before {
			if uptime >= deadline {
				ClipboardWatch.restoreIfChanged(pasteboard, from: before, to: saved, for: watchLate)
				return nil
			}
			usleep(4000)
		}
		var text: String?
		let readUntil = uptime + 0.1
		while true {
			if pasteboard.types?.contains(.fileURL) == true { break }
			text = pasteboard.string(forType: .string)
			if text != nil || uptime >= readUntil { break }
			usleep(4000)
		}
		saved.restore(to: pasteboard)
		if text == nil { ClipboardWatch.restoreIfChanged(pasteboard, from: pasteboard.changeCount, to: saved, for: watchLate) }
		return text
	}
}

enum ClipboardWatch {
	private static let lock = NSLock()
	private static var generation = 0

	static func stop() {
		lock.lock()
		generation += 1
		lock.unlock()
	}

	static func restoreIfChanged(_ pb: NSPasteboard, from count: Int, to saved: PasteboardSnapshot, for seconds: TimeInterval) {
		lock.lock()
		generation += 1
		let mine = generation
		lock.unlock()
		let end = uptime + seconds
		DispatchQueue.global(qos: .utility).async {
			while uptime < end {
				usleep(20_000)
				lock.lock()
				defer { lock.unlock() }
				guard generation == mine else { return }
				if pb.changeCount != count {
					saved.restore(to: pb)
					return
				}
			}
		}
	}
}

enum Keystroke {
	static func copy() {
		let source = CGEventSource(stateID: .privateState)
		source?.localEventsSuppressionInterval = 0
		let command = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)
		func key(_ code: Int, down: Bool, _ flags: CGEventFlags, modifier: Bool = false) -> CGEvent? {
			guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { return nil }
			if modifier { e.type = .flagsChanged }
			e.flags = flags
			e.setIntegerValueField(.eventSourceUserData, value: TapRecognizer.ownEventTag)
			return e
		}
		let events = [key(kVK_Command, down: true, command, modifier: true), key(kVK_ANSI_C, down: true, command),
		              key(kVK_ANSI_C, down: false, command), key(kVK_Command, down: false, [], modifier: true)]
		for e in events { e?.post(tap: .cgSessionEventTap) }
	}
}

enum Selection {
	static let maxLength = 20_000
	@MainActor static var lastTrace = ""
	private static let queue = DispatchQueue(label: "translator.selection", qos: .userInitiated)

	static func capture(front: NSRunningApplication?, ticket: CancelToken, done: @escaping (String?) -> Void) {
		queue.async {
			let pid = front?.processIdentifier ?? 0
			let copyAllowed = pid != getpid() && !IsSecureEventInputEnabled() && front?.bundleIdentifier != "com.apple.finder"
			let noAX = ProcessInfo.processInfo.environment["TRANSLATOR_TEST_NO_AX"] != nil
			let capture = SelectionCapture(read: { noAX ? .unknown(role: nil) : AXReader(seconds: 0.35).read(app: front) },
			                               enableTree: { noAX ? false : AccessibilityTree.enable(pid) },
			                               copy: copyAllowed ? ClipboardCopy() : nil,
			                               isCancelled: { ticket.isCancelled })
			let start = uptime
			let (text, how) = capture.traced()
			let ms = Int((uptime - start) * 1000)
			appLog.info("selection: \(how, privacy: .public), \(text?.count ?? 0) chars in \(ms) ms")
			DispatchQueue.main.async {
				lastTrace = "\(how), \(text?.count ?? 0) chars in \(ms) ms, copy allowed: \(copyAllowed)"
				done(text)
			}
		}
	}

	static func clean(_ raw: String) -> String? {
		var scalars = String.UnicodeScalarView()
		var previousCR = false
		var cutEarly = false
		for (i, u) in raw.unicodeScalars.enumerated() {
			if i >= maxLength * 2 {
				cutEarly = true
				break
			}
			defer { previousCR = u == "\r" }
			switch u.value {
			case 0x0A where previousCR: continue
			case 0x0D, 0x0B, 0x0C, 0x85, 0x2028, 0x2029: scalars.append("\n")
			case 0x09, 0x0A: scalars.append(u)
			case 0x00...0x1F, 0x7F...0x9F, 0xAD, 0x200B, 0x2060, 0xFEFF: continue
			default: scalars.append(u)
			}
		}
		let lines = String(scalars).components(separatedBy: "\n").map { line -> String in
			var l = Substring(line)
			while let last = l.last, last == " " || last == "\t" { l.removeLast() }
			return String(l)
		}
		var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return nil }
		if cutEarly || text.count > maxLength {
			let head = String(text.prefix(maxLength))
			let floor = head.index(head.startIndex, offsetBy: head.count * 3 / 4)
			let ends = [". ", "! ", "? ", "… ", ".\n", "!\n", "?\n", "\n"]
			let cut = ends.compactMap { head.range(of: $0, options: .backwards, range: floor..<head.endIndex)?.lowerBound }.max()
				?? head[floor...].lastIndex(where: \.isWhitespace)
			text = String(head[..<(cut.map { head.index(after: $0) } ?? head.endIndex)]).trimmingCharacters(in: .whitespacesAndNewlines)
		}
		return text
	}

	static var accessibilityGranted: Bool { AXIsProcessTrusted() }

	static func requestAccessibility() {
		let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
		_ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
	}
}
