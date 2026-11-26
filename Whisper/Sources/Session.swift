import Foundation

final class DictationSession: @unchecked Sendable {
	struct Segment {
		let start: Int
		let end: Int
		var text = ""
		var recognized = false
		var hint: String?
		var final: String?
		var provisional = ""
	}

	struct Tuning {
		var speechOn: Float = 0.5
		var speechOff: Float = 0.35
		var minCutPause = 0.55
		var softSegment = 18.0
		var hardSegment = 22.5
		var maxSegment = 24.5
		var padBefore = 0.4, padAfter = 0.5
		var previewInterval = 1.6
	}

	struct Preview: Equatable {
		var committed = ""
		var draft = ""
		var text: String { [committed, draft].filter { !$0.isEmpty }.joined(separator: " ") }
	}

	typealias Recognize = ([Float]) -> (text: String, hint: String?)

	static let rate = 16000
	private let frame = SileroVAD.frameSize
	let tuning: Tuning
	private let speechProbability: ((ArraySlice<Float>) -> Float)?
	private let asrQueue: DispatchQueue
	private let recognize: Recognize
	private let quickRecognize: ([Float]) -> AsrResult
	private let correct: ((String, String?) -> String)?
	private let correctQueue: DispatchQueue?

	private(set) var audio: [Float] = []
	private var probs: [Float] = []
	private var inSpeech = false
	private var segStart = 0
	private var silenceRun = 0
	private var bestPause: (mid: Int, length: Int)?
	private(set) var speechFrames = 0
	private var lastPreviewAt = 0

	private let lock = NSLock()
	private var segments: [Segment] = []
	private var openPreview: [(piece: String, at: Int)] = []
	private var generation = 0
	private var previewBusy = false
	private var previewCost: TimeInterval = 0
	private var finishing = false
	private var cancelled = false
	private let asrPending = DispatchGroup()
	private let correctionPending = DispatchGroup()
	var correctionGrace: TimeInterval = 8

	var onPreview: ((Preview) -> Void)? {
		get { lock.withLock { _onPreview } }
		set { lock.withLock { _onPreview = newValue } }
	}
	var onSegment: ((Segment) -> Void)? {
		get { lock.withLock { _onSegment } }
		set { lock.withLock { _onSegment = newValue } }
	}
	private var _onPreview: ((Preview) -> Void)?
	private var _onSegment: ((Segment) -> Void)?

	private func dropCallbacks() {
		lock.lock()
		_onPreview = nil
		_onSegment = nil
		lock.unlock()
	}

	init(speechProbability: ((ArraySlice<Float>) -> Float)?, tuning: Tuning = Tuning(), asrQueue: DispatchQueue,
	     recognize: @escaping Recognize, quickRecognize: @escaping ([Float]) -> AsrResult,
	     correct: ((String, String?) -> String)? = nil, correctQueue: DispatchQueue? = nil) {
		self.speechProbability = speechProbability
		self.tuning = tuning
		self.asrQueue = asrQueue
		self.recognize = recognize
		self.quickRecognize = quickRecognize
		self.correct = correct
		self.correctQueue = correctQueue
	}

	convenience init(vad: @escaping () -> SileroVAD?, tuning: Tuning = Tuning(), asrQueue: DispatchQueue,
	                 recognize: @escaping Recognize, quickRecognize: @escaping ([Float]) -> AsrResult,
	                 correct: ((String, String?) -> String)? = nil, correctQueue: DispatchQueue? = nil) {
		var detector: SileroVAD?
		var ready = false
		self.init(speechProbability: { frame in
			if !ready {
				detector = vad()
				detector?.reset()
				ready = true
			}
			guard let detector else { return 1 }
			return (try? detector.probability(frame)) ?? 1
		}, tuning: tuning, asrQueue: asrQueue, recognize: recognize, quickRecognize: quickRecognize,
		          correct: correct, correctQueue: correctQueue)
	}

	var duration: Double { Double(audio.count) / Double(Self.rate) }
	var speechSeconds: Double { Double(speechFrames * frame) / Double(Self.rate) }

	var heardSpeech: Bool {
		lock.lock()
		defer { lock.unlock() }
		return spoke
	}
	private var spoke = false

	func append(_ samples: [Float]) {
		audio.append(contentsOf: samples)
		while (probs.count + 1) * frame <= audio.count {
			let i = probs.count
			let p = speechProbability?(audio[(i * frame)..<((i + 1) * frame)]) ?? 1
			probs.append(p)
			step(frameIndex: i, prob: p)
		}
		maybePreview()
	}

	private func seconds(_ frames: Int) -> Double { Double(frames * frame) / Double(Self.rate) }

	private func step(frameIndex i: Int, prob p: Float) {
		if inSpeech {
			if p < tuning.speechOff { inSpeech = false }
		} else if p >= tuning.speechOn {
			inSpeech = true
		}
		if inSpeech {
			speechFrames += 1
			if speechFrames == 2 {
				lock.lock()
				spoke = true
				lock.unlock()
			}
			if silenceRun > 0, (i - silenceRun) * frame > segStart {
				let mid = (i - silenceRun / 2) * frame
				if bestPause == nil || silenceRun >= bestPause!.length { bestPause = (mid, silenceRun) }
			}
			silenceRun = 0
		} else {
			silenceRun += 1
		}
		let segLen = Double((i + 1) * frame - segStart) / Double(Self.rate)
		if !inSpeech && seconds(silenceRun) >= tuning.minCutPause && segLen >= tuning.softSegment {
			cut(at: (i + 1 - silenceRun / 2) * frame)
		} else if segLen >= tuning.hardSegment, let bp = bestPause, seconds(bp.length) >= 0.2 {
			cut(at: bp.mid)
		} else if segLen >= tuning.maxSegment {
			cut(at: (i + 1) * frame)
		}
	}

