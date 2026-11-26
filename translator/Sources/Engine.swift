import Foundation
import Observation
import os

let appLog = Logger(subsystem: "com.ilya.translator", category: "translator")

enum ModelFiles {
	static let preferred = "gemma-4-26B_q4_0-it.gguf"

	static var llm: URL? {
		if let path = ProcessInfo.processInfo.environment["TRANSLATOR_LLM"] { return URL(fileURLWithPath: path) }
		let url = AppPaths.models.appendingPathComponent(preferred)
		return FileManager.default.fileExists(atPath: url.path) ? url : nil
	}
}

enum FileCache {
	private static let chunk = 4 << 20, lanes = 8

	@discardableResult
	static func warm(_ paths: [String], willRead: (() -> Void)? = nil) -> Int {
		var read = 0
		for path in paths {
			let fd = open(path, O_RDONLY)
			guard fd >= 0 else { continue }
			defer { close(fd) }
			var st = stat()
			guard fstat(fd, &st) == 0, st.st_size > 32 << 20 else { continue }
			let missing = missingChunks(fd, Int(st.st_size))
			guard !missing.isEmpty else { continue }
			if read == 0 { willRead?() }
			DispatchQueue.concurrentPerform(iterations: lanes) { lane in
				let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
				defer { buffer.deallocate() }
				for i in stride(from: lane, to: missing.count, by: lanes) {
					guard pread(fd, buffer, chunk, off_t(missing[i] * chunk)) > 0 else { return }
				}
			}
			read += missing.count * chunk
		}
		return read
	}

	private static func missingChunks(_ fd: Int32, _ size: Int) -> [Int] {
		let chunks = (size + chunk - 1) / chunk
		guard let map = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0), map != UnsafeMutableRawPointer(bitPattern: -1) else {
			return Array(0..<chunks)
		}
		defer { munmap(map, size) }
		let page = Int(getpagesize())
		let pages = (size + page - 1) / page
		let perLane = (pages + lanes - 1) / lanes
		var resident = [CChar](repeating: 0, count: pages)
		resident.withUnsafeMutableBufferPointer { vector in
			guard let base = vector.baseAddress else { return }
			DispatchQueue.concurrentPerform(iterations: lanes) { lane in
				let first = lane * perLane, last = min(pages, first + perLane)
				guard first < last else { return }
				_ = mincore(map + first * page, min(size, last * page) - first * page, base + first)
			}
		}
		let perChunk = chunk / page
		return (0..<chunks).filter { c in
			(c * perChunk..<min(pages, (c + 1) * perChunk)).contains { resident[$0] & 1 == 0 }
		}
	}
}

@Observable
final class EngineState: @unchecked Sendable {
	var reading = false
}

final class Engine: @unchecked Sendable {
	static let shared = Engine()

	let queue = DispatchQueue(label: "translator.llm", qos: .userInitiated)
	private let lock = NSLock()
	private var llm: LocalLLM?
	private var loadError: String?
	private var generation = 0
	private var unloadTimer: DispatchSourceTimer?
	var idleUnload: TimeInterval = 3 * 60
	let state = EngineState()
	private var lastUse: TimeInterval = 0
	private static let refillAfter: TimeInterval = 20

	var unloadArmed: Bool {
		lock.lock()
		defer { lock.unlock() }
		return unloadTimer != nil
	}

	var isLoaded: Bool {
		lock.lock()
		defer { lock.unlock() }
		return llm?.isLoaded ?? false
	}

	private var lastError: String? {
		lock.lock()
		defer { lock.unlock() }
		return loadError
	}

	func prepare() {
		cancelUnload()
		queue.async { [self] in
			_ = loadLLM()
			scheduleUnload()
		}
	}

	private func loadLLM() -> LocalLLM? {
		if let llm, llm.isLoaded {
			refill(llm)
			return llm
		}
		guard let url = ModelFiles.llm else {
			setError("No model in the Models folder")
			return nil
		}
		let m = LocalLLM(path: url.path, format: Prompt.template(for:))
		setReading(true)
		defer { setReading(false) }
		do {
			let t = ProcessInfo.processInfo.systemUptime
			let read = FileCache.warm([url.path] + LocalLLM.caches(of: url.path))
			let warmed = ProcessInfo.processInfo.systemUptime
			try autoreleasepool { try m.load() }
			lastUse = ProcessInfo.processInfo.systemUptime
			appLog.notice("model loaded in \(self.lastUse - t, format: .fixed(precision: 2)) s: \(read >> 20) MB read from the disk in \(warmed - t, format: .fixed(precision: 2)) s, \(m.loadTimes, privacy: .public)")
			lock.lock()
			llm = m
			loadError = nil
			lock.unlock()
			return m
		} catch {
			setError("\(error)")
			return nil
		}
	}

