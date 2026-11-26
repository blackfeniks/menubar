import Foundation

enum TermMatcher {
	static let table: [(String, [String])] = [
		("GitHub", ["гитхаб", "гитхуб", "гитхап"]), ("GitLab", ["гитлаб"]),
		("GitHub Actions", ["гитхаб экшнс", "гитхаб экшенс", "гитхаб экшн"]), ("Bitbucket", ["битбакет"]),
		("Slack", ["слак", "слэк"]), ("Telegram", ["телеграм", "телеграмм"]),
		("WhatsApp", ["ватсап", "вотсап", "вацап", "ватсапп", "вотсапп"]), ("Viber", ["вайбер"]),
		("Zoom", ["зум"]), ("Google Meet", ["гугл мит"]), ("Teams", ["тимс"]), ("Discord", ["дискорд"]),
		("Notion", ["ноушн", "ноушен", "ношн"]), ("Obsidian", ["обсидиан"]), ("Figma", ["фигма"]),
		("Miro", ["миро"]), ("Jira", ["джира"]), ("Confluence", ["конфлюенс", "конфлюэнс"]),
		("Trello", ["трелло"]), ("YouTube", ["ютуб", "ютюб"]), ("Spotify", ["спотифай"]),
		("Instagram", ["инстаграм", "инстаграмм"]), ("Facebook", ["фейсбук"]), ("Twitter", ["твиттер", "твитер"]),
		("LinkedIn", ["линкедин", "линкдин"]), ("TikTok", ["тикток", "тик ток"]), ("Reddit", ["реддит", "редит"]),
		("Chrome", ["хром"]), ("Safari", ["сафари"]), ("Firefox", ["файрфокс", "фаерфокс"]), ("Finder", ["файндер"]),
		("Xcode", ["иксикод", "икскод", "икс код", "иксикоде"]),
		("Visual Studio Code", ["вижуал студио код", "визуал студио код", "вижуэл студио код"]),
		("VS Code", ["ви эс код", "вс код", "вскод"]), ("Cursor", ["курсор"]),
		("Claude Code", ["клод код", "клауд код"]), ("Claude", ["клод"]),
		("ChatGPT", ["чат джипити", "чатджипити", "чат гпт", "чатгпт", "чат жпт", "чат gpt"]),
		("OpenAI", ["опен эй ай", "опенэйай", "опен ай"]), ("Anthropic", ["антропик"]), ("Gemini", ["джемини"]),
		("Copilot", ["копайлот", "копилот"]), ("LM Studio", ["эл эм студио", "элэм студио", "лм студио"]),
		("Ollama", ["оллама"]), ("Hugging Face", ["хаггинг фейс", "хагинг фейс", "хаггингфейс"]),
		("llama.cpp", ["лама цпп", "лама си пи пи"]), ("Whisper", ["виспер"]), ("Docker", ["докер"]),
		("Kubernetes", ["кубернетес", "кубернетис"]), ("Redis", ["редис"]),
		("PostgreSQL", ["постгрес", "постгрескл", "постгрес кью эль"]), ("MySQL", ["май эс кью эль", "майскл"]),
		("MongoDB", ["монго дб", "монгодб"]), ("SQLite", ["эс кью лайт", "скьюлайт"]),
		("Nginx", ["энджинкс", "нджинкс", "нгинкс"]), ("Linux", ["линукс"]), ("Ubuntu", ["убунту"]),
		("macOS", ["мак ос", "макос"]), ("iOS", ["ай ос", "айос"]), ("iPhone", ["айфон"]), ("iPad", ["айпад"]),
		("MacBook", ["макбук"]), ("iCloud", ["айклауд"]), ("AirPods", ["эйрподс", "аирподс", "эирподс"]),
		("AirDrop", ["эйрдроп"]), ("Apple Watch", ["эпл вотч", "эппл вотч"]), ("Windows", ["виндоус", "виндовс"]),
		("Android", ["андроид"]), ("Vercel", ["версель", "верцель"]), ("Netlify", ["нетлифай"]),
		("Cloudflare", ["клаудфлер", "клаудфлэр"]), ("Firebase", ["файрбейс", "фаербейс"]),
		("Supabase", ["супабейс", "супабэйс"]), ("Stripe", ["страйп"]), ("Sentry", ["сентри"]),
		("Grafana", ["графана"]), ("Postman", ["постман"]), ("Swagger", ["сваггер"]), ("Excel", ["эксель"]),
		("PowerPoint", ["пауэрпоинт", "павер поинт", "пауэр поинт"]), ("Google Docs", ["гугл докс"]),
		("Google Drive", ["гугл драйв"]), ("Gmail", ["джимейл"]), ("Dropbox", ["дропбокс"]),
		("Photoshop", ["фотошоп"]), ("Python", ["пайтон", "питон"]), ("JavaScript", ["джаваскрипт", "джава скрипт"]),
		("TypeScript", ["тайпскрипт", "тайп скрипт"]), ("Swift", ["свифт"]), ("SwiftUI", ["свифт юай", "свифтюай"]),
		("Kotlin", ["котлин"]), ("Java", ["джава"]), ("Golang", ["голанг"]), ("Rust", ["раст"]),
		("C++", ["си плюс плюс"]), ("C#", ["си шарп"]), ("PHP", ["пэхапэ", "пи эйч пи"]), ("Ruby", ["руби"]),
		("React", ["реакт", "риакт"]), ("Angular", ["ангуляр"]), ("Node.js", ["нод джиэс", "нода джиэс", "нод джи эс", "ноуд джиэс"]),
		("npm", ["эн пи эм", "нпм"]), ("Homebrew", ["хомбрю", "хоумбрю"]),
		("JSON", ["джейсон", "джисон", "жсон"]), ("YAML", ["ямл", "ямыл"]), ("XML", ["икс эм эль"]),
		("HTML", ["эйч ти эм эль", "хтмл"]), ("CSS", ["си эс эс"]), ("SQL", ["эс кью эль", "сиквел"]),
		("API", ["эй пи ай", "эйпиай"]), ("GraphQL", ["графкуэль", "граф кью эль", "графкл"]),
		("OAuth", ["оаус", "оаут", "о ауф"]), ("JWT", ["джей дабл ю ти"]), ("SDK", ["эс ди кей"]),
		("CLI", ["си эль ай"]), ("UI", ["юай"]), ("CI/CD", ["си ай си ди"]),
		("pull request", ["пул реквест", "пулл реквест", "пул риквест", "пулреквест"]),
		("merge request", ["мерж реквест", "мердж реквест"]),
		("git pull", ["гит пул"]), ("git push", ["гит пуш"]), ("git status", ["гит статус"]),
		("git commit", ["гит коммит"]), ("git clone", ["гит клон"]), ("git", ["гит"]),
		("webhook", ["вебхук", "веб хук"]), ("localhost", ["локалхост"]), ("Wi-Fi", ["вайфай", "вай фай"]),
		("Bluetooth", ["блютус", "блютуз"]), ("USB", ["юэсби", "ю эс би"]), ("VPN", ["ви пи эн"]),
		("SSH", ["эс эс эйч"]), ("LLM", ["эл эл эм"]), ("GPU", ["джи пи ю"]), ("CPU", ["си пи ю"]),
		("README", ["ридми"]), ("Dynamic Island", ["динамик айленд", "динамик айлэнд"]), ("MLX", ["эм эл икс"]),
		("GigaAM", ["гигаам", "гига ам"]), ("Gemma", ["джемма"]), ("PNG", ["пэ эн гэ", "пнг"]),
		("PDF", ["пэдээф", "пдф", "пи ди эф"]), ("JPEG", ["джипег", "жипег"]), ("Google Chrome", ["гугл хром"]),
		("App Store", ["эп стор", "эпп стор", "апп стор", "аппстор", "эпстор"]),
	]

