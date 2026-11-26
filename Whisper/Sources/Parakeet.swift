import Foundation

final class Parakeet {
	private let pre: OrtSession
	private let enc: OrtSession
	private let decJoint: OrtSession
	private let vocab: [String]
	private let blank: Int
	private let maxTokensPerStep = 10

	init(dir: URL, preprocessor: URL, threads: Int = 4) throws {
		pre = try OrtSession(path: preprocessor.path, threads: 1)
		enc = try OrtSession(path: dir.appendingPathComponent("encoder-model.int8.onnx").path, threads: threads)
		decJoint = try OrtSession(path: dir.appendingPathComponent("decoder_joint-model.int8.onnx").path, threads: 1)
		let text = try String(contentsOf: dir.appendingPathComponent("vocab.txt"), encoding: .utf8)
		var map: [Int: String] = [:]
		for line in text.split(separator: "\n") {
			guard let space = line.lastIndex(of: " "), let id = Int(line[line.index(after: space)...]) else { continue }
			map[id] = String(line[..<space])
		}
		vocab = (0..<map.count).map { map[$0] ?? "" }
		blank = vocab.firstIndex(of: "<blk>") ?? vocab.count - 1
	}

	func transcribe(_ samples: [Float]) throws -> AsrResult {
		guard samples.count >= 1600 else { return AsrResult(text: "", tokens: []) }
		let n = Int64(samples.count)
		let f = try pre.run([.float("waveforms", samples, [1, n]), .int64("waveforms_lens", [n], [1])],
		                    outputs: ["features", "features_lens"])
		let e = try enc.run([.float("audio_signal", Array(f[0].floats), f[0].shape),
		                     .int64("length", [f[1].int64s[0]], [1])],
		                    outputs: ["outputs", "encoded_lengths"])
		let dim = Int(e[0].shape[1]), total = Int(e[0].shape[2])
		let frames = min(total, Int(e[1].int64s[0]))
		let encoded = e[0].floats
		var frame = [Float](repeating: 0, count: dim)
		var s1 = [Float](repeating: 0, count: 2 * 640), s2 = s1
		var tokens: [AsrToken] = []
		var last = blank
		var t = 0, emitted = 0
		while t < frames {
			for d in 0..<dim { frame[d] = encoded[d * total + t] }
			let o = try decJoint.run([.float("encoder_outputs", frame, [1, Int64(dim), 1]),
			                          .int32("targets", [Int32(last)], [1, 1]),
			                          .int32("target_length", [1], [1]),
			                          .float("input_states_1", s1, [2, 1, 640]),
			                          .float("input_states_2", s2, [2, 1, 640])],
			                         outputs: ["outputs", "output_states_1", "output_states_2"])
			let out = o[0].floats
			var token = 0
			var bestValue = -Float.infinity
			for i in 0..<vocab.count where out[i] > bestValue {
				bestValue = out[i]
				token = i
			}
			var step = 0
			bestValue = -Float.infinity
			for i in vocab.count..<out.count where out[i] > bestValue {
				bestValue = out[i]
				step = i - vocab.count
			}
			if token != blank {
				s1 = Array(o[1].floats)
				s2 = Array(o[2].floats)
				last = token
				tokens.append(AsrToken(text: vocab[token], frame: t))
				emitted += 1
			}
			if step > 0 {
				t += step
				emitted = 0
			} else if token == blank || emitted == maxTokensPerStep {
				t += 1
				emitted = 0
			}
		}
		return AsrResult(text: Detokenizer.join(tokens.map(\.text)), tokens: tokens)
	}
}