	private func refill(_ llm: LocalLLM) {
		let now = ProcessInfo.processInfo.systemUptime
		defer { lastUse = ProcessInfo.processInfo.systemUptime }
		guard now - lastUse > Self.refillAfter else { return }
		var reading = false
		let read = FileCache.warm([llm.path]) {
			reading = true
			self.setReading(true)
		}
		guard reading else { return }
		setReading(false)
		appLog.notice("the loaded model was partly out of memory: \(read >> 20) MB read back in \(ProcessInfo.processInfo.systemUptime - now, format: .fixed(precision: 2)) s")
	}

	private func setReading(_ on: Bool) {
		DispatchQueue.main.async { [state] in if state.reading != on { state.reading = on } }
	}

	static let notLoaded = "the model didn't load"

	private func setError(_ text: String) {
		lock.lock()
		loadError = text
		lock.unlock()
		appLog.error("model: \(text, privacy: .public)")
	}

	@discardableResult
	func ask<Value>(_ q: Query<Value>, onPreview: ((Value) -> Void)? = nil, done: @escaping (Result<Value, Error>) -> Void) -> CancelToken {
		let token = CancelToken()
		cancelUnload()
		queue.async { [self] in
			defer { scheduleUnload() }
			guard !token.isCancelled else { return }
			let show = onPreview.map { show in { (v: Value) in DispatchQueue.main.async { if !token.isCancelled { show(v) } } } }
			let result: Result<Value, Error> = Result { try autoreleasepool { try answer(q, cancel: token, preview: show).value } }
			DispatchQueue.main.async { if !token.isCancelled { done(result) } }
		}
		return token
	}

	func askSync<Value>(_ q: Query<Value>, onText: ((String) -> Void)? = nil) throws -> (value: Value, raw: String) {
		try queue.sync { try autoreleasepool { try answer(q, cancel: nil, preview: nil, onText: onText) } }
	}

	private func answer<Value>(_ q: Query<Value>, cancel: CancelToken?, preview: ((Value) -> Void)?,
	                           onText: ((String) -> Void)? = nil) throws -> (value: Value, raw: String) {
		guard let llm = loadLLM() else { throw LLMError(description: lastError ?? Self.notLoaded) }
		defer { lastUse = ProcessInfo.processInfo.systemUptime }
		let raw = try llm.complete(q.request, forced: q.forced, maxTokens: max(300, q.request.utf8.count), cancel: cancel, onText: { text in
			onText?(text)
			if let preview, let value = q.preview?(text) { preview(value) }
		})
		if cancel?.isCancelled == true { throw LLMError(description: "cancelled") }
		guard let value = q.read(raw) else { throw LLMError(description: "the model gave no answer") }
		return (value, raw)
	}

	func runSync(_ request: String, forced: String = "", maxTokens: Int = 700, onText: ((String) -> Void)? = nil) throws -> String {
		try queue.sync {
			guard let llm = loadLLM() else { throw LLMError(description: lastError ?? Self.notLoaded) }
			return try autoreleasepool { try llm.complete(request, forced: forced, maxTokens: maxTokens, onText: onText) }
		}
	}

	func restart(done: @escaping (String?) -> Void) {
		cancelUnload()
		queue.async { [self] in
			lock.lock()
			let old = llm
			llm = nil
			loadError = nil
			lock.unlock()
			autoreleasepool { old?.unload() }
			if let path = ModelFiles.llm?.path { LocalLLM.removeCaches(of: path) }
			let error = loadLLM() == nil ? (lastError ?? Self.notLoaded) : nil
			appLog.notice("model restarted: \(error ?? "ok", privacy: .public)")
			scheduleUnload()
			DispatchQueue.main.async { done(error) }
		}
	}

	func scheduleUnload() {
		lock.lock()
		defer { lock.unlock() }
		unloadTimer?.cancel()
		generation += 1
		let due = generation
		let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
		t.schedule(deadline: .now() + idleUnload)
		t.setEventHandler { [weak self] in self?.unload(onlyIf: due) }
		t.resume()
		unloadTimer = t
	}

	private func cancelUnload() {
		lock.lock()
		unloadTimer?.cancel()
		unloadTimer = nil
		generation += 1
		lock.unlock()
	}

	func unload(onlyIf due: Int? = nil) {
		queue.sync {
			lock.lock()
			let stale = due != nil && due != generation
			let m = stale ? nil : llm
			if !stale { llm = nil }
			if !stale, due != nil { unloadTimer = nil }
			lock.unlock()
			guard let m else { return }
			autoreleasepool { m.unload() }
			appLog.notice("model unloaded")
		}
	}
}
