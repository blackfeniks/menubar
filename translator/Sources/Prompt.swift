import Foundation

enum Direction: Equatable {
	case toEnglish, toRussian

	init(of text: String) {
		self = Reply.hasCyrillic(text) ? .toEnglish : .toRussian
	}

	var label: String { self == .toEnglish ? "RU → EN" : "EN → RU" }
}

enum Mode: Equatable {
	case word, text

	init(of raw: String) {
		let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		let words = text.split(whereSeparator: { $0.isWhitespace })
		if text.contains("\n") || words.count > 10 {
			self = .text
		} else if words.count <= 3 {
			self = .word
		} else {
			let lower = text.lowercased()
			let starters = Direction(of: text) == .toEnglish
				? ["когда ", "тот, кто", "та, кто", "те, кто", "то, что", "человек, который", "человек которы",
				   "как называется", "как сказать", "слово для", "слово, когда", "что-то вроде", "типа когда"]
				: ["when you ", "when someone ", "someone who ", "a person who ", "the word for ", "what do you call ", "how do you say ",
				   "something like "]
			self = starters.contains { lower.hasPrefix($0) } ? .word : .text
		}
	}
}

struct Style: Equatable, Codable {
	var simpler = 0, casual = 0, polite = 0, shorter = 0
	var request: String?

	static let maxLevel = 3
	static let shortest = 3

	var isEmpty: Bool { simpler == 0 && casual == 0 && polite == 0 && shorter == 0 && (request ?? "").isEmpty }

	func instruction(currentWords: Int, to target: Direction) -> String? {
		let russian = target == .toRussian
		var parts: [String] = []
		switch simpler {
		case 0: break
		case 1: parts.append("simpler: more common words, keep every bit of the meaning")
		case 2: parts.append(russian ? "much simpler: plain everyday Russian, short sentences, keep the meaning"
			: "much simpler: basic everyday English (B1 words), short sentences, keep the meaning")
		default: parts.append(russian ? "very simple: the plainest Russian words, very short sentences, keep the meaning"
			: "very simple: beginner English (A2 words), very short sentences, keep the meaning")
		}
		switch casual {
		case 0: break
		case 1: parts.append(russian ? "more casual: conversational, like texting a friend" : "more casual: conversational, contractions, like texting a friend")
		case 2: parts.append("very casual: relaxed, slang is welcome")
		default: parts.append(russian ? "heavy Russian slang" : "heavy American slang")
		}
		switch polite {
		case 0: break
		case 1: parts.append("more polite and courteous")
		case 2: parts.append("formal business tone")
		default: parts.append("very formal and official")
		}
		switch shorter {
		case 0: break
		case 1: parts.append("shorter: drop filler and repeated words but keep every point, at most \(max(3, currentWords * 3 / 4)) words")
		case 2: parts.append("much shorter: at most \(max(3, currentWords / 2)) words, keep the main point")
		default: parts.append("as short as possible: 2 to 5 words, keep the main point")
		}
		if let request, !request.isEmpty { parts.append(request) }
		return parts.isEmpty ? nil : parts.joined(separator: "; ")
	}
}

struct CardLine: Equatable, Hashable, Codable {
	var term: String
	var note: String
}

