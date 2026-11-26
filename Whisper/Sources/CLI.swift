import AppKit

enum CLI {
	static func run(_ args: [String]) -> Int32? {
		guard let mode = args.dropFirst().first, mode.hasPrefix("--") else { return nil }
		let flags = Set(args)
		switch mode {
		case "--eval":
			guard args.count >= 4 else { return usage() }
			return eval(list: args[2], out: args[3], llm: !flags.contains("--no-llm"), hints: !flags.contains("--no-hints"))
		case "--simulate":
			guard args.count >= 3 else { return usage() }
			let speed = args.firstIndex(of: "--speed").flatMap { Double(args[$0 + 1]) } ?? 1
			return simulate(path: args[2], speed: speed, llm: !flags.contains("--no-llm"))
		case "--selftest":
			return SelfTest.run()
		case "--idle-check":
			guard args.count >= 3 else { return usage() }
			return idleCheck(path: args[2])
		case "--snapshot":
			guard args.count >= 3 else { return usage() }
			return MainActor.assumeIsolated { Snapshot.run(dir: args[2]) }
		default:
			return nil
		}
	}

	private static func usage() -> Int32 {
		print("usage: --eval LIST.tsv OUT.json [--no-llm] [--no-hints] | --simulate WAV [--speed X] | --selftest"
			+ " | --idle-check WAV | --snapshot DIR")
		return 2
	}

