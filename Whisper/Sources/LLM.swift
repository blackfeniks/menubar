import Accelerate
import Foundation
import llama

struct LLMError: Error, CustomStringConvertible {
	let description: String
}

final class LocalLLM {
	struct Template {
		var prefix: String
		var suffix: String
		var stops: [String] = []
	}

	private var model: OpaquePointer?
	private var ctx: OpaquePointer?
	private var vocab: OpaquePointer?
	private var prefixCount: Int32 = 0
	private var template = Template(prefix: "", suffix: "")
	let path: String
	private let format: (String) throws -> Template
	private static var backendReady = false
	private static let contextSize = 3072

	init(path: String, format: @escaping (String) throws -> Template) {
		self.path = path
		self.format = format
	}

	deinit { unload() }

	var isLoaded: Bool { ctx != nil }
	private var cachePath: String { path + ".kv" }

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
		var mp = llama_model_default_params()
		mp.n_gpu_layers = 999
		guard let m = llama_model_load_from_file(path, mp) else { throw LLMError(description: "не удалось загрузить \(path)") }
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
		guard let c = llama_init_from_model(m, cp) else {
			llama_model_free(m)
			throw LLMError(description: "не удалось создать контекст")
		}
		model = m
		ctx = c
		vocab = llama_model_get_vocab(m)
		let tokens = tokenize(template.prefix, addSpecial: true)
		if !restorePrefix(tokens) {
			do { try decode(tokens, startPos: 0, logits: .none) } catch {
				unload()
				throw error
			}
			_ = llama_state_seq_save_file(c, cachePath, 0, tokens, tokens.count)
		}
		prefixCount = Int32(tokens.count)
	}

	private func restorePrefix(_ tokens: [llama_token]) -> Bool {
		guard FileManager.default.fileExists(atPath: cachePath) else { return false }
		var saved = [llama_token](repeating: 0, count: tokens.count + 1)
		var n = 0
		if llama_state_seq_load_file(ctx, cachePath, 0, &saved, saved.count, &n) > 0, n == tokens.count,
		   saved.prefix(n).elementsEqual(tokens) {
			return true
		}
		llama_memory_clear(llama_get_memory(ctx), true)
		return false
	}

	func unload() {
		if let ctx { llama_free(ctx) }
		if let model { llama_model_free(model) }
		ctx = nil
		model = nil
		vocab = nil
		prefixCount = 0
	}

	private func tokenize(_ text: String, addSpecial: Bool) -> [llama_token] {
		let utf8 = Array(text.utf8CString)
		var tokens = [llama_token](repeating: 0, count: utf8.count + 16)
		var n = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &tokens, Int32(tokens.count), addSpecial, true)
		if n < 0 {
			tokens = [llama_token](repeating: 0, count: Int(-n))
			n = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &tokens, Int32(tokens.count), addSpecial, true)
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

	private enum Logits { case none, last }

	private func decode(_ tokens: [llama_token], startPos: Int32, logits: Logits) throws {
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
				batch.logits[k] = logits == .last && i + k == tokens.count - 1 ? 1 : 0
			}
			batch.n_tokens = Int32(n)
			let rc = llama_decode(ctx, batch)
			guard rc == 0 else { throw LLMError(description: "llama_decode: \(rc)") }
			pos += Int32(n)
			i += n
		}
	}

	private func best(_ row: Int32) throws -> llama_token {
		guard let logits = llama_get_logits_ith(ctx, row) else { throw LLMError(description: "нет логитов") }
		var value: Float = 0
		var index: vDSP_Length = 0
		vDSP_maxvi(logits, 1, &value, &index, vDSP_Length(llama_vocab_n_tokens(vocab)))
		return llama_token(index)
	}

	private func isStop(_ token: llama_token) -> Bool {
		llama_vocab_is_eog(vocab, token)
			|| !template.stops.isEmpty && template.stops.contains(String(decoding: piece(token, special: true), as: UTF8.self))
	}

	func complete(_ user: String, maxTokens: Int = 256, deadline: Date? = nil) throws -> String {
		guard let ctx, vocab != nil else { throw LLMError(description: "модель не загружена") }
		llama_memory_seq_rm(llama_get_memory(ctx), 0, prefixCount, -1)
		let prompt = tokenize(user + template.suffix, addSpecial: false)
		let room = Self.contextSize - Int(prefixCount) - prompt.count
		guard room > 8 else { throw LLMError(description: "запрос не помещается в контекст (\(prompt.count) токенов)") }
		let maxTokens = min(maxTokens, room)
		try decode(prompt, startPos: prefixCount, logits: .last)
		var pos = prefixCount + Int32(prompt.count)
		var out: [UInt8] = []
		var cut = false
		for _ in 0..<maxTokens {
			let next = try best(-1)
			if isStop(next) { break }
			out.append(contentsOf: piece(next))
			if let deadline, Date() > deadline {
				cut = true
				break
			}
			try decode([next], startPos: pos, logits: .last)
			pos += 1
		}
		var text = String(decoding: out, as: UTF8.self)
		for stop in template.stops {
			if let r = text.range(of: stop) { text = String(text[..<r.lowerBound]) }
		}
		if cut { text = text.range(of: "\n", options: .backwards).map { String(text[..<$0.lowerBound]) } ?? "" }
		return text
	}
}