	static let ambiguous: Set<String> = ["питон", "хром", "редис", "курсор", "сафари", "обсидиан", "миро", "клод",
	                                     "руби", "раст", "джава", "зум", "гит", "свифт", "джейсон", "джемма"]

	private static let techWords = ["код", "скрипт", "функци", "сервер", "запуст", "установ", "верси", "библиотек",
	                                "фреймворк", "приложени", "программ", "напиш", "проект", "файл", "репозитор",
	                                "браузер", "вкладк", "баг", "тест", "деплой", "коммит", "базу", "базе", "данных",
	                                "модел", "терминал", "компил", "сборк", "ветк", "токен", "логи", "консол",
	                                "созвон", "звонок", "ссылк", "чат", "написал", "скин", "открой", "открыт",
	                                "рендер", "нейронк", "скача", "макет"]

	static let endings = ["ами", "ями", "ом", "ем", "ём", "ой", "ою", "ей", "ах", "ях", "ов", "ев",
	                      "а", "я", "у", "ю", "е", "и", "ы"]

	struct Form {
		let words: [String]
		let term: String
		let ambiguous: Bool
		let scalars: [TextMetrics.Key]
		let inflected: Set<String>

		init(_ spoken: String, term: String) {
			words = spoken.split(separator: " ").map(String.init)
			self.term = term
			ambiguous = TermMatcher.ambiguous.contains(spoken)
			scalars = words.map { Array($0.unicodeScalars) }
			var stems = [words.last ?? ""]
			if let form = words.last, let l = form.last, "ая".contains(l), form.count > 3 { stems.append(String(form.dropLast())) }
			inflected = Set(stems.flatMap { stem in TermMatcher.endings.map { stem + $0 } })
		}
	}

