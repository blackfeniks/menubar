import Foundation

enum TextPolish {
	static func join(_ parts: [String], isWord: (String) -> Bool = { _ in false }) -> String {
		var out = ""
		for part in parts.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !part.isEmpty {
			guard !out.isEmpty else {
				out = part
				continue
			}
			let end = out.last { !"»\")]'".contains($0) }
			out += " " + (end.map { ".!?…".contains($0) } == false ? lowercasedStart(part, isWord: isWord) : part)
		}
		return out
	}

	static func lowercasedStart(_ t: String, isWord: (String) -> Bool) -> String {
		let word = String(t.prefix { $0.isLetter })
		guard let first = word.first, first.isUppercase, word != "Я", TextMetrics.hasCyrillic(word) else { return t }
		if word.count > 1 && word == word.uppercased() { return t }
		let lower = word.lowercased()
		guard word.count == 1 || isWord(lower) else { return t }
		return lower + t.dropFirst(word.count)
	}

	private static let hesitation = try! NSRegularExpression(
		pattern: #"(?i)(?<![\p{L}\d-])(?:э{1,5}|э(?:-э)+м*|эм{1,3}|хм{1,3}|м{3,6}|м(?:-м)+|а{2,5}|а(?:-а)+|uh+m*|um+|erm)(?![\p{L}\d-]),?[ \t]*"#)

	static func finalize(_ text: String, dictionary: UserDictionary? = nil) -> String {
		let capitalized = text.trimmingCharacters(in: .whitespaces).first?.isUppercase ?? false
		var s = text
		s = hesitation.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
		s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
		s = s.replacingOccurrences(of: #" +([,.!?…:;)\]»])(?![\p{L}\d])"#, with: "$1", options: .regularExpression)
		s = s.replacingOccurrences(of: #",+([.!?…])"#, with: "$1", options: .regularExpression)
		s = s.replacingOccurrences(of: #"([(\[«]) +"#, with: "$1", options: .regularExpression)
		s = s.replacingOccurrences(of: #"([,;:])(?=[\p{L}])"#, with: "$1 ", options: .regularExpression)
		s = s.replacingOccurrences(of: #",{2,}"#, with: ",", options: .regularExpression)
		s = s.trimmingCharacters(in: .whitespacesAndNewlines)
		while let f = s.first, ",.;:".contains(f) { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
		if let dictionary { s = dictionary.apply(s) }
		if capitalized, let f = s.first, f.isLowercase, TextMetrics.hasCyrillic(String(f)) { s = f.uppercased() + s.dropFirst() }
		return s
	}
}

final class UserDictionary {
	struct Rule {
		let regex: NSRegularExpression
		let replacement: String
	}

	static let url = AppPaths.data.appendingPathComponent("Словарь.txt")

	private(set) var rules: [Rule] = []
	private(set) var terms: [String] = []
	private var loadedAt: Date?

	static let template = """
	# Словарь Whisper: свои замены после распознавания, по одной на строку.
	# Формат: как распознаётся => как писать. Регистр слева не важен, слово ищется целиком.
	# Правая часть ещё и подсказывает LLM, как пишутся твои термины.
	#
	# клод код => Claude Code
	# эл эм студио => LM Studio
	# гитхаб => GitHub
	"""

	func reloadIfChanged() {
		let fm = FileManager.default
		if !fm.fileExists(atPath: Self.url.path) {
			try? fm.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
			try? Self.template.write(to: Self.url, atomically: true, encoding: .utf8)
		}
		let modified = (try? fm.attributesOfItem(atPath: Self.url.path)[.modificationDate] as? Date) ?? nil
		guard modified != loadedAt, let text = try? String(contentsOf: Self.url, encoding: .utf8) else { return }
		loadedAt = modified
		parse(text)
	}

	func parse(_ text: String) {
		var rules: [Rule] = []
		var terms: [String] = []
		for line in text.split(whereSeparator: \.isNewline) {
			let l = line.trimmingCharacters(in: .whitespaces)
			guard !l.isEmpty, !l.hasPrefix("#") else { continue }
			let sep = l.contains("=>") ? "=>" : (l.contains("->") ? "->" : "→")
			let parts = l.components(separatedBy: sep)
			guard parts.count == 2 else { continue }
			let from = parts[0].trimmingCharacters(in: .whitespaces), to = parts[1].trimmingCharacters(in: .whitespaces)
			guard !from.isEmpty, !to.isEmpty else { continue }
			let pattern = "(?<![\\p{L}\\d])" + NSRegularExpression.escapedPattern(for: from)
				.replacingOccurrences(of: " ", with: "[\\s-]+") + "(?![\\p{L}\\d])"
			if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
				rules.append(Rule(regex: re, replacement: NSRegularExpression.escapedTemplate(for: to)))
				terms.append(to)
			}
		}
		self.rules = rules
		self.terms = Array(Set(terms)).sorted()
	}

	func apply(_ text: String) -> String {
		var s = text
		for r in rules {
			s = r.regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: r.replacement)
		}
		return s
	}
}