	private static func eval(list: String, out: String, llm: Bool, hints: Bool) -> Int32 {
		let engine = Engine()
		engine.useLLM = llm
		engine.useHints = hints
		engine.log = { print("·", $0) }
		guard let lines = try? String(contentsOfFile: list, encoding: .utf8) else { return usage() }
		var results: [[String: Any]] = []
		var asrTime = 0.0, llmTime = 0.0, audioTime = 0.0
		for line in lines.split(separator: "\n") {
			let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
			guard f.count >= 2 else { continue }
			let t0 = Date()
			let r: (text: String, hint: String?)
			if f.count >= 5 {
				r = (f[3], f[4].isEmpty ? nil : f[4])
			} else {
				guard let audio = try? readAudioFile(URL(fileURLWithPath: f[1])) else {
					print("! cannot read \(f[1])")
					continue
				}
				r = engine.asrQueue.sync { engine.recognize(audio) }
				audioTime += Double(audio.count) / 16000
			}
			let t1 = Date()
			let (fixed, decisions) = engine.llmQueue.sync { engine.correct(r.text, hint: r.hint) }
			let t2 = Date()
			let final = TextPolish.finalize(fixed)
			asrTime += t1.timeIntervalSince(t0)
			llmTime += t2.timeIntervalSince(t1)
			results.append(["id": f[0], "ref": f.count > 2 ? f[2] : "", "asr": r.text, "hint": r.hint ?? "",
			                "final": final, "asr_s": t1.timeIntervalSince(t0), "llm_s": t2.timeIntervalSince(t1),
			                "edits": decisions.map { ["src": $0.edit.source, "dst": $0.edit.replacement,
			                                          "ok": $0.accepted, "why": $0.reason] }])
			print("\(f[0])\t\(final)")
			for d in decisions { print("    \(d.accepted ? "+" : "-") \(d.edit.source) => \(d.edit.replacement)  (\(d.reason))") }
		}
		let summary: [String: Any] = ["files": results.count, "audio_s": audioTime, "asr_s": asrTime, "llm_s": llmTime]
		let json: [String: Any] = ["summary": summary, "results": results]
		if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
			try? data.write(to: URL(fileURLWithPath: out))
		}
		print(String(format: "files %d, audio %.1fs, ASR %.2fs, LLM %.2fs (%.2fs/file)", results.count, audioTime, asrTime,
		             llmTime, llmTime / Double(max(results.count, 1))))
		return 0
	}

	private static func simulate(path: String, speed: Double, llm: Bool) -> Int32 {
		guard let audio = try? readAudioFile(URL(fileURLWithPath: path)) else { return usage() }
		let engine = Engine()
		engine.useLLM = llm
		engine.log = { print(String(format: "[%6.2f] ·", Date().timeIntervalSince(start)), $0) }
		let processing = DispatchQueue(label: "sim.processing")
		engine.prepare()
		let session = DictationSession(vad: { engine.vad() }, asrQueue: engine.asrQueue,
		                               recognize: { engine.recognize($0) }, quickRecognize: { engine.quickRecognize($0) },
		                               correct: llm ? { engine.correct($0, hint: $1).0 } : nil, correctQueue: engine.llmQueue)
		var lastPreview = ""
		session.onPreview = { p in
			if p.text != lastPreview {
				lastPreview = p.text
				print(String(format: "[%6.2f] preview: %@", Date().timeIntervalSince(start), String(p.text.suffix(90))))
			}
		}
		session.onSegment = { seg in
			print(String(format: "[%6.2f] segment %.1f–%.1fs: %@", Date().timeIntervalSince(start),
			             Double(seg.start) / 16000, Double(seg.end) / 16000, seg.text))
		}
		var finished = false
		Thread.detachNewThread {
			let chunk = 1600
			var i = 0
			while i < audio.count {
				let slice = Array(audio[i..<min(audio.count, i + chunk)])
				processing.sync { session.append(slice) }
				i += chunk
				if speed > 0 { Thread.sleep(forTimeInterval: 0.1 / speed) }
			}
			let stopAt = Date()
			print(String(format: "[%6.2f] stop (audio %.1fs, speech %.1fs)", stopAt.timeIntervalSince(start), session.duration,
			             session.speechSeconds))
			let segments = session.finish()
			let final = TextPolish.finalize(TextPolish.join(segments.map { $0.final ?? $0.text }, isWord: engine.speller.isWord))
			let end = Date()
			let corrected = segments.filter { $0.final != nil }.count
			print(String(format: "stop→text %.2fs (%d segments, %d corrected)", end.timeIntervalSince(stopAt),
			             segments.count, corrected))
			print("FINAL: \(final)")
			DispatchQueue.main.async { finished = true }
		}
		while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
		return 0
	}

	private static let start = Date()

	static func footprint() -> (mb: Double, threads: Int) {
		var info = task_vm_info_data_t()
		var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
		let kr = withUnsafeMutablePointer(to: &info) {
			$0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
		}
		var threads: thread_act_array_t?
		var n: mach_msg_type_number_t = 0
		task_threads(mach_task_self_, &threads, &n)
		if let threads { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(Int(n) * MemoryLayout<thread_t>.stride)) }
		return (kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1e6 : -1, Int(n))
	}

	static func cpuSeconds() -> Double {
		var u = rusage()
		getrusage(RUSAGE_SELF, &u)
		return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
	}

	private static func idleCheck(path: String) -> Int32 {
		func report(_ what: String) {
			let f = footprint()
			print(String(format: "%-34@ memory %7.1f MB, threads %3d", what, f.mb, f.threads))
		}
		report("start")
		guard let audio = try? readAudioFile(URL(fileURLWithPath: path)) else { return usage() }
		let engine = Engine()
		engine.log = { print("·", $0) }
		let processing = DispatchQueue(label: "idle.processing")
		var leftOver: [() -> AnyObject?] = []
		for round in 1...2 {
			engine.prepare()
			let s = DictationSession(vad: { engine.vad() }, asrQueue: engine.asrQueue,
			                         recognize: { engine.recognize($0) }, quickRecognize: { engine.quickRecognize($0) },
			                         correct: { engine.correct($0, hint: $1).0 }, correctQueue: engine.llmQueue)
			s.onPreview = { _ in _ = ObjectIdentifier(s) }
			weak var gone = s
			leftOver.append { gone }
			var text: String?
			Thread.detachNewThread {
				var i = 0
				while i < audio.count {
					let slice = Array(audio[i..<min(audio.count, i + 1600)])
					processing.sync { s.append(slice) }
					i += 1600
				}
				let segments = s.finish()
				let joined = TextPolish.join(segments.map { $0.final ?? $0.text })
				DispatchQueue.main.async { text = joined }
			}
			while text == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
			print("text:", text ?? "")
			report("dictation \(round), models loaded")
			engine.unloadAll()
			RunLoop.main.run(until: Date().addingTimeInterval(1))
			report("dictation \(round), after unload")
		}
		let kept = leftOver.filter { $0() != nil }.count
		print(kept == 0 ? "finished dictations: all released" : "finished dictations: \(kept) STILL IN MEMORY")
		RunLoop.main.run(until: Date().addingTimeInterval(3))
		let c0 = cpuSeconds()
		let seconds = Double(ProcessInfo.processInfo.environment["IDLE_SECONDS"] ?? "10") ?? 10
		RunLoop.main.run(until: Date().addingTimeInterval(seconds))
		let c1 = cpuSeconds()
		report(String(format: "idle %.0f s later", seconds))
		print(String(format: "CPU used while idle: %.3f s", c1 - c0))
		return kept == 0 && c1 - c0 < 0.05 ? 0 : 1
	}
}
