import Foundation

enum CLI {
	static func run(_ args: [String]) -> Int32? {
		guard args.count > 1 else { return nil }
		switch args[1] {
		case "--selftest":
			return SelfTest.run()
		case "--idle-check":
			return idleCheck()
		case "--session-test":
			return MainActor.assumeIsolated { SessionTest.run() }
		case "--draft-check":
			return MainActor.assumeIsolated { DraftCheck.run() }
		case "--window-check":
			return MainActor.assumeIsolated { WindowCheck.run(args.count > 2 ? args[2] : nil) }
		case "--keys-check":
			let dir = NSTemporaryDirectory() + "translator-keys-check-\(getpid())"
			setenv("TRANSLATOR_DIR", dir, 1)
			unsetenv("TRANSLATOR_LLM")
			defer { try? FileManager.default.removeItem(atPath: dir) }
			return MainActor.assumeIsolated { KeysCheck.run() }
		case "--snapshot":
			guard args.count > 2 else { return usage() }
			return MainActor.assumeIsolated { Snapshot.run(args[2], only: args.count > 3 ? args[3] : nil) }
		case "--ask":
			guard args.count > 2 else { return usage() }
			var style = Style()
			if let i = args.firstIndex(of: "--style"), i + 1 < args.count { style = parseStyle(args[i + 1]) }
			return ask(args[2], style: style)
		case "--alt":
			guard args.count > 4 else { return usage() }
			let rest = Array(args.dropFirst(5))
			let n = rest.first.flatMap { Int($0) } ?? 1
			let new = rest.firstIndex(of: "--apply").flatMap { $0 + 1 < rest.count ? rest[$0 + 1] : nil }
			return alternatives(source: args[2], translation: args[3], part: args[4], occurrence: n, apply: new)
		case "--reopen":
			MainActor.assumeIsolated { AppDelegate.reopenText = args.count > 2 ? args[2] : "" }
			return nil
		case "--live":
			guard args.count > 3 else { return usage() }
			MainActor.assumeIsolated {
				LiveTest.dir = args[2]
				LiveTest.scenarios = Array(args[3...])
			}
			return nil
		case "--raw":
			guard args.count > 2, let file = try? String(contentsOfFile: args[2], encoding: .utf8) else { return usage() }
			for block in file.components(separatedBy: "\n===\n") {
				var lines = block.components(separatedBy: "\n")
				var forced = ""
				if let i = lines.firstIndex(where: { $0.hasPrefix("FORCED: ") }) { forced = String(lines.remove(at: i).dropFirst(8)) }
				let request = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
				guard !request.isEmpty else { continue }
				let answer = (try? Engine.shared.runSync(request, forced: forced)) ?? "<error>"
				print("### " + request.replacingOccurrences(of: "\n", with: " ⏎ ") + (forced.isEmpty ? "" : "  [forced: \(forced)]"))
				print(answer.replacingOccurrences(of: "\n", with: " ⏎ "))
			}
			return 0
		default:
			return args[1].hasPrefix("--") ? usage() : nil
		}
	}

	private static func idleCheck() -> Int32 {
		func footprint() -> Double {
			var info = task_vm_info_data_t()
			var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
			let kr = withUnsafeMutablePointer(to: &info) {
				$0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
			}
			return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
		}
		func cpu() -> Double {
			var u = rusage()
			getrusage(RUSAGE_SELF, &u)
			return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
		}
		print(String(format: "start: %.0f MB", footprint()))
		_ = try? Engine.shared.runSync(Prompt.word("замок"))
		print(String(format: "model loaded, one request done: %.0f MB", footprint()))
		Engine.shared.unload()
		Thread.sleep(forTimeInterval: 3)
		let c0 = cpu()
		Thread.sleep(forTimeInterval: 10)
		let used = cpu() - c0
		print(String(format: "after unload: %.0f MB, CPU %.3f s over 10 s", footprint(), used))
		return used < 0.05 ? 0 : 1
	}