enum Prompt {
	static let system = """
	You are the engine of a Russian⇄English translator used by a Russian speaker who reads and writes American English at a B2–C1 level. Every request starts with a mode tag; for WORD, TEXT and EDIT the tag also names the target language. Answer in exactly the format of that mode, with nothing else around it.

	[WORD to English], [WORD to Russian] — a word, a short phrase, or a description of something.
	Give translations into the target language (English means American English), one per line:
	translation | note
	- 2 to 5 lines, the most common everyday translation first. Cover each distinct meaning; within one meaning, add a richer or more precise option when one exists.
	- The left side is ALWAYS in the target language. A misspelled input word is translated as the word that was meant. Every line has a different translation: meanings that translate the same way share one line, and the note lists them («от двери; к разгадке; клавиша»).
	- The note is Russian, 1–4 words, lowercase, no period, never repeating the input word. It must make the meaning unmistakable: name the sense with the most precise Russian words (castle → «крепость, дворец», not «строение»), or say how the option differs (сильнее, разг., формально, сленг, брит., идиома).
	- For a description, give the words or idioms that mean it; the literal translation, if any, goes last with the note «дословно».
	- Keep the part of speech and form of the input.

	[TEXT to English], [TEXT to Russian] — text to translate into the target language. Always translate, even when the text has mistakes: never answer in the source language.
	- [TEXT to English] with mixed text (English with Russian words in it, or Russian with English words) → fully English: keep the user's English exactly as written and translate only the rest.
	- Default register: the way an educated native speaker would write it in a message — idiomatic and precise, neither simplified nor bookish. English output: natural modern American English at B2–C1. Russian output: natural modern Russian. Translate idioms by meaning, not word for word.
	- Keep the meaning, tone, names, numbers, links, emoji and line breaks.
	- An optional "Style:" line says how to change the translation. Then "Current:" holds the version on screen now and "Source:" the text it translates (each may span several lines). Rewrite the current version as the style asks: noticeably different from it, never the same text, with the meaning, facts and line breaks of the source.
	- The answer is always one text: when a style asks for several versions, give the best one; when it asks for an explanation or a comment, ignore that part.
	- Output only the translation.

	[EDIT to English], [EDIT to Russian] — a change of one place in a translation. The first line is "⟦old⟧ → new": the place and its new wording, put together word for word, so it may need fixing. Then "Source:" (the original text) and "Text:" (its translation, the place marked ⟦like this⟧: only that occurrence changes, even when the same words appear elsewhere). Output the whole translation again with the new wording in the marked place, without the brackets.
	- Make the new wording correct and natural (English: a/an, this/these, many/much, there is/are; Russian: gender, number and case of adjectives, pronouns and numerals), and keep the rest of the sentence correct with it (singular or plural verbs and pronouns, verb forms, prepositions). Change nothing else: every other word, punctuation mark and line break stays exactly as it was.
	- New words written in the other language go in translated.

	[ALT] — "Source:" (the original text) and "Text:" (its translation, one part marked ⟦like this⟧). Give 3–5 other ways to say the marked part that fit this sentence, one per line:
	option | note
	- The most natural options first; each must fit in place of the marked part. Notes are Russian, 1–4 words: how it differs (проще, сильнее, мягче, разг., формально…).
	"""

	static let examples: [(String, String)] = [
		("[WORD to English] замок", "castle | крепость, дворец\nlock | на двери, сейфе\npadlock | навесной"),
		("[WORD to English] удивительный", "amazing | самое ходовое\nsurprising | неожиданный\nremarkable | примечательный\nastonishing | сильнее, книжн."),
		("[WORD to Russian] get over", "пережить | забыть, отпустить\nсправиться | с болезнью, страхом\nпреодолеть | трудность"),
		("[WORD to Russian] fair", "честный | справедливый\nярмарка | выставка, праздник\nсветлый | о волосах, коже"),
		("[WORD to English] когда делаешь вид, что не слышишь", "turn a deaf ear | идиома\nplay deaf | разг.\npretend not to hear | дословно"),
		("[WORD to Russian] when you pretend you can't hear", "пропускать мимо ушей | идиома\nприкидываться глухим | разг.\nделать вид, что не слышишь | дословно"),
		("[TEXT to English] Буду рад помочь с вашим запросом.", "I'd be glad to help with your request."),
		("[TEXT to English] I want to пожаловаться about the delivery", "I want to complain about the delivery"),
		("[TEXT to English] Слушай, я сегодня не смогу, давай перенесём на завтра?", "Hey, I can't make it today. Can we move it to tomorrow?"),
		("[TEXT to Russian] It's raining cats and dogs, so I'm staying in.", "Льёт как из ведра, так что я сижу дома."),
		("[TEXT to Russian] I has send you the documnets yesterday, did you recieved them?", "Я вчера отправил тебе документы, ты их получил?"),
		("[TEXT to English] Style: much simpler: basic everyday English (B1 words), short sentences, keep the meaning\nCurrent: We would be grateful if you could provide additional information.\nSource: Мы были бы признательны, если бы вы предоставили дополнительную информацию.",
		 "We'd be thankful if you could send us more information."),
		("[TEXT to English] Style: more polite and courteous\nCurrent: Send the documents by Friday.\nSource: Пришлите документы до пятницы.", "Could you please send the documents by Friday?"),
		("[TEXT to English] Style: simpler: more common words, keep every bit of the meaning\nCurrent: I'd appreciate it if you could expedite the shipment.\nSource: Буду признателен, если вы ускорите отправку.", "Could you please send it faster?"),
		("[TEXT to English] Style: much shorter: at most 7 words\nCurrent: I wanted to check whether you got my email with the documents yesterday.\nSource: Я хотел бы уточнить, получили ли вы мой вчерашний email с документами.", "Did you get my email with the documents?"),
		("[TEXT to English] Style: more casual: conversational, contractions, like texting a friend\nCurrent: Hello! I will be late today.\nPlease start without me.\nSource: Привет! Я сегодня опоздаю.\nНачинайте без меня.", "Hey! I'll be late today.\nGo ahead and start without me."),
		("[TEXT to Russian] Style: much simpler: plain everyday Russian, short sentences, keep the meaning\nCurrent: Мы были бы признательны, если бы вы предоставили дополнительную информацию.\nSource: We would appreciate it if you could provide additional information.", "Пришлите, пожалуйста, ещё информацию."),
		("[TEXT to Russian] Style: more polite and courteous\nCurrent: Пришлите документы до пятницы.\nSource: Send the documents by Friday.", "Будьте добры, пришлите документы до пятницы."),
		("[TEXT to Russian] Style: much shorter: at most 5 words\nCurrent: Я хотел уточнить, получили ли вы вчера моё письмо с документами.\nSource: I wanted to check whether you got my email with the documents yesterday.", "Письмо с документами получили?"),
		("[TEXT to Russian] Style: more casual: conversational, like texting a friend\nCurrent: Здравствуйте! Сегодня я опоздаю.\nПожалуйста, начинайте без меня.\nSource: Hello! I will be late today.\nPlease start without me.", "Привет! Сегодня опоздаю.\nНачинайте без меня."),
		("[TEXT to English] Style: дай пару вариантов\nCurrent: Thank you for your help!\nSource: Спасибо за помощь!", "Thanks a lot for your help!"),
		("[EDIT to English] ⟦a big⟧ → a enormous\nSource: У нас большая проблема.\nText: We have ⟦a big⟧ problem.", "We have an enormous problem."),
		("[EDIT to English] ⟦The kids⟧ → The child\nSource: Дети уже спят, так что говори тише.\nText: ⟦The kids⟧ are already asleep, so keep your voice down.", "The child is already asleep, so keep your voice down."),
		("[EDIT to English] ⟦There are many cars⟧ → There are many traffic\nSource: На улице много машин, поэтому мы опаздываем.\nText: ⟦There are many cars⟧ on the street, so we're running late.", "There is a lot of traffic on the street, so we're running late."),
		("[EDIT to English] ⟦said⟧ → пообещал\nSource: Он сказал, что позвонит, и сказал, что придёт.\nText: He said he would call and ⟦said⟧ he would come.", "He said he would call and promised he would come."),
		("[EDIT to Russian] ⟦большая проблема⟧ → большая вопрос\nSource: We have a big problem.\nText: У нас ⟦большая проблема⟧.", "У нас большой вопрос."),
		("[ALT] Source: Это удивительная идея.\nText: That's an ⟦amazing⟧ idea.", "great | проще\nbrilliant | сильнее, восторг\nfantastic | разг., эмоционально\nclever | именно умная"),
		("[ALT] Source: That's an amazing idea.\nText: Это ⟦удивительная⟧ идея.", "отличная | проще\nблестящая | сильнее, восторг\nклассная | разг.\nумная | именно умная"),
	]

