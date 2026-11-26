import Accelerate
import Foundation
import llama

struct LLMError: Error, CustomStringConvertible {
	let description: String
}

struct TextTooLong: Error, CustomStringConvertible {
	var description: String { "The text is too long for the model — split it into parts" }
}

final class CancelToken: @unchecked Sendable {
	private let lock = NSLock()
	private var flag = false
	var isCancelled: Bool {
		lock.lock()
		defer { lock.unlock() }
		return flag
	}
	func cancel() {
		lock.lock()
		flag = true
		lock.unlock()
	}
}

final class LocalLLM {
	struct Template {
		var prefix: String
		var suffix: String
		var stops: [String]
	}

	private var model: OpaquePointer?
	private var ctx: OpaquePointer?
	private var vocab: OpaquePointer?
	private var prefixCount: Int32 = 0
	private var template = Template(prefix: "", suffix: "", stops: [])
	let path: String
	private let format: (String) throws -> Template
	private static var backendReady = false
	static let contextSize = 6144

	init(path: String, format: @escaping (String) throws -> Template) {
		self.path = path
		self.format = format
	}

	deinit { unload() }

	var isLoaded: Bool { ctx != nil }
	private(set) var loadTimes = ""

	private func cachePath(for prefix: String) -> String {
		var hash: UInt64 = 0xcbf29ce484222325
		for byte in prefix.utf8 {
			hash ^= UInt64(byte)
			hash = hash &* 0x100000001b3
		}
		let name = (path as NSString).lastPathComponent
		return AppPaths.data.appendingPathComponent("\(name).\(String(hash, radix: 16)).kv").path
	}

	func load() throws {
		guard ctx == nil else { return }
		if !Self.backendReady {
			setenv("GGML_METAL_NO_RESIDENCY", "1", 0)
			llama_log_set({ level, text, _ in
				if level == GGML_LOG_LEVEL_ERROR, let text { fputs(String(cString: text), stderr) }
			}, nil)
			llama_backend_init()
			Self.backendReady = true
		}
		let started = ProcessInfo.processInfo.systemUptime
		var mp = llama_model_default_params()
		mp.n_gpu_layers = 999
		guard let m = llama_model_load_from_file(path, mp) else { throw LLMError(description: "couldn't load \(path)") }
		var arch = [CChar](repeating: 0, count: 64)
		_ = llama_model_meta_val_str(m, "general.architecture", &arch, arch.count)
		do { template = try format(String(cString: arch)) } catch {
			llama_model_free(m)
			throw error
		}
		var cp = llama_context_default_params()
		cp.n_ctx = UInt32(Self.contextSize)
		cp.n_batch = 2048
		cp.n_ubatch = 512
		cp.n_seq_max = 1
		cp.swa_full = true
		let cores = ProcessInfo.processInfo.activeProcessorCount
		cp.n_threads = Int32(max(2, min(6, cores / 2)))
		cp.n_threads_batch = cp.n_threads
		cp.no_perf = true
		let weights = ProcessInfo.processInfo.systemUptime
		guard let c = llama_init_from_model(m, cp) else {
			llama_model_free(m)
			throw LLMError(description: "couldn't create the context")
		}
		let context = ProcessInfo.processInfo.systemUptime
		model = m
		ctx = c
		vocab = llama_model_get_vocab(m)
		let tokens = tokenize(template.prefix, addSpecial: true, parseSpecial: true)
		let cache = cachePath(for: template.prefix)
		let restored = restorePrefix(tokens, from: cache)
		if !restored {
			do {
				try decode(tokens, startPos: 0, wantLogits: false)
				llama_synchronize(c)
			} catch {
				unload()
				throw error
			}
			AppPaths.ensureData()
			Self.removeCaches(of: path, keeping: cache)
			_ = llama_state_seq_save_file(c, cache, 0, tokens, tokens.count)
		}
		prefixCount = Int32(tokens.count)
		loadTimes = String(format: "weights %.2f s, context %.2f s, prompt %@ %.2f s", weights - started, context - weights,
		                   restored ? "restored in" : "computed in", ProcessInfo.processInfo.systemUptime - context)
	}

	private func restorePrefix(_ tokens: [llama_token], from file: String) -> Bool {
		guard FileManager.default.fileExists(atPath: file) else { return false }
		var saved = [llama_token](repeating: 0, count: tokens.count + 1)
		var n = 0
		if llama_state_seq_load_file(ctx, file, 0, &saved, saved.count, &n) > 0, n == tokens.count,
		   saved.prefix(n).elementsEqual(tokens) {
			return true
		}
		llama_memory_clear(llama_get_memory(ctx), true)
		return false
	}

	static func removeCaches(of modelPath: String, keeping keep: String? = nil) {
		for file in caches(of: modelPath) where file != keep { try? FileManager.default.removeItem(atPath: file) }
	}

	static func caches(of modelPath: String) -> [String] {
		let name = (modelPath as NSString).lastPathComponent
		let files = (try? FileManager.default.contentsOfDirectory(atPath: AppPaths.data.path)) ?? []
		return files.filter { $0.hasPrefix(name + ".") && $0.hasSuffix(".kv") }.map { AppPaths.data.appendingPathComponent($0).path }
	}