	static let forms: [Form] = table.flatMap { term, spoken in
		spoken.map { Form($0, term: term) }
	}.sorted { $0.words.count > $1.words.count }

	private static let endingScalars = endings.map { Array($0.unicodeScalars) }

	private struct Token {
		var text: String
		let isWord: Bool
	}

	private static func tokenize(_ s: String) -> [Token] {
		var out: [Token] = []
		var cur = ""
		var curIsWord: Bool?
		for ch in s {
			let w = ch.isLetter || ch.isNumber
			if curIsWord == nil || curIsWord == w {
				cur.append(ch)
			} else {
				out.append(Token(text: cur, isWord: curIsWord!))
				cur = String(ch)
			}
			curIsWord = w
		}
		if let w = curIsWord { out.append(Token(text: cur, isWord: w)) }
		return out
	}

	private static func norm(_ w: String) -> String { w.lowercased().replacingOccurrences(of: "ё", with: "е") }

	private static func sentenceStart(_ tokens: [Token], _ i: Int) -> Bool {
		for t in tokens[..<i].reversed() {
			if let u = t.text.unicodeScalars.last(where: { !CharacterSet.whitespaces.contains($0) }) {
				return ".!?…".unicodeScalars.contains(u)
			}
		}
		return true
	}

	enum Match { case exact, inflected, fuzzy }

	private static func match(_ word: String, _ ws: TextMetrics.Key, _ form: Form, _ k: Int, last: Bool) -> Match? {
		let fs = form.scalars[k]
		if word == form.words[k] { return .exact }
		guard last else {
			return ws.count >= 6 && abs(ws.count - fs.count) <= 1 && TextMetrics.levenshtein(ws, fs) <= 1 ? .fuzzy : nil
		}
		if form.inflected.contains(word) { return .inflected }
		guard fs.count >= 6 else { return nil }
		let limit = fs.count >= 10 ? 2 : 1
		if abs(ws.count - fs.count) <= limit, TextMetrics.levenshtein(ws, fs) <= limit { return .fuzzy }
		for e in endingScalars where ws.count - e.count >= 5 && abs(ws.count - e.count - fs.count) <= limit
			&& ws[(ws.count - e.count)...].elementsEqual(e) {
			if TextMetrics.levenshtein(Array(ws.dropLast(e.count)), fs) <= limit { return .fuzzy }
		}
		return nil
	}

