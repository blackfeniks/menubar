import Foundation

struct AsrToken {
	let text: String
	let frame: Int
}

struct AsrResult {
	var text: String
	var tokens: [AsrToken]
}

enum Detokenizer {
	static func join(_ pieces: [String]) -> String {
		var s = pieces.joined().replacingOccurrences(of: "▁", with: " ")
		s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
		s = s.replacingOccurrences(of: #"\s+([,.!?…:;)\]»])"#, with: "$1", options: .regularExpression)
		s = s.replacingOccurrences(of: #"([(\[«])\s+"#, with: "$1", options: .regularExpression)
		return s.trimmingCharacters(in: .whitespaces)
	}
}

private func loadVocab(_ url: URL) throws -> [String] {
	let text = try String(contentsOf: url, encoding: .utf8)
	var vocab: [Int: String] = [:]
	for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
		guard let space = line.lastIndex(of: " "), let id = Int(line[line.index(after: space)...]) else { continue }
		vocab[id] = String(line[..<space])
	}
	return (0..<vocab.count).map { vocab[$0] ?? "" }
}

final class GigaAM {
	static let frameSeconds = 0.04
	private let pre: OrtSession
	private let enc: OrtSession
	private let dec: OrtSession
	private let joint: OrtSession
	private let vocab: [String]
	private let blank: Int
	private let maxTokensPerStep = 3
	private let predHidden = 320

	init(dir: URL, preprocessor: URL, threads: Int = 4) throws {
		pre = try OrtSession(path: preprocessor.path, threads: 1)
		enc = try OrtSession(path: dir.appendingPathComponent("v3_e2e_rnnt_encoder.onnx").path, threads: threads)
		dec = try OrtSession(path: dir.appendingPathComponent("v3_e2e_rnnt_decoder.onnx").path, threads: 1)
		joint = try OrtSession(path: dir.appendingPathComponent("v3_e2e_rnnt_joint.onnx").path, threads: 1)
		vocab = try loadVocab(dir.appendingPathComponent("v3_e2e_rnnt_vocab.txt"))
		blank = vocab.firstIndex(of: "<blk>") ?? vocab.count - 1
	}

	func transcribe(_ samples: [Float]) throws -> AsrResult {
		guard samples.count >= 1600 else { return AsrResult(text: "", tokens: []) }
		let n = Int64(samples.count)
		let f = try pre.run([.float("waveforms", samples, [1, n]), .int64("waveforms_lens", [n], [1])],
		                    outputs: ["features", "features_lens"])
		let feats = Array(f[0].floats), featLen = f[1].int64s[0]
		let e = try enc.run([.float("audio_signal", feats, f[0].shape), .int64("length", [featLen], [1])],
		                    outputs: ["encoded", "encoded_len"])
		let dim = Int(e[0].shape[1]), total = Int(e[0].shape[2])
		let frames = min(total, Int(e[1].int32s[0]))
		let encoded = e[0].floats
		var frame = [Float](repeating: 0, count: dim)

		var h = [Float](repeating: 0, count: predHidden), c = h
		var cached: (dec: [Float], h: [Float], c: [Float])?
		var tokens: [AsrToken] = []
		var last = blank
		var t = 0, emitted = 0
		while t < frames {
			for d in 0..<dim { frame[d] = encoded[d * total + t] }
			if cached == nil {
				let o = try dec.run([.int64("x", [Int64(last)], [1, 1]),
				                     .float("h.1", h, [1, 1, Int64(predHidden)]),
				                     .float("c.1", c, [1, 1, Int64(predHidden)])],
				                    outputs: ["dec", "h", "c"])
				cached = (Array(o[0].floats), Array(o[1].floats), Array(o[2].floats))
			}
			let j = try joint.run([.float("enc", frame, [1, Int64(dim), 1]),
			                       .float("dec", cached!.dec, [1, Int64(predHidden), 1])],
			                      outputs: ["joint"])
			let logits = j[0].floats
			var best = 0
			var bestValue = -Float.infinity
			for i in 0..<logits.count where logits[i] > bestValue {
				bestValue = logits[i]
				best = i
			}
			if best != blank {
				h = cached!.h
				c = cached!.c
				cached = nil
				last = best
				tokens.append(AsrToken(text: vocab[best], frame: t))
				emitted += 1
			}
			if best == blank || emitted == maxTokensPerStep {
				t += 1
				emitted = 0
			}
		}
		return AsrResult(text: Detokenizer.join(tokens.map(\.text)), tokens: tokens)
	}
}
