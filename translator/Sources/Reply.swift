import Foundation
import NaturalLanguage

struct Query<Value> {
	var request: String
	var forced = ""
	var read: (String) -> Value?
	var preview: ((String) -> Value?)?
}

extension Query where Value == String {
	static func translation(_ source: String) -> Query {
		Query(request: Prompt.text(source), read: { nonEmpty(Reply.text($0, like: [source])) },
		      preview: { Reply.textPreview($0, like: [source]) })
	}

	static func restyle(_ source: String, style: Style, current: String) -> Query {
		Query(request: Prompt.restyle(source, style: style, current: current), read: { nonEmpty(Reply.text($0, like: [source, current])) })
	}

	static func edit(source: String, text: String, range: NSRange, with new: String) -> Query {
		let zone = Reply.zone(of: text, around: range)
		return Query(request: Prompt.edit(source: source, text: text, range: range, zone: zone, with: new),
		             forced: Reply.lead(of: text, before: zone.location), read: { nonEmpty(Reply.text($0, like: [text])) })
	}

	private static func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }
}

extension Query where Value == [CardLine] {
	static func word(_ source: String) -> Query {
		let target = Direction(of: source)
		return Query(request: Prompt.word(source), read: { raw in
		             	let lines = Reply.card(raw, to: target)
		             	return lines.isEmpty ? nil : lines
		             },
		             preview: { raw in
		             	let lines = Reply.card(raw, to: target, partial: true)
		             	return lines.isEmpty ? nil : lines
		             })
	}

	static func alternatives(source: String, text: String, range: NSRange) -> Query {
		let target = Direction(of: source)
		let current = (text as NSString).substring(with: range)
		return Query(request: Prompt.alternatives(source: source, text: text, range: range),
		             read: { Reply.card($0, to: target, excluding: current) })
	}
}