	private static func usage() -> Int32 {
		print("Translator --ask \"текст\" [--style simpler=2,casual=1,polite=1,shorter=1,request=…] | --alt ОРИГИНАЛ ПЕРЕВОД ЧАСТЬ [N] [--apply НОВОЕ] | --raw FILE | --selftest | --session-test | --draft-check | --snapshot DIR")
		return 2
	}

	private static func parseStyle(_ s: String) -> Style {
		var style = Style()
		for pair in s.split(separator: ",") {
			let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
			guard kv.count == 2 else { continue }
			let n = Int(kv[1]) ?? 0
			switch kv[0] {
			case "simpler": style.simpler = n
			case "casual": style.casual = n
			case "polite": style.polite = n
			case "shorter": style.shorter = n
			case "request": style.request = kv[1]
			default: break
			}
		}
		return style
	}

	private static func ask(_ input: String, style: Style) -> Int32 {
		let mode = Mode(of: input), direction = Direction(of: input)
		print("mode: \(mode), \(direction.label)")
		let load = Date()
		Engine.shared.prepare()
		Engine.shared.queue.sync {}
		print(String(format: "model ready in %.2f s", Date().timeIntervalSince(load)))
		switch mode {
		case .word:
			return timed("WORD", .word(input)) { $0.map { "  \($0.term) — \($0.note)" }.joined(separator: "\n") } == nil ? 1 : 0
		case .text:
			guard let plain = timed("TEXT", .translation(input), show: { "  " + $0 }) else { return 1 }
			if !style.isEmpty {
				guard let styled = timed("STYLE \(style.instruction(currentWords: Reply.words(plain), to: direction) ?? "")", .restyle(input, style: style, current: plain),
				                         show: { "  " + $0 }) else { return 1 }
				if Reply.same(styled, plain) { print("  (the same text: the window tries one level stronger, then says it is already as … as it gets)") }
			}
			return 0
		}
	}

	private static func alternatives(source: String, translation: String, part: String, occurrence: Int, apply new: String?) -> Int32 {
		let ns = translation as NSString
		var found: [NSRange] = []
		ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { w, r, _, _ in
			if w == part { found.append(r) }
		}
		if found.isEmpty, case let r = ns.range(of: part), r.location != NSNotFound { found = [r] }
		guard found.indices.contains(occurrence - 1) else {
			print("«\(part)» №\(occurrence) нет в переводе")
			return 2
		}
		let range = found[occurrence - 1]
		print("marked: " + ns.replacingCharacters(in: range, with: "⟦" + part + "⟧"))
		guard timed("ALT", .alternatives(source: source, text: translation, range: range), show: {
			$0.map { "  \($0.term) — \($0.note)" }.joined(separator: "\n")
		}) != nil else { return 1 }
		guard let new else { return 0 }
		print("edit place: " + ns.replacingCharacters(in: Reply.zone(of: translation, around: range), with: "⟦" + ns.substring(with: Reply.zone(of: translation, around: range)) + "⟧"))
		guard let edited = timed("EDIT → \(new)", .edit(source: source, text: translation, range: range, with: new), show: { "  " + $0 }) else { return 1 }
		let marks = Reply.changedWords(old: translation, new: edited).map { (edited as NSString).substring(with: $0) }
		print("  changed: \(marks)")
		return 0
	}

	private static func timed<Value>(_ label: String, _ q: Query<Value>, show: (Value) -> String) -> Value? {
		let start = Date()
		var first: TimeInterval?
		do {
			let (value, raw) = try Engine.shared.askSync(q) { _ in if first == nil { first = Date().timeIntervalSince(start) } }
			print(String(format: "%@: first text %.0f ms, total %.0f ms", label, (first ?? 0) * 1000, Date().timeIntervalSince(start) * 1000))
			let shown = value as? String ?? (value as? [CardLine]).map(Reply.cardText)
			if raw.trimmingCharacters(in: .whitespacesAndNewlines) != shown { print("  raw: " + raw.replacingOccurrences(of: "\n", with: " ⏎ ")) }
			print(show(value))
			return value
		} catch {
			print("\(label): \(error)")
			return nil
		}
	}
}