	private func cut(at sample: Int) {
		guard sample > segStart else { return }
		lock.lock()
		generation += 1
		let provisional: String
		(provisional, openPreview) = Self.split(openPreview, at: sample)
		lock.unlock()
		submit(start: segStart, end: sample, provisional: provisional)
		segStart = sample
		bestPause = nil
	}

	static func split(_ preview: [(piece: String, at: Int)], at sample: Int) -> (String, [(piece: String, at: Int)]) {
		let before = preview.prefix { $0.at < sample }
		let after = preview.dropFirst(before.count).drop { $0.piece.allSatisfy { ",.!?…:;▁".contains($0) } }
		return (Detokenizer.join(before.map(\.piece)), Array(after))
	}

	private func speechBounds(_ start: Int, _ end: Int) -> (Int, Int)? {
		let f0 = start / frame, f1 = min(probs.count, (end + frame - 1) / frame)
		guard f1 > f0 else { return nil }
		var first = -1, last = -1, voiced = 0
		for f in f0..<f1 {
			if probs[f] >= tuning.speechOff {
				if first < 0 { first = f }
				last = f
			}
			if probs[f] >= tuning.speechOn { voiced += 1 }
		}
		guard first >= 0, voiced >= 4 else { return nil }
		let s = max(start, first * frame - Int(tuning.padBefore * Double(Self.rate)))
		let e = min(end, (last + 1) * frame + Int(tuning.padAfter * Double(Self.rate)))
		return e > s ? (s, e) : nil
	}

	private func submit(start: Int, end: Int, provisional: String) {
		guard let (s, e) = speechBounds(start, end) else { return }
		let slice = Array(audio[s..<e])
		lock.lock()
		let index = segments.count
		segments.append(Segment(start: s, end: e, provisional: provisional))
		lock.unlock()
		asrPending.enter()
		asrQueue.async { [self] in
			defer { asrPending.leave() }
			guard !isCancelled else { return }
			let r = recognize(slice)
			lock.lock()
			segments[index].text = r.text
			segments[index].recognized = true
			segments[index].hint = r.hint
			let seg = segments[index]
			lock.unlock()
			onSegment?(seg)
			publishPreview()
			guard let correct, let correctQueue, !r.text.isEmpty else { return }
			correctionPending.enter()
			correctQueue.async { [self] in
				defer { correctionPending.leave() }
				guard !isCancelled else { return }
				let fixed = correct(r.text, r.hint)
				lock.lock()
				segments[index].final = fixed
				lock.unlock()
			}
		}
	}

	private var isCancelled: Bool {
		lock.lock()
		defer { lock.unlock() }
		return cancelled
	}

	private func maybePreview() {
		lock.lock()
		let interval = max(tuning.previewInterval, previewCost * 2.5)
		lock.unlock()
		guard onPreview != nil, audio.count - lastPreviewAt >= Int(interval * Double(Self.rate)),
		      inSpeech || silenceRun < 20 else { return }
		guard let (s, e) = speechBounds(segStart, audio.count), e - s > Self.rate / 2 else { return }
		lock.lock()
		let busy = previewBusy
		previewBusy = true
		let gen = generation
		lock.unlock()
		guard !busy else { return }
		lastPreviewAt = audio.count
		let slice = Array(audio[s..<e])
		asrQueue.async { [self] in
			lock.lock()
			let skip = cancelled || finishing
			lock.unlock()
			let t0 = Date()
			let r = skip ? AsrResult(text: "", tokens: []) : quickRecognize(slice)
			let frame = Int(GigaAM.frameSeconds * Double(Self.rate))
			lock.lock()
			if !skip { previewCost = Date().timeIntervalSince(t0) }
			if gen == generation, !skip { openPreview = r.tokens.map { ($0.text, s + $0.frame * frame) } }
			previewBusy = false
			lock.unlock()
			if !skip { publishPreview() }
		}
	}

	private func publishPreview() {
		lock.lock()
		let done = segments.prefix { $0.recognized }
		let pending = segments.dropFirst(done.count).map(\.provisional) + [Detokenizer.join(openPreview.map(\.piece))]
		let preview = Preview(committed: done.map(\.text).filter { !$0.isEmpty }.joined(separator: " "),
		                      draft: pending.filter { !$0.isEmpty }.joined(separator: " "))
		let callback = _onPreview
		lock.unlock()
		callback?(preview)
	}

	func breakHere() {
		cut(at: audio.count)
	}

	func finish() -> [Segment] {
		lock.lock()
		finishing = true
		lock.unlock()
		cut(at: audio.count)
		asrPending.wait()
		if correctionPending.wait(timeout: .now() + correctionGrace) == .timedOut {
			lock.lock()
			cancelled = true
			lock.unlock()
		}
		dropCallbacks()
		lock.lock()
		defer { lock.unlock() }
		return segments.filter { !$0.text.isEmpty }
	}

	func cancel() {
		lock.lock()
		cancelled = true
		_onPreview = nil
		_onSegment = nil
		lock.unlock()
	}
}