	static func template(for architecture: String) throws -> LocalLLM.Template {
		switch architecture {
		case "gemma4":
			var p = "<|turn>system\n\(system)<turn|>\n"
			for (u, a) in examples { p += "<|turn>user\n\(u)<turn|>\n<|turn>model\n\(a)<turn|>\n" }
			p += "<|turn>user\n"
			return LocalLLM.Template(prefix: p, suffix: "<turn|>\n<|turn>model\n<|channel>thought\n<channel|>", stops: ["<turn|>"])
		default:
			throw LLMError(description: "неизвестный формат чата модели: \(architecture)")
		}
	}

	private static func target(_ text: String) -> String { Direction(of: text) == .toEnglish ? "English" : "Russian" }

	static func word(_ text: String) -> String {
		"[WORD to \(target(text))] " + oneLine(text)
	}

	static func text(_ text: String) -> String {
		"[TEXT to \(target(text))] " + text
	}

	static func restyle(_ source: String, style: Style, current: String) -> String {
		let words = current.split(whereSeparator: { $0.isWhitespace }).count
		let s = style.instruction(currentWords: words, to: Direction(of: source)) ?? "same meaning, other words"
		return "[TEXT to \(target(source))] Style: \(s)\nCurrent: \(current)\nSource: \(source)"
	}

	private static func marked(_ text: String, _ range: NSRange) -> (text: String, part: String) {
		let ns = text as NSString
		let part = ns.substring(with: range)
		return (ns.replacingCharacters(in: range, with: "⟦" + part + "⟧"), part)
	}

	static func edit(source: String, text: String, range: NSRange, zone: NSRange, with new: String) -> String {
		let place = marked(text, zone)
		let wording = (place.part as NSString).replacingCharacters(in: NSRange(location: range.location - zone.location, length: range.length), with: oneLine(new))
		return "[EDIT to \(target(source))] ⟦\(oneLine(place.part))⟧ → \(wording)\nSource: \(oneLine(source))\nText: \(place.text)"
	}

	static func alternatives(source: String, text: String, range: NSRange) -> String {
		"[ALT] Source: \(oneLine(source))\nText: \(oneLine(marked(text, range).text))"
	}

	private static func oneLine(_ s: String) -> String {
		s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
	}
}