enum Reply {
	static func hasCyrillic(_ s: String) -> Bool { s.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } }

	static func words(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }

	static func same(_ a: String, _ b: String) -> Bool {
		let norm = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
		return norm(a) == norm(b)
	}

	private static func trimmed(_ s: some StringProtocol) -> String { s.trimmingCharacters(in: .whitespaces) }

	private static func nonEmptyLines(_ s: String) -> [String] {
		s.components(separatedBy: "\n").map { trimmed($0) }.filter { !$0.isEmpty }
	}

	private static let labels = [["translation:", "перевод:"], ["text:", "текст:"], ["result:", "результат:"], ["answer:", "ответ:"],
	                             ["rewritten:", "rewrite:", "new text:", "новый текст:"], ["new version:", "version:", "вариант:", "версия:"]]
	private static let fields = [["style:", "стиль:"], ["current:", "текущий:"], ["source:", "источник:"], ["original:", "оригинал:"],
	                             ["part:", "часть:"], ["text:", "текст:"], ["translation:", "перевод:"]]
	private static let tags = ["[text", "[word", "[edit", "[alt"]
	private static let noteStarts = ["note", "nb", "n.b.", "примечание", "пояснение", "объяснение", "комментарий", "explanation",
	                                 "comment", "(", "*", "†", "literally", "дословно", "p.s."]
	private static let leadInStarts = ["here", "sure", "of course", "certainly", "okay", "ok,", "translation", "перевод", "вот",
	                                   "конечно", "[", "```", "**"]
	private static let quotes: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("«", "»"), ("„", "“"), ("'", "'")]

	static func text(_ raw: String, like refs: [String]) -> String {
		let ref = refs.joined(separator: "\n")
		let refLines = refs.flatMap(nonEmptyLines).map { $0.lowercased() }
		let allowed = max(1, refs.map { nonEmptyLines($0).count }.max() ?? 1)
		func refStarts(_ prefix: String) -> Bool { refLines.contains { $0.hasPrefix(prefix) } }
		func foreignLabel(_ line: String, _ groups: [[String]]) -> String? {
			let l = line.lowercased()
			for group in groups {
				if let label = group.first(where: { l.hasPrefix($0) }) { return group.contains(where: refStarts) ? nil : label }
			}
			return nil
		}

		var t = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "⟦", with: "").replacingOccurrences(of: "⟧", with: "")
		if !ref.contains("**") { t = t.replacingOccurrences(of: "**", with: "") }
		var rows = t.components(separatedBy: "\n").filter { !trimmed($0).hasPrefix("```") }
		func trimBlankRows() {
			while let f = rows.first, trimmed(f).isEmpty { rows.removeFirst() }
			while let l = rows.last, trimmed(l).isEmpty { rows.removeLast() }
		}
		trimBlankRows()
		guard !rows.isEmpty else { return "" }

		var first = trimmed(rows[0])
		if first.hasPrefix("["), let close = first.firstIndex(of: "]"), tags.contains(where: { first.lowercased().hasPrefix($0) }),
		   !ref.contains(first[...close]) {
			first = trimmed(first[first.index(after: close)...])
		}
		if let label = foreignLabel(first, labels) { first = trimmed(first.dropFirst(label.count)) }
		rows[0] = first
		if rows.filter({ !trimmed($0).isEmpty }).count > allowed {
			rows.removeAll { foreignLabel(trimmed($0), fields) != nil }
		}
		trimBlankRows()
		if rows.count > 1, trimmed(rows[0]).hasSuffix(":"), !refLines.contains(where: { $0.hasSuffix(":") }) {
			rows.removeFirst()
			trimBlankRows()
		}
		let content = rows.indices.filter { !trimmed(rows[$0]).isEmpty }
		if content.count > allowed {
			let extra = trimmed(rows[content[allowed]]).lowercased()
			if noteStarts.contains(where: { extra.hasPrefix($0) }), !refStarts(String(extra.prefix(4))) {
				rows = Array(rows[..<content[allowed]])
			}
		}
		if !ref.contains("|"), rows.contains(where: { !trimmed($0).isEmpty }),
		   rows.allSatisfy({ trimmed($0).isEmpty || $0.contains(" | ") }) {
			rows = rows.map { row in row.range(of: " | ").map { String(row[..<$0.lowerBound]) } ?? row }
		}
		var result = rows.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
		if !ref.contains("("), result.hasSuffix(")"), let open = result.range(of: "(", options: .backwards) {
			let inside = result[open.upperBound...].lowercased()
			if ["note", "literally", "дословно", "примеч", "i.e.", "т.е.", "or ", "или "].contains(where: { inside.hasPrefix($0) }) {
				result = result[..<open.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
			}
		}
		let opening = Set(quotes.map(\.0))
		for (open, close) in quotes where result.count > 2 && result.first == open && result.last == close {
			let inner = result.dropFirst().dropLast()
			if !refs.contains(where: { trimmed($0).first.map(opening.contains) == true }), !inner.contains(open), !inner.contains(close) {
				result = inner.trimmingCharacters(in: .whitespacesAndNewlines)
			}
			break
		}
		return result
	}

	static func textPreview(_ raw: String, like refs: [String]) -> String? {
		var rows = raw.components(separatedBy: "\n")
		let allowed = max(1, refs.map { nonEmptyLines($0).count }.max() ?? 1)
		let refFirst = refs.compactMap { nonEmptyLines($0).first?.lowercased() }
		if rows.count == 1 {
			let l = trimmed(rows[0]).lowercased()
			if leadInStarts.contains(where: { l.hasPrefix($0) }) && !refFirst.contains(where: { $0.hasPrefix(String(l.prefix(4))) }) {
				return nil
			}
		} else if trimmed(rows[0]).hasSuffix(":") && !refFirst.contains(where: { $0.hasSuffix(":") }) {
			rows.removeFirst()
		}
		var kept: [String] = []
		var count = 0
		for row in rows {
			if !trimmed(row).isEmpty {
				if count == allowed { break }
				count += 1
			}
			kept.append(row)
		}
		var text = kept.joined(separator: "\n")
		if let q = quotes.first(where: { text.first == $0.0 }), !refs.contains(where: { trimmed($0).first == q.0 }), text.dropFirst().last != q.1 {
			text.removeFirst()
		}
		let shown = Reply.text(text, like: refs)
		return shown.isEmpty ? nil : shown
	}

	static func card(_ raw: String, to target: Direction?, excluding current: String? = nil, partial: Bool = false) -> [CardLine] {
		let rows = raw.components(separatedBy: "\n")
		func parse(_ target: Direction?) -> [CardLine] {
			var lines: [CardLine] = []
			for (i, row) in rows.enumerated() {
				let line = dropListMarker(trimmed(row).replacingOccurrences(of: "**", with: ""))
				guard !line.isEmpty, !line.hasPrefix("["), !line.hasSuffix(":") else { continue }
				let parts = line.split(separator: "|", maxSplits: 1).map { trimmed($0) }
				var term = parts.first ?? ""
				var note = parts.count > 1 ? parts[1] : ""
				if parts.count < 2 {
					if partial && i == rows.count - 1 { continue }
					guard words(term) <= 6, !".!?".contains(term.last ?? " ") else { continue }
				}
				for (open, close) in quotes where term.count > 2 && term.first == open && term.last == close {
					term = String(term.dropFirst().dropLast())
					break
				}
				guard !term.isEmpty else { continue }
				if let target, (target == .toEnglish) == hasCyrillic(term) { continue }
				if !note.isEmpty, !hasCyrillic(note) { note = "" }
				if let current, term.lowercased() == current.lowercased() { continue }
				if let k = lines.firstIndex(where: { $0.term.lowercased() == term.lowercased() }) {
					if !note.isEmpty, !lines[k].note.contains(note) { lines[k].note = lines[k].note.isEmpty ? note : lines[k].note + "; " + note }
				} else {
					lines.append(CardLine(term: term, note: note))
				}
			}
			return lines
		}
		let lines = parse(target)
		guard lines.isEmpty, target != nil, !partial, current == nil else { return lines }
		let any = parse(nil)
		return any.isEmpty ? nonEmptyLines(raw).prefix(1).map { CardLine(term: $0, note: "") } : any
	}

	private static func dropListMarker(_ line: String) -> String {
		for bullet in ["- ", "• ", "* ", "– "] where line.hasPrefix(bullet) { return String(line.dropFirst(bullet.count)) }
		let digits = line.prefix(while: \.isNumber)
		guard !digits.isEmpty, digits.count <= 2 else { return line }
		let rest = line.dropFirst(digits.count)
		return rest.hasPrefix(". ") || rest.hasPrefix(") ") ? String(rest.dropFirst(2)) : line
	}

	static func cardText(_ lines: [CardLine]) -> String {
		lines.map { $0.note.isEmpty ? $0.term : "\($0.term) | \($0.note)" }.joined(separator: "\n")
	}

	static func lead(of text: String, before location: Int) -> String {
		let ns = text as NSString
		var i = min(location, ns.length)
		while i > 0 {
			let c = ns.character(at: i - 1)
			if c == 0x0A { break }
			if i >= 2, c == 0x20, let p = UnicodeScalar(ns.character(at: i - 2)), ".!?…".unicodeScalars.contains(p) { break }
			i -= 1
		}
		var lead = ns.substring(to: i)
		while let last = lead.last, last.isWhitespace { lead.removeLast() }
		return lead
	}

	private static let agreeing: Set<String> = ["a", "an", "the", "this", "that", "these", "those", "many", "much", "few", "little",
		"several", "each", "every", "both", "another", "some", "any", "no", "all", "lot", "lots", "of", "couple", "plenty", "there",
		"is", "are", "was", "were", "am", "be", "been", "has", "have", "had", "do", "does", "did", "there's", "that's", "it's", "here's",
		"этот", "эта", "это", "эти", "этого", "этой", "этому", "этих", "эту", "тот", "та", "то", "те", "того", "той", "тех", "ту",
		"такой", "такая", "такое", "такие", "мой", "моя", "моё", "мое", "мои", "твой", "твоя", "твоё", "твое", "твои",
		"наш", "наша", "наше", "наши", "ваш", "ваша", "ваше", "ваши", "свой", "своя", "своё", "свое", "свои",
		"весь", "вся", "всё", "все", "каждый", "каждая", "каждое", "каждые", "один", "одна", "одно", "одни", "два", "две", "три", "четыре"]

	static func zone(of text: String, around range: NSRange) -> NSRange {
		let ns = text as NSString
		let words = wordRanges(text)
		guard let first = words.firstIndex(where: { NSIntersectionRange($0, range).length > 0 || $0.location >= range.location }) else { return range }
		let tagger = NLTagger(tagSchemes: [.lexicalClass])
		tagger.string = text
		let russian = hasCyrillic(ns.substring(with: range))
		if russian { tagger.setLanguage(.russian, range: text.startIndex..<text.endIndex) }
		var start = first, zoneStart = first
		while start > 0, first - start < 4 {
			let prev = words[start - 1]
			let gap = ns.substring(with: NSRange(location: NSMaxRange(prev), length: words[start].location - NSMaxRange(prev)))
			guard gap.allSatisfy(\.isWhitespace) else { break }
			let word = ns.substring(with: prev).lowercased().replacingOccurrences(of: "’", with: "'")
			let index = String.Index(utf16Offset: prev.location, in: text)
			let tag = tagger.tag(at: index, unit: .word, scheme: .lexicalClass).0
			if agreeing.contains(word) || tag == .determiner || tag == .number || (tag == .adjective && russian) {
				start -= 1
				zoneStart = start
			} else if tag == .adjective || tag == .adverb {
				start -= 1
			} else {
				break
			}
		}
		let begin = min(words[zoneStart].location, range.location)
		return NSRange(location: begin, length: NSMaxRange(range) - begin)
	}

	private static func wordRanges(_ s: String) -> [NSRange] {
		var out: [NSRange] = []
		let ns = s as NSString
		ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { _, r, _, _ in out.append(r) }
		return out
	}

	static func changedWords(old: String, new: String) -> [NSRange] {
		let a = wordRanges(old), b = wordRanges(new)
		let aw = a.map { (old as NSString).substring(with: $0).lowercased() }
		let bw = b.map { (new as NSString).substring(with: $0).lowercased() }
		var dp = [[Int]](repeating: [Int](repeating: 0, count: bw.count + 1), count: aw.count + 1)
		for i in stride(from: aw.count - 1, through: 0, by: -1) {
			for j in stride(from: bw.count - 1, through: 0, by: -1) {
				dp[i][j] = aw[i] == bw[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
			}
		}
		var kept = Set<Int>()
		var i = 0, j = 0
		while i < aw.count && j < bw.count {
			if aw[i] == bw[j] {
				kept.insert(j)
				i += 1
				j += 1
			} else if dp[i + 1][j] >= dp[i][j + 1] {
				i += 1
			} else {
				j += 1
			}
		}
		var marks: [NSRange] = []
		let ns = new as NSString
		for k in b.indices where !kept.contains(k) {
			if let last = marks.last {
				let gap = ns.substring(with: NSRange(location: NSMaxRange(last), length: b[k].location - NSMaxRange(last)))
				if gap.allSatisfy(\.isWhitespace) {
					marks[marks.count - 1] = NSRange(location: last.location, length: NSMaxRange(b[k]) - last.location)
					continue
				}
			}
			marks.append(b[k])
		}
		return marks
	}
}

extension Result {
	var failureValue: Failure? {
		if case let .failure(e) = self { return e }
		return nil
	}
}
