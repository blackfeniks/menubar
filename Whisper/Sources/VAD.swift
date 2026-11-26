import Foundation

final class SileroVAD {
	static let frameSize = 512
	private static let contextSize = 64
	private let session: OrtSession
	private var state = [Float](repeating: 0, count: 2 * 128)
	private var context = [Float](repeating: 0, count: SileroVAD.contextSize)

	init(path: String) throws {
		session = try OrtSession(path: path, threads: 1)
	}

	func reset() {
		state = [Float](repeating: 0, count: 2 * 128)
		context = [Float](repeating: 0, count: Self.contextSize)
	}

	func probability(_ frame: ArraySlice<Float>) throws -> Float {
		precondition(frame.count == Self.frameSize)
		let input = context + Array(frame)
		let o = try session.run([.float("input", input, [1, Int64(input.count)]),
		                         .float("state", state, [2, 1, 128]),
		                         .int64("sr", [16000], [])],
		                        outputs: ["output", "stateN"])
		state = Array(o[1].floats)
		context = Array(frame.suffix(Self.contextSize))
		return o[0].floats[0]
	}
}
