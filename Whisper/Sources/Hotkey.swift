import AppKit
import Carbon.HIToolbox
import os

final class HotkeyMonitor {
	enum Event { case down, up, chord, escape }

	var onEvent: ((Event, TimeInterval) -> Void)?
	private let state = OSAllocatedUnfairLock(initialState: Shared())
	private var tap: CFMachPort?
	private var source: CFRunLoopSource?
	private var runLoop: CFRunLoop?
	private var rightDown = false
	private static let rightOptionMask: UInt64 = 0x40
	private static let otherModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskShift, .maskSecondaryFn]

	private struct Shared {
		var swallowEscape = false
		var ownUI: CGRect?
	}

	var swallowEscape: Bool {
		get { state.withLock { $0.swallowEscape } }
		set { state.withLock { $0.swallowEscape = newValue } }
	}

	var ownUIFrame: CGRect? {
		get { state.withLock { $0.ownUI } }
		set { state.withLock { $0.ownUI = newValue } }
	}

	@discardableResult
	func start() -> Bool {
		guard tap == nil else { return true }
		let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
			| (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
			| (1 << CGEventType.otherMouseDown.rawValue)
		let ref = Unmanaged.passUnretained(self).toOpaque()
		guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
		                                eventsOfInterest: CGEventMask(mask), callback: { _, type, event, refcon in
			let me = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
			return me.handle(type, event)
		}, userInfo: ref) else { return false }
		let src = CFMachPortCreateRunLoopSource(nil, t, 0)!
		let ready = DispatchSemaphore(value: 0)
		var loop: CFRunLoop?
		let thread = Thread {
			loop = CFRunLoopGetCurrent()
			CFRunLoopAddSource(loop, src, .commonModes)
			ready.signal()
			CFRunLoopRun()
		}
		thread.name = "whisper.hotkey"
		thread.qualityOfService = .userInteractive
		thread.start()
		ready.wait()
		tap = t
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

	private func releasedIfMissed(_ flags: CGEventFlags, _ event: CGEvent? = nil) -> Bool {
		guard rightDown, flags.rawValue & Self.rightOptionMask == 0 else { return false }
		rightDown = false
		emit(.up, event)
		return true
	}

	private static let timebase: Double = {
		var tb = mach_timebase_info_data_t()
		mach_timebase_info(&tb)
		return Double(tb.numer) / Double(tb.denom)
	}()

	private static func moment(of event: CGEvent?) -> TimeInterval {
		let now = ProcessInfo.processInfo.systemUptime
		guard let ts = event?.timestamp, ts > 0 else { return now }
		let readings = [Double(ts) / 1e9, Double(ts) * timebase / 1e9].filter { $0 <= now + 0.01 && now - $0 < 2 }
		return readings.min { now - $0 < now - $1 } ?? now
	}

	private func emit(_ e: Event, _ event: CGEvent? = nil) {
		let t = Self.moment(of: event)
		DispatchQueue.main.async { [weak self] in self?.onEvent?(e, t) }
	}

	private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
		if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) {
			return Unmanaged.passUnretained(event)
		}
		switch type {
		case .tapDisabledByTimeout, .tapDisabledByUserInput:
			if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
			_ = releasedIfMissed(CGEventSource.flagsState(.combinedSessionState))
		case .flagsChanged:
			let code = event.getIntegerValueField(.keyboardEventKeycode)
			let flags = event.flags
			let rightNow = flags.rawValue & Self.rightOptionMask != 0
			if code == Int64(kVK_RightOption) {
				if rightNow {
					rightDown = true
					if flags.intersection(Self.otherModifiers).isEmpty { emit(.down, event) }
				} else if rightDown {
					rightDown = false
					emit(.up, event)
				}
			} else if rightDown, !releasedIfMissed(flags, event), !flags.intersection(Self.otherModifiers).isEmpty {
				emit(.chord, event)
			}
		case .keyDown:
			let code = event.getIntegerValueField(.keyboardEventKeycode)
			if code == Int64(kVK_Escape), swallowEscape {
				emit(.escape, event)
				return nil
			}
			if rightDown, !releasedIfMissed(event.flags, event) { emit(.chord, event) }
		case .leftMouseDown, .rightMouseDown, .otherMouseDown:
			guard rightDown, event.flags.contains(.maskAlternate) else {
				_ = releasedIfMissed(event.flags, event)
				break
			}
			if !(ownUIFrame?.contains(event.location) ?? false) { emit(.chord, event) }
		default:
			break
		}
		return Unmanaged.passUnretained(event)
	}
}

struct HotkeyLogic {
	enum State: Equatable { case idle, holding(since: TimeInterval), latched }
	enum Action: Equatable { case none, start, stop, cancel, cancelPending }

	var state: State = .idle
	var tapThreshold: TimeInterval = 0.35
	var quietTapLimit: TimeInterval = 0.8
	var doublePressGuard: TimeInterval = 0.6
	private var startedAt: TimeInterval = 0

	var isRecording: Bool { state != .idle }

	mutating func handle(_ event: HotkeyMonitor.Event, at t: TimeInterval, heardSpeech: Bool = true) -> Action {
		switch (state, event) {
		case (.idle, .down):
			state = .holding(since: t)
			startedAt = t
			return .start
		case let (.holding(since), .up):
			let held = t - since
			if held < tapThreshold || (held < quietTapLimit && !heardSpeech) {
				state = .latched
				return .none
			}
			state = .idle
			return .stop
		case (.holding, .chord):
			state = .idle
			return .cancel
		case (.latched, .down):
			if t - startedAt < doublePressGuard && !heardSpeech { return .none }
			state = .idle
			return .stop
		case (.holding, .escape), (.latched, .escape):
			state = .idle
			return .cancel
		case (.idle, .escape):
			return .cancelPending
		default:
			return .none
		}
	}

	mutating func reset() { state = .idle }

	mutating func latch() {
		if case .holding = state { state = .latched }
	}
}
