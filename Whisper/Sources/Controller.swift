import AppKit
import AVFoundation
import ApplicationServices

@MainActor
final class Controller {
	final class Job: @unchecked Sendable {
		let target: InsertionTarget?
		let seconds: Double
		var cancelled = false
		init(target: InsertionTarget?, seconds: Double) {
			self.target = target
			self.seconds = seconds
		}
	}

	private final class Meter {
		var peak: Float = 0
		var sincePush: Float = 0
		var lastPush = 0.0
	}

	enum State { case idle, recording, processing }

	let engine = Engine()
	let settings = Settings.shared
	let history = History()
	let dictionary = UserDictionary()
	let hud = HUD()
	let inserter = Inserter()
	private let hotkey = HotkeyMonitor()
	private var logic = HotkeyLogic()
	private let processing = DispatchQueue(label: "whisper.processing", qos: .userInitiated)
	private let finishing = DispatchQueue(label: "whisper.finishing", qos: .userInitiated)
	private var capture: AudioCapture?
	private var feeder: FileFeeder?
	private var session: DictationSession?
	private var meter = Meter()
	private var target: InsertionTarget?
	private var recordingStarted = Date()
	private var captureDevice: InputDevice?
	private var paused = false
	private var pauseStarted = Date()
	private var pausedTotal: TimeInterval = 0
	private var lastSpeechAt = Date()
	private var jobs: [Job] = []
	private var watchdog: Timer?
	private var axPoll: Timer?
	private var pendingShow: DispatchWorkItem?
	private var insertChain: Task<Void, Never>?

	var onChange: (() -> Void)?

	var state: State { session != nil ? .recording : (jobs.isEmpty ? .idle : .processing) }
	var accessibilityOK: Bool { AXIsProcessTrusted() }
	var microphoneOK: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

	init() {
		engine.log = { appLog.notice("\($0, privacy: .public)") }
		let speller = engine.speller
		Inserter.isWord = { speller.isWord($0) }
	}

	func start() {
		hud.enabled = settings.showHUD
		dictionary.reloadIfChanged()
		hotkey.onEvent = { [weak self] e, t in
			MainActor.assumeIsolated { self?.handle(e, at: t) }
		}
		hud.onFrame = { [weak self] frame in self?.hotkey.ownUIFrame = frame }
		hud.onButton = { [weak self] button in
			guard let self else { return }
			switch button {
			case .pause: togglePause()
			case .cancel:
				logic.reset()
				cancelRecording(quiet: false)
				hotkey.swallowEscape = insertPending
			}
		}
		AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
		if !settings.askedPermissions {
			settings.askedPermissions = true
			requestMicrophone()
			if !accessibilityOK { requestAccessibility() }
		}
		startHotkey()
	}