	func unload() {
		if let ctx { llama_free(ctx) }
		if let model { llama_model_free(model) }
		ctx = nil
		model = nil
		vocab = nil
		prefixCount = 0
	}

	private func tokenize(_ text: String, addSpecial: Bool = false, parseSpecial: Bool) -> [llama_token] {
		let utf8 = Array(text.utf8CString)
		var tokens = [llama_token](repeating: 0, count: utf8.count + 16)
		var n = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &tokens, Int32(tokens.count), addSpecial, parseSpecial)
		if n < 0 {
			tokens = [llama_token](repeating: 0, count: Int(-n))
			n = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &tokens, Int32(tokens.count), addSpecial, parseSpecial)
		}
		return Array(tokens.prefix(Int(max(0, n))))
	}

	private func piece(_ token: llama_token, special: Bool = false) -> [UInt8] {
		var buf = [CChar](repeating: 0, count: 64)
		var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, special)
		if n < 0 {
			buf = [CChar](repeating: 0, count: Int(-n))
			n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, special)
		}
		return buf.prefix(Int(max(0, n))).map { UInt8(bitPattern: $0) }
	}

	private func decode(_ tokens: [llama_token], startPos: Int32, wantLogits: Bool) throws {
		var pos = startPos
		var i = 0
		while i < tokens.count {
			let n = min(2048, tokens.count - i)
			var batch = llama_batch_init(Int32(n), 0, 1)
			defer { llama_batch_free(batch) }
			for k in 0..<n {
				batch.token[k] = tokens[i + k]
				batch.pos[k] = pos + Int32(k)
				batch.n_seq_id[k] = 1
				batch.seq_id[k]![0] = 0
				batch.logits[k] = wantLogits && i + k == tokens.count - 1 ? 1 : 0
			}
			batch.n_tokens = Int32(n)
			let rc = llama_decode(ctx, batch)
			guard rc == 0 else { throw LLMError(description: "llama_decode: \(rc)") }
			pos += Int32(n)
			i += n
		}
	}

	private func best() throws -> llama_token {
		guard let logits = llama_get_logits_ith(ctx, -1) else { throw LLMError(description: "no logits") }
		var value: Float = 0
		var index: vDSP_Length = 0
		vDSP_maxvi(logits, 1, &value, &index, vDSP_Length(llama_vocab_n_tokens(vocab)))
		return llama_token(index)
	}

	private func isStop(_ token: llama_token) -> Bool {
		llama_vocab_is_eog(vocab, token)
			|| template.stops.contains(String(decoding: piece(token, special: true), as: UTF8.self))
	}

	func complete(_ user: String, forced: String = "", maxTokens: Int = 600, cancel: CancelToken? = nil,
	              onText: ((String) -> Void)? = nil) throws -> String {
		guard let ctx, vocab != nil else { throw LLMError(description: "the model isn't loaded") }
		llama_memory_seq_rm(llama_get_memory(ctx), 0, prefixCount, -1)
		let prompt = tokenize(user, parseSpecial: false) + tokenize(template.suffix, parseSpecial: true) + tokenize(forced, parseSpecial: false)
		let room = Self.contextSize - Int(prefixCount) - prompt.count
		guard room > max(16, prompt.count / 2) else { throw TextTooLong() }
		if cancel?.isCancelled == true { return forced }
		try decode(prompt, startPos: prefixCount, wantLogits: true)
		var pos = prefixCount + Int32(prompt.count)
		var out = Array(forced.utf8)
		var shown = 0
		var ended = false
		for _ in 0..<min(maxTokens, room) {
			let next = try best()
			if isStop(next) {
				ended = true
				break
			}
			out.append(contentsOf: piece(next))
			if let onText, Self.completeLength(out) > shown {
				shown = Self.completeLength(out)
				onText(Self.clean(String(decoding: out.prefix(shown), as: UTF8.self), stops: template.stops))
			}
			if cancel?.isCancelled == true {
				ended = true
				break
			}
			try decode([next], startPos: pos, wantLogits: true)
			pos += 1
		}
		if !ended {
			if room <= maxTokens { throw TextTooLong() }
			appLog.info("the answer ran into its limit of \(maxTokens) tokens")
		}
		return Self.clean(String(decoding: out, as: UTF8.self), stops: template.stops)
	}

	static func completeLength(_ bytes: [UInt8]) -> Int {
		var i = bytes.count
		var back = 0
		while i > 0 && back < 4 {
			let b = bytes[i - 1]
			if b & 0x80 == 0 { return i }
			if b & 0xC0 == 0xC0 {
				let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : 2
				return back + 1 >= need ? i + back : i - 1
			}
			i -= 1
			back += 1
		}
		return i
	}

	private static func clean(_ text: String, stops: [String]) -> String {
		var t = text
		for stop in stops {
			if let r = t.range(of: stop) { t = String(t[..<r.lowerBound]) }
		}
		return t
	}
}
