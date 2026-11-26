import Foundation
import os

let appLog = Logger(subsystem: "com.ilya.diktovka", category: "whisper")

enum ModelFiles {
	static let root = AppPaths.models
	static let giga = root.appendingPathComponent("gigaam-v3")
	static let parakeet = root.appendingPathComponent("parakeet-v3")
	static let vad = root.appendingPathComponent("silero_vad.onnx")

	static var llm: URL? {
		if let path = ProcessInfo.processInfo.environment["WHISPER_LLM"] { return URL(fileURLWithPath: path) }
		let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
		return names.filter { $0.hasSuffix(".gguf") }.sorted().first.map { root.appendingPathComponent($0) }
	}

	static var ready: Bool {
		[giga.appendingPathComponent("v3_e2e_rnnt_encoder.onnx"), vad].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
	}

	static func bundled(_ name: String) -> URL? {
		Bundle.main.url(forResource: name, withExtension: "onnx")
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

final class Engine {
	let asrQueue = DispatchQueue(label: "whisper.asr", qos: .userInitiated)
	private let hintQueue = DispatchQueue(label: "whisper.hint", qos: .userInitiated)
	let llmQueue = DispatchQueue(label: "whisper.llm", qos: .userInitiated)
	private let lock = NSLock()
	private var giga: GigaAM?
	private var parakeet: Parakeet?
	private var llm: LocalLLM?
	private var vadModel: SileroVAD?
	private let vadLock = NSLock()
	private var generation = 0
	private var unloadTimer: DispatchSourceTimer?
	let speller = Speller()

	var useHints = true
	var useLLM = true
	var idleUnload: TimeInterval = 5 * 60
	var verbose = ProcessInfo.processInfo.environment["WHISPER_VERBOSE"] != nil
	var log: (String) -> Void = { _ in }

	func prepare() {
		cancelUnload()
		let hints = useHints, llm = useLLM
		asrQueue.async { [self] in
			_ = loadGiga()
			if hints { hintQueue.async { [self] in _ = loadParakeet() } }
			if llm { llmQueue.async { [self] in _ = loadLLM() } }
		}
	}

	private func loadGiga() -> GigaAM? {
		lock.lock()
		if let giga {
			lock.unlock()
			return giga
		}
		lock.unlock()
		do {
			let t = Date()
			guard let pre = ModelFiles.bundled("gigaam_v3") else { throw OrtError(description: "нет gigaam_v3.onnx") }
			let g = try GigaAM(dir: ModelFiles.giga, preprocessor: pre, threads: 6)
			log(String(format: "GigaAM загружен за %.2f с", Date().timeIntervalSince(t)))
			lock.lock()
			giga = g
			lock.unlock()
			return g
		} catch {
			log("GigaAM: \(error)")
			return nil
		}
	}

	private func loadParakeet() -> Parakeet? {
		lock.lock()
		if let parakeet {
			lock.unlock()
			return parakeet
		}
		lock.unlock()
		do {
			let t = Date()
			guard let pre = ModelFiles.bundled("nemo128") else { throw OrtError(description: "нет nemo128.onnx") }
			let p = try Parakeet(dir: ModelFiles.parakeet, preprocessor: pre, threads: 3)
			log(String(format: "Parakeet загружен за %.2f с", Date().timeIntervalSince(t)))
			lock.lock()
			parakeet = p
			lock.unlock()
			return p
		} catch {
			log("Parakeet: \(error)")
			return nil
		}
	}

	private func loadLLM() -> LocalLLM? {
		if let llm, llm.isLoaded { return llm }
		guard let url = ModelFiles.llm else { return nil }
		let m = llm.flatMap { $0.path == url.path ? $0 : nil } ?? LocalLLM(path: url.path, format: CorrectionPrompt.template(for:))
		do {
			let t = Date()
			FileCache.warm([url.path, url.path + ".kv"])
			try autoreleasepool { try m.load() }
			log(String(format: "LLM загружена за %.2f с", Date().timeIntervalSince(t)))
			llm = m
			return m
		} catch {
			log("LLM: \(error)")
			return nil
		}
	}

	func vad() -> SileroVAD? {
		vadLock.lock()
		defer { vadLock.unlock() }
		if let vadModel { return vadModel }
		do {
			vadModel = try SileroVAD(path: ModelFiles.vad.path)
		} catch {
			log("VAD: \(error)")
		}
		return vadModel
	}

	func recognize(_ samples: [Float]) -> (text: String, hint: String?) {
		var hint: String?
		let group = DispatchGroup()
		if useHints {
			group.enter()
			hintQueue.async { [self] in
				hint = try? loadParakeet()?.transcribe(samples).text
				group.leave()
			}
		}
		let text = (try? loadGiga()?.transcribe(samples).text) ?? ""
		group.wait()
		if let hint, Self.isEnglish(hint, main: text) { return (hint, nil) }
		return (text, hint)
	}

	static func isEnglish(_ hint: String, main: String) -> Bool {
		hint.split(separator: " ").count >= 2 && TextMetrics.latinShare(hint) >= 0.8 && TextMetrics.latinShare(main) >= 0.5
	}

	func quickRecognize(_ samples: [Float]) -> AsrResult {
		(try? loadGiga()?.transcribe(samples)) ?? AsrResult(text: "", tokens: [])
	}

	func correct(_ input: String, hint: String?, terms: [String] = []) -> (String, [EditDecision]) {
		speller.extraWords = Set(terms.flatMap { $0.lowercased().split(separator: " ").map(String.init) })
		let text = TermMatcher.apply(input, isRussianWord: { [speller] in speller.isWord($0) })
		if verbose, text != input { log("terms: \(text)") }
		guard useLLM, !text.isEmpty, TextMetrics.latinShare(text) < 0.8, let llm = loadLLM() else { return (text, []) }
		do {
			let raw = try autoreleasepool {
				try llm.complete(CorrectionPrompt.user(text: text, hint: hint, terms: terms), maxTokens: 160,
				                 deadline: Date().addingTimeInterval(8))
			}
			let validator = EditValidator(speller: speller, userTerms: Set(terms.map { $0.lowercased() }))
			var result = validator.apply(raw, to: text, hint: hint)
			result.0 = TermMatcher.apply(result.0, isRussianWord: { [speller] in speller.isWord($0) })
			if verbose {
				log("LLM: \(raw.replacingOccurrences(of: "\n", with: " | "))")
				for d in result.1 { log("  \(d.accepted ? "+" : "-") \(d.edit.source) => \(d.edit.replacement) (\(d.reason))") }
			}
			return result
		} catch {
			log("LLM: \(error)")
			return (text, [])
		}
	}

	func scheduleUnload() {
		cancelUnload()
		lock.lock()
		let due = generation
		lock.unlock()
		let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
		t.schedule(deadline: .now() + idleUnload)
		t.setEventHandler { [weak self] in self?.unloadAll(onlyIf: due) }
		t.resume()
		unloadTimer = t
	}

	private func cancelUnload() {
		unloadTimer?.cancel()
		unloadTimer = nil
		lock.lock()
		generation += 1
		lock.unlock()
	}

	func unloadAll(onlyIf due: Int? = nil) {
		let drop = { [self] (release: () -> Void) in
			lock.lock()
			defer { lock.unlock() }
			if due == nil || due == generation { release() }
		}
		asrQueue.sync { drop { giga = nil } }
		hintQueue.sync { drop { parakeet = nil } }
		llmQueue.sync {
			lock.lock()
			let stale = due != nil && due != generation
			lock.unlock()
			guard !stale else { return }
			autoreleasepool {
				llm?.unload()
				llm = nil
			}
		}
		lock.lock()
		let done = due == nil || due == generation
		lock.unlock()
		guard done else { return }
		vadLock.lock()
		vadModel = nil
		vadLock.unlock()
		log("Модели выгружены из памяти")
	}
}