	private func startHotkey() {
		if accessibilityOK, hotkey.start() {
			axPoll?.invalidate()
			axPoll = nil
			onChange?()
			return
		}
		guard axPoll == nil else { return }
		axPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self, self.accessibilityOK else { return }
				self.startHotkey()
			}
		}
	}

	func requestAccessibility() {
		let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
		_ = AXIsProcessTrustedWithOptions(opts)
		startHotkey()
	}

	func requestMicrophone() {
		switch AVCaptureDevice.authorizationStatus(for: .audio) {
		case .notDetermined:
			AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
				DispatchQueue.main.async { self?.onChange?() }
			}
		case .denied, .restricted:
			NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
		default:
			break
		}
	}

	func openAccessibilitySettings() {
		requestAccessibility()
		NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
	}

	private func log(_ s: @autoclosure () -> String) {
		guard engine.verbose else { return }
		let message = s()
		appLog.notice("\(message, privacy: .public)")
	}

	private func handle(_ event: HotkeyMonitor.Event, at t: TimeInterval) {
		let action = logic.handle(event, at: t, heardSpeech: session?.heardSpeech ?? true)
		log("hotkey \(event) → \(action), state \(logic.state)")
		switch action {
		case .start: startRecording()
		case .stop: stopRecording()
		case .cancel: cancelRecording(quiet: event == .chord)
		case .cancelPending: cancelPending()
		case .none:
			if logic.state == .latched {
				hud.model.handsFree = true
				showRecordingUI(now: true)
			}
		}
		hotkey.swallowEscape = logic.isRecording || insertPending
	}

	private var insertPending: Bool { jobs.contains { !$0.cancelled } }

	private func startRecording() {
		let engine = self.engine
		guard microphoneOK else {
			logic.reset()
			requestMicrophone()
			hud.flash("mic.slash", "No microphone access — allow it in the Whisper menu", seconds: 3)
			return
		}
		guard ModelFiles.ready else {
			logic.reset()
			hud.flash("exclamationmark.triangle", "No models in the Models folder", seconds: 3)
			return
		}
		guard let device = AudioDevices.resolve(uid: settings.deviceUID) else {
			logic.reset()
			hud.flash("mic.slash", "No microphone found", seconds: 2)
			return
		}
		target = InsertionTarget.capture()
		dictionary.reloadIfChanged()
		let terms = dictionary.terms
		engine.useLLM = settings.llmEnabled
		engine.useHints = settings.llmEnabled && settings.hintsEnabled
		engine.idleUnload = TimeInterval(settings.unloadMinutes * 60)
		engine.prepare()

		let s = DictationSession(vad: { engine.vad() }, asrQueue: engine.asrQueue,
		                         recognize: { engine.recognize($0) }, quickRecognize: { engine.quickRecognize($0) },
		                         correct: { engine.correct($0, hint: $1, terms: terms).0 },
		                         correctQueue: engine.llmQueue)
		if settings.livePreview {
			s.onPreview = { [weak self, weak s] preview in
				DispatchQueue.main.async {
					MainActor.assumeIsolated {
						guard let self, let s, self.session === s else { return }
						self.hud.setText(preview)
					}
				}
			}
		}
		let cap = AudioCapture(queue: processing)
		let meter = Meter()
		cap.onSamples = { [weak self] samples, rms in
			s.append(samples)
			meter.peak = max(meter.peak, rms)
			meter.sincePush = max(meter.sincePush, rms)
			let now = ProcessInfo.processInfo.systemUptime
			guard now - meter.lastPush >= 0.05 else { return }
			meter.lastPush = now
			let db = 20 * log10(max(meter.sincePush, 1e-6))
			meter.sincePush = 0
			let level = max(0, min(1, (db + 55) / 40))
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					guard let self, self.session === s else { return }
					self.hud.model.level = level
					if level > 0.35 { self.lastSpeechAt = Date() }
				}
			}
		}
		cap.onDeviceLost = { [weak self] in
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					guard let self, self.session === s else { return }
					self.logic.reset()
					self.stopRecording()
					self.hud.flash("mic.slash", "Microphone disconnected — transcribing what was recorded", seconds: 2.5)
				}
			}
		}
		if let fake = ProcessInfo.processInfo.environment["WHISPER_FAKE_MIC"] {
			do {
				let f = try FileFeeder(path: fake, queue: processing)
				f.onSamples = cap.onSamples
				f.start()
				feeder = f
			} catch {
				logic.reset()
				hud.flash("exclamationmark.triangle", "Couldn't open \(fake): \(error)", seconds: 3)
				scheduleUnloadIfIdle()
				return
			}
		} else {
			startCapture(cap, device, for: s) { [weak self] error in
				self?.discard(s, "Couldn't start the microphone: \(error)")
			}
		}
		capture = cap
		self.meter = meter
		captureDevice = device
		session = s
		paused = false
		pausedTotal = 0
		recordingStarted = Date()
		lastSpeechAt = Date()
		hud.model.handsFree = false
		showRecordingUI(now: false)
		startWatchdog()
		onChange?()
	}

	private func startCapture(_ cap: AudioCapture, _ device: InputDevice, for s: DictationSession,
	                          failed: @escaping @MainActor (Error) -> Void) {
		processing.async { [weak self] in
			do { try cap.start(device: device) } catch {
				DispatchQueue.main.async {
					MainActor.assumeIsolated {
						guard let self, self.session === s else { return }
						failed(error)
					}
				}
			}
		}
	}

	private func discard(_ s: DictationSession, _ message: String) {
		guard session === s else { return }
		logic.reset()
		stopCapture()
		s.cancel()
		session = nil
		hotkey.swallowEscape = insertPending
		hud.flash("exclamationmark.triangle", message, seconds: 3)
		scheduleUnloadIfIdle()
		onChange?()
	}

	private func showRecordingUI(now: Bool) {
		pendingShow?.cancel()
		let work = DispatchWorkItem { [weak self] in
			guard let self, self.session != nil else { return }
			if self.hud.model.phase != .recording {
				self.hud.recording(handsFree: self.hud.model.handsFree)
				self.hud.model.resumedAt = self.recordingStarted
				self.play("Tink")
			}
		}
		pendingShow = work
		DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0 : 0.15), execute: work)
	}

	private func startWatchdog() {
		watchdog?.invalidate()
		watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self, self.session != nil else { return }
				let now = Date()
				if self.paused {
					if now.timeIntervalSince(self.pauseStarted) > 20 * 60 {
						self.logic.reset()
						self.stopRecording(insert: false)
						self.hud.flash("clock", "Paused too long — kept in history", seconds: 3)
					}
					return
				}
				if now.timeIntervalSince(self.recordingStarted) - self.pausedTotal > 30 * 60 {
					self.logic.reset()
					self.stopRecording()
				} else if self.logic.state == .latched, now.timeIntervalSince(self.lastSpeechAt) > 120 {
					self.logic.reset()
					self.stopRecording()
				}
			}
		}
	}

	func togglePause() {
		guard let s = session else { return }
		logic.latch()
		hud.model.handsFree = true
		if !paused {
			paused = true
			pauseStarted = Date()
			if let cap = capture { processing.sync { cap.stop() } }
			if let f = feeder { processing.sync { f.stop() } }
			processing.async { s.breakHere() }
			hud.setPaused(true)
		} else {
			if let f = feeder {
				f.start()
			} else if let cap = capture, let d = captureDevice {
				startCapture(cap, d, for: s) { [weak self] _ in
					guard let self else { return }
					self.logic.reset()
					self.stopRecording()
					self.hud.flash("mic.slash", "Microphone didn't start — transcribing what was recorded", seconds: 2.5)
				}
			}
			pausedTotal += Date().timeIntervalSince(pauseStarted)
			paused = false
			lastSpeechAt = Date()
			hud.setPaused(false)
		}
		log("pause → \(paused)")
		onChange?()
	}

	private func stopCapture() {
		paused = false
		pendingShow?.cancel()
		watchdog?.invalidate()
		watchdog = nil
		if let cap = capture { processing.sync { cap.stop() } }
		if let f = feeder { processing.sync { f.stop() } }
		capture = nil
		feeder = nil
	}

	private func stopRecording(insert: Bool = true, cancelled: Bool = false) {
		guard let s = session else { return }
		stopCapture()
		session = nil
		let job = Job(target: target, seconds: s.duration)
		job.cancelled = !insert
		jobs.append(job)
		hotkey.swallowEscape = insertPending
		if cancelled {
			hud.flash("xmark.circle", "Cancelled — kept in history", seconds: 1.4)
		} else {
			play("Pop")
			hud.processing()
		}
		onChange?()
		log(String(format: "stop: %.1f s of audio, %.1f s of speech", s.duration, s.speechSeconds))
		let speller = engine.speller
		let stoppedAt = Date()
		let (audio, speech, peak) = (s.duration, s.speechSeconds, Double(20 * log10(max(meter.peak, 1e-6))))
		finishing.async { [weak self] in
			let segments = s.finish()
			let raw = TextPolish.join(segments.map { $0.final ?? TermMatcher.apply($0.text, isRussianWord: speller.isWord) },
			                          isWord: speller.isWord)
			let corrected = segments.filter { $0.final != nil }.count
			appLog.notice("""
				dictation: \(audio, format: .fixed(precision: 1), privacy: .public) s audio, \
				\(speech, format: .fixed(precision: 1), privacy: .public) s speech, \
				peak \(peak, format: .fixed(precision: 0), privacy: .public) dB, \
				\(segments.count, privacy: .public) segments (\(corrected, privacy: .public) corrected), \
				\(raw.count, privacy: .public) chars, \
				\(Date().timeIntervalSince(stoppedAt), format: .fixed(precision: 2), privacy: .public) s after stop
				""")
			DispatchQueue.main.async {
				MainActor.assumeIsolated { self?.complete(job, raw: raw) }
			}
		}
	}

	private func cancelRecording(quiet: Bool) {
		guard let s = session else { return }
		if !quiet, s.heardSpeech {
			stopRecording(insert: false, cancelled: true)
			return
		}
		stopCapture()
		s.cancel()
		session = nil
		if quiet, hud.model.phase != .recording {
		} else {
			hud.flash("xmark.circle", "Cancelled", seconds: 0.8)
		}
		scheduleUnloadIfIdle()
		onChange?()
	}

	private func cancelPending() {
		for j in jobs { j.cancelled = true }
		hud.flash("xmark.circle", "Not inserted — kept in history", seconds: 1.5)
	}

	private func complete(_ job: Job, raw: String) {
		jobs.removeAll { $0 === job }
		hotkey.swallowEscape = logic.isRecording || insertPending
		scheduleUnloadIfIdle()
		var text = TextPolish.finalize(raw, dictionary: dictionary)
		if settings.dropFinalPeriod {
			if text.hasSuffix("."), !text.hasSuffix("..") { text.removeLast() }
		} else if let last = text.last, last.isLetter || last.isNumber {
			text += "."
		}
		let busy = session != nil
		defer { onChange?() }
		guard !text.isEmpty else {
			if !busy, !job.cancelled { hud.flash("waveform.slash", "Heard nothing", seconds: 1.2) }
			return
		}
		history.add(HistoryItem(text: text, date: Date(), app: job.target?.appName, seconds: job.seconds))
		guard !job.cancelled else { return }
		log("finished: \(text)")
		let previous = insertChain
		insertChain = Task { @MainActor in
			await previous?.value
			var waited = 0
			while logic.state != .idle, logic.state != .latched, waited < 1200 {
				try? await Task.sleep(nanoseconds: 50_000_000)
				waited += 1
			}
			let result = await inserter.insert(text, into: job.target)
			switch result {
			case .inserted: appLog.notice("inserted")
			case .clipboard: appLog.notice("left on the clipboard")
			}
			guard session == nil else { return }
			switch result {
			case .inserted: hud.done(text)
			case let .clipboard(why): hud.flash("doc.on.clipboard", why, seconds: 3)
			}
		}
	}

	private func scheduleUnloadIfIdle() {
		if session == nil && jobs.isEmpty { engine.scheduleUnload() }
	}

	func setUnloadMinutes(_ minutes: Int) {
		settings.unloadMinutes = minutes
		engine.idleUnload = TimeInterval(minutes * 60)
		scheduleUnloadIfIdle()
	}

	func copy(_ item: HistoryItem) {
		inserter.copyToClipboard(item.text, transient: false)
		hud.flash("doc.on.doc", "Copied", seconds: 0.9)
	}

	private func play(_ name: String) {
		guard settings.sounds, let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
		sound.volume = 0.25
		sound.play()
	}

	func shutdown() {
		cancelRecording(quiet: true)
		hotkey.stop()
	}
}