	static func isTechnical(_ text: String) -> Bool {
		let t = norm(text)
		if t.range(of: "[a-z]", options: .regularExpression) != nil { return true }
		return techWords.contains { t.contains($0) }
	}

	static func apply(_ text: String, isRussianWord: (String) -> Bool = { _ in false }) -> String {
		let cased = fixCase(text)
		let technical = isTechnical(cased)
		let (first, found) = replace(cased, allowAmbiguous: false, technical: technical, isRussianWord: isRussianWord)
		guard found || technical else { return first }
		return replace(first, allowAmbiguous: true, technical: true, isRussianWord: isRussianWord).0
	}

	static let canonicalCase: [String: String] = {
		var map: [String: String] = [:]
		let terms = Glossary.terms.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
		for term in terms where !term.contains(" ") && term.count >= 2 {
			let simple = term.prefix(1).uppercased() + term.dropFirst().lowercased()
			if term != simple { map[term.lowercased()] = term }
		}
		return map
	}()

	private static func fixCase(_ text: String) -> String {
		var tokens = tokenize(text)
		for i in tokens.indices where tokens[i].isWord {
			guard var canonical = canonicalCase[tokens[i].text.lowercased()],
			      tokens[i].text.range(of: "[A-Za-z]", options: .regularExpression) != nil else { continue }
			if canonical == canonical.lowercased(), sentenceStart(tokens, i) {
				canonical = canonical.prefix(1).uppercased() + canonical.dropFirst()
			}
			tokens[i].text = canonical
		}
		return tokens.map(\.text).joined()
	}

	private static func replace(_ text: String, allowAmbiguous: Bool, technical: Bool,
	                            isRussianWord: (String) -> Bool) -> (String, Bool) {
		var tokens = tokenize(text)
		var normed = tokens.map { $0.isWord ? norm($0.text) : "" }
		var scalars = normed.map { Array($0.unicodeScalars) }
		var found = false
		var i = 0
		while i < tokens.count {
			guard tokens[i].isWord else {
				i += 1
				continue
			}
			for form in forms where !form.ambiguous || allowAmbiguous {
				var idx = [i]
				var j = i
				var ok = true
				while idx.count < form.words.count {
					j += 1
					guard j + 1 < tokens.count, !tokens[j].isWord, tokens[j].text.unicodeScalars.allSatisfy({ $0 == " " || $0 == "-" }),
					      tokens[j + 1].isWord else {
						ok = false
						break
					}
					j += 1
					idx.append(j)
				}
				guard ok else { continue }
				var kinds: [Match] = []
				for (k, t) in idx.enumerated() {
					guard let m = match(normed[t], scalars[t], form, k, last: k == idx.count - 1) else { break }
					kinds.append(m)
				}
				guard kinds.count == idx.count else { continue }
				if !technical, zip(kinds, idx).contains(where: { $0.0 != .exact && isRussianWord(tokens[$0.1].text) }) {
					continue
				}
				var term = form.term
				if term == term.lowercased(), sentenceStart(tokens, i) {
					term = term.prefix(1).uppercased() + term.dropFirst()
				}
				let first = idx.first!, last = idx.last!
				tokens.replaceSubrange(first...last, with: [Token(text: term, isWord: true)])
				normed.replaceSubrange(first...last, with: [norm(term)])
				scalars.replaceSubrange(first...last, with: [Array(norm(term).unicodeScalars)])
				found = true
				break
			}
			i += 1
		}
		return (tokens.map(\.text).joined(), found)
	}
}
