import AppKit
import Foundation

struct Edit: Equatable {
	var source: String
	var replacement: String
}

struct EditDecision {
	let edit: Edit
	let accepted: Bool
	let reason: String
}

enum Glossary {
	static let terms = """
	GitHub, GitLab, GitHub Actions, GitHub Copilot, Bitbucket, Gitea, Slack, Telegram, WhatsApp, Viber, Signal, Zoom, \
	Google Meet, Microsoft Teams, Teams, Skype, Discord, Notion, Obsidian, Figma, FigJam, Sketch, Miro, Jira, \
	Confluence, Trello, Asana, Linear, ClickUp, YouTube, Twitch, Spotify, Netflix, Instagram, Facebook, Twitter, \
	LinkedIn, TikTok, Reddit, Medium, Habr, Stack Overflow, Wikipedia, Chrome, Safari, Firefox, Arc, Edge, Opera, \
	Finder, Xcode, Visual Studio, Visual Studio Code, VS Code, IntelliJ IDEA, PyCharm, WebStorm, Android Studio, \
	Cursor, Windsurf, Zed, Vim, Neovim, Emacs, Sublime Text, iTerm, Terminal, Raycast, Alfred, Homebrew, \
	Claude, Claude Code, ChatGPT, GPT, OpenAI, Anthropic, Gemini, Copilot, Midjourney, Stable Diffusion, \
	LM Studio, Ollama, Hugging Face, llama.cpp, Whisper, GigaChat, YandexGPT, Qwen, DeepSeek, Mistral, Llama, \
	LLM, RAG, MCP, Docker, Docker Compose, Kubernetes, Helm, Terraform, Ansible, Jenkins, GitHub Pages, \
	Redis, PostgreSQL, Postgres, MySQL, MariaDB, MongoDB, SQLite, ClickHouse, Elasticsearch, Kafka, RabbitMQ, \
	Nginx, Apache, Linux, Ubuntu, Debian, Arch, macOS, iOS, iPadOS, watchOS, iPhone, iPad, MacBook, MacBook Pro, \
	MacBook Air, iMac, Mac mini, Mac Studio, iCloud, AirPods, AirDrop, Apple Watch, Apple, Siri, App Store, \
	TestFlight, Windows, Android, AWS, S3, EC2, Lambda, Azure, Google Cloud, Vercel, Netlify, Heroku, \
	Cloudflare, DigitalOcean, Firebase, Supabase, Stripe, PayPal, Sentry, Grafana, Prometheus, Datadog, \
	Postman, Swagger, Excel, Word, PowerPoint, Outlook, OneDrive, SharePoint, Google Docs, Google Sheets, \
	Google Drive, Gmail, Google Calendar, Dropbox, Keynote, Pages, Numbers, Photoshop, Lightroom, Illustrator, \
	Premiere, After Effects, Final Cut, DaVinci Resolve, Blender, Unity, Unreal Engine, Steam, \
	Python, JavaScript, TypeScript, Swift, SwiftUI, UIKit, AppKit, Objective-C, Kotlin, Java, Go, Golang, Rust, \
	C, C++, C#, .NET, PHP, Ruby, Ruby on Rails, Rails, Perl, Lua, Dart, Flutter, Elixir, Haskell, Scala, R, \
	MATLAB, Bash, Zsh, PowerShell, React, React Native, Vue, Angular, Svelte, Next.js, Nuxt, Node.js, Deno, Bun, \
	Express, Django, Flask, FastAPI, Spring, Laravel, Tailwind, Bootstrap, jQuery, Redux, GraphQL, Webpack, Vite, \
	npm, pnpm, yarn, pip, uv, conda, Poetry, PyTorch, TensorFlow, NumPy, pandas, Jupyter, CUDA, Metal, Core ML, \
	ONNX, git, git pull, git push, git status, git commit, git merge, git rebase, git clone, GitHub CLI, \
	JSON, YAML, TOML, XML, HTML, CSS, SQL, NoSQL, API, REST, gRPC, WebSocket, OAuth, JWT, SSO, SDK, CLI, IDE, \
	UI, UX, CI, CD, CI/CD, DevOps, QA, MVP, PR, pull request, merge request, code review, webhook, endpoint, \
	localhost, Wi-Fi, Bluetooth, USB, USB-C, HDMI, PDF, VPN, DNS, SSH, HTTP, HTTPS, URL, IP, TCP, UDP, GPU, \
	CPU, RAM, SSD, M1, M2, M3, M4, M3 Pro, OK, FAQ, KPI, OKR, CRM, ERP, SaaS, B2B, B2C, HR, PM, CEO, CTO, \
	README, Markdown, PNG, JPEG, SVG, GIF, MP4, CSV, ZIP, Dynamic Island, MLX, GigaAM, Gemma, Codex, ComfyUI, Flux, \
	Runway, CapCut, Framer, Webflow, CrossOver, GTA
	"""

	static let known: Set<String> = Set(terms.split(separator: ",").map {
		$0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	})

	static let knownWords: Set<String> = Set(known.flatMap { latinWords($0) })

	static func latinWords(_ s: String) -> [String] {
		s.lowercased().components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789+#.").inverted)
			.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
			.filter { $0.range(of: "[a-z]", options: .regularExpression) != nil }
	}

	static let slang: Set<String> = [
		"линтер", "линтера", "линтеры", "коммит", "коммита", "коммиты", "коммитов", "коммитить", "закоммитить",
		"закоммить", "закоммитил", "деплой", "деплоя", "деплоить", "задеплоить", "задеплой", "задеплоил", "мерж",
		"мердж", "смерджить", "смерджил", "смёрджил", "мерджить", "мёрджить", "мерджи", "мёрджи", "фидбэк",
		"фидбек", "фидбэка", "ревью", "бэкенд", "бэкэнд", "бэкенда", "бэкенде", "фронтенд", "фронтенда", "фронтенде",
		"реквест", "реквеста", "реквесте", "баг", "бага", "баги", "багов", "фича", "фичи", "фичу", "тикет", "тикета",
		"тикету", "спринт", "дедлайн", "релиз", "релиза", "билд", "билда", "пуш", "пушить", "запушить", "запушь",
		"запушил", "форк", "бранч", "апишка", "апишки", "эндпоинт", "эндпоинта", "продакшн", "продакшен", "прод",
		"прода", "созвон", "созвона", "созвониться", "лагает", "лагать", "скрин", "скриншот", "скриншота", "превью",
		"брейкпоинт", "рефакторинг", "рестартится", "рестарт", "джоб", "джоба", "кэш", "кеш", "токен", "токена",
		"логи", "логов", "парсит", "парсить", "дебаг", "дебажить", "апдейт", "апгрейд", "юзер", "юзера", "аккаунт",
		"видос", "видоса", "видосы", "видосе", "видосик", "мудборд", "мудборда", "мудборде", "мудборды", "нейронка",
		"нейронки", "нейронку", "нейронкой", "промпт", "промпта", "промпты", "промпте", "рендер", "рендера", "рендеры",
		"рендерить", "отрендерить", "чекнуть", "чекни", "фикс", "фикса", "пофиксить", "пофикси", "косяк", "косяки",
	]
}

enum CorrectionPrompt {
	static let system = """
	Ты исправляешь ошибки автоматического распознавания русской речи. Даны «Текст» — основная расшифровка (точнее в русских словах) и «Вторая» — другая расшифровка той же записи (точнее передаёт звучание иностранных слов).
	Найди в «Тексте» только явные ошибки распознавания:
	1. Названия программ, сервисов, компаний, языков программирования, команд и аббревиатуры, записанные кириллицей или искажённо, — замени оригинальным написанием латиницей: гитхаб → GitHub, клод код → Claude Code, джейсон → JSON, пул реквест → pull request.
	2. Искажённые слова, которых нет в русском языке, если по «Второй» расшифровке и по смыслу ясно, что было сказано.
	3. Слова, распознанные как другое настоящее слово, только если «Вторая» расшифровка и смысл однозначно показывают, что сказано иное: налоги → на логи.
	Обычные русские слова и привычный IT-сленг (коммит, деплой, фидбэк, ревью, фронтенд, баг, созвон) не трогай и не переводи на английский.
	Каждую правку выведи отдельной строкой: фрагмент => исправление. Фрагмент копируй из «Текста» дословно. Если исправлять нечего, выведи: нет
	Частые названия (пиши их именно так): \(Glossary.terms)
	"""

	static let examples: [(String, String)] = [
		("Текст: Залей фикс на гитлаб и скинь линк в слак.\nВторая: Залей фикс на гитлаб и скинь линк в слак.",
		 "гитлаб => GitLab\nслак => Slack"),
		("Текст: Проверь, что гра фкюэль отдаёт дату, и закоммить.\nВторая: Проверь, что графкуэль отдает дату и закоммить.",
		 "гра фкюэль => GraphQL"),
		("Текст: Мы встретимся завтра в 10 утра у входа.\nВторая: Мы встретимся завтра в десять утра у входа.",
		 "нет"),
		("Текст: Он сказал, что прийдёт позже, застрял в пропке.\nВторая: Он сказал, что придет позже, застрял в пробке.",
		 "прийдёт => придёт\nпропке => пробке"),
		("Текст: Кинь фидбэк по задаче в джиру и отпиши в тимсе.\nВторая: Кинь фидбэк по задаче в джиру и отпиши в тимс.",
		 "джиру => Jira\nтимсе => Teams"),
		("Текст: Можешь сильно не вникать в налоги, просто перезапусти сервис.\nВторая: Можешь сильно не вникать в логи, просто перезапусти сервис.",
		 "в налоги => в логи"),
	]

	static func user(text: String, hint: String?, terms: [String] = []) -> String {
		let own = terms.isEmpty ? "" : "\nТермины пользователя: " + terms.joined(separator: ", ")
		return "Текст: \(text)\nВторая: \(hint ?? text)" + own
	}

	static func template(for architecture: String) throws -> LocalLLM.Template {
		switch architecture {
		case "deepseek2":
			var p = "system<|role_sep|>\n\(system)<|message_sep|>\n\n"
			for (u, a) in examples {
				p += "user<|role_sep|>\n\(u)<|message_sep|>\n\nassistant<|role_sep|>\n\(a)<|message_sep|>\n\n"
			}
			p += "user<|role_sep|>\n"
			return LocalLLM.Template(prefix: p, suffix: "<|message_sep|>\n\nassistant<|role_sep|>\n",
			                         stops: ["<|message_sep|>", "</s>"])
		case "gemma4":
			var p = "<|turn>system\n\(system)<turn|>\n"
			for (u, a) in examples {
				p += "<|turn>user\n\(u)<turn|>\n<|turn>model\n\(a)<turn|>\n"
			}
			p += "<|turn>user\n"
			return LocalLLM.Template(prefix: p, suffix: "<turn|>\n<|turn>model\n<|channel>thought\n<channel|>",
			                         stops: ["<turn|>"])
		default:
			throw LLMError(description: "неизвестный формат чата модели: \(architecture)")
		}
	}
}

enum TextMetrics {
	typealias Key = [Unicode.Scalar]
	private typealias Rule = (from: Key, to: Key)

	private static func rules(_ pairs: [(String, String)]) -> [Rule] {
		pairs.map { (Array($0.0.unicodeScalars), Array($0.1.unicodeScalars)) }
	}

	private static let lat2cyr = rules([
		("sch", "ш"), ("sh", "ш"), ("ch", "ч"), ("zh", "ж"), ("th", "т"), ("ph", "ф"), ("ck", "к"), ("qu", "кв"),
		("ee", "и"), ("oo", "у"), ("ea", "и"), ("ou", "ау"), ("ai", "эй"), ("ay", "эй"), ("oa", "оу"), ("ew", "ью"),
		("x", "кс"), ("j", "дж"), ("w", "в"), ("q", "к"), ("c", "к"), ("y", "и"), ("a", "а"), ("b", "б"), ("d", "д"),
		("e", "е"), ("f", "ф"), ("g", "г"), ("h", "х"), ("i", "и"), ("k", "к"), ("l", "л"), ("m", "м"), ("n", "н"),
		("o", "о"), ("p", "п"), ("r", "р"), ("s", "с"), ("t", "т"), ("u", "у"), ("v", "в"), ("z", "з"),
	])

	private static let cyr2lat = rules([
		("дж", "j"), ("кс", "x"), ("а", "a"), ("б", "b"), ("в", "v"), ("г", "g"), ("д", "d"), ("е", "e"), ("ё", "yo"),
		("ж", "zh"), ("з", "z"), ("и", "i"), ("й", "y"), ("к", "k"), ("л", "l"), ("м", "m"), ("н", "n"), ("о", "o"),
		("п", "p"), ("р", "r"), ("с", "s"), ("т", "t"), ("у", "u"), ("ф", "f"), ("х", "h"), ("ц", "ts"), ("ч", "ch"),
		("ш", "sh"), ("щ", "sch"), ("ъ", ""), ("ы", "y"), ("ь", ""), ("э", "e"), ("ю", "yu"), ("я", "ya"),
	])

	private static func transliterate(_ input: Key, _ rules: [Rule]) -> Key {
		var s = input, out = Key()
		for (from, to) in rules {
			guard let first = from.first, s.count >= from.count, s.contains(first) else { continue }
			out.removeAll(keepingCapacity: true)
			var i = 0, changed = false
			while i < s.count {
				if s[i] == first, i + from.count <= s.count, from.count == 1 || s[(i + 1)..<(i + from.count)].elementsEqual(from[1...]) {
					out.append(contentsOf: to)
					i += from.count
					changed = true
				} else {
					out.append(s[i])
					i += 1
				}
			}
			if changed { swap(&s, &out) }
		}
		return s
	}

	private static func words(_ s: Key) -> Key {
		var out = Key()
		out.reserveCapacity(s.count)
		var gap = false
		for u in s {
			if CharacterSet.alphanumerics.contains(u) {
				if gap, !out.isEmpty { out.append(" ") }
				gap = false
				out.append(u)
			} else {
				gap = true
			}
		}
		return out
	}

	private static func phoneticScalars(_ s: String) -> Key {
		let yo: Unicode.Scalar = "ё", ye: Unicode.Scalar = "е"
		return words(transliterate(s.lowercased().unicodeScalars.map { $0 == yo ? ye : $0 }, lat2cyr))
	}

	private static func latinScalars(_ s: String) -> Key {
		words(transliterate(Array(s.lowercased().unicodeScalars), cyr2lat))
	}

	private final class Memo<Value>: @unchecked Sendable {
		private var table: [String: Value] = [:]
		private let lock = NSLock()

		func value(_ key: String, _ make: (String) -> Value) -> Value {
			lock.lock()
			if let v = table[key] {
				lock.unlock()
				return v
			}
			lock.unlock()
			let v = make(key)
			lock.lock()
			if table.count > 20000 { table.removeAll(keepingCapacity: true) }
			table[key] = v
			lock.unlock()
			return v
		}
	}

	private static let phoneticMemo = Memo<Key>(), latinMemo = Memo<Key>()

	static func phonetic(_ s: String) -> String {
		var v = String.UnicodeScalarView()
		v.append(contentsOf: phoneticMemo.value(s, phoneticScalars))
		return String(v)
	}

	static func latin(_ s: String) -> String {
		var v = String.UnicodeScalarView()
		v.append(contentsOf: latinMemo.value(s, latinScalars))
		return String(v)
	}

	static func soundKeys(_ s: String) -> (phonetic: Key, latin: Key) {
		(phoneticMemo.value(s, phoneticScalars).filter { $0 != " " }, latinMemo.value(s, latinScalars).filter { $0 != " " })
	}

	static func soundSimilarity(_ a: String, _ b: String) -> Double {
		soundSimilarity(soundKeys(a), soundKeys(b))
	}

	static func soundSimilarity(_ a: (phonetic: Key, latin: Key), _ b: (phonetic: Key, latin: Key)) -> Double {
		max(similarity(a.phonetic, b.phonetic), similarity(a.latin, b.latin))
	}

	static func letters(_ s: String) -> String {
		var v = String.UnicodeScalarView()
		for u in s.lowercased().unicodeScalars where CharacterSet.letters.contains(u) || CharacterSet.decimalDigits.contains(u) {
			v.append(u == "ё" ? "е" : u)
		}
		return String(v)
	}

	static func levenshtein(_ a: Key, _ b: Key) -> Int {
		if a.isEmpty { return b.count }
		if b.isEmpty { return a.count }
		return withUnsafeTemporaryAllocation(of: Int.self, capacity: 2 * (b.count + 1)) { buf in
			var prev = buf.baseAddress!, cur = prev + (b.count + 1)
			for j in 0...b.count { prev[j] = j }
			for i in 1...a.count {
				cur[0] = i
				let ai = a[i - 1]
				for j in 1...b.count {
					cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ai == b[j - 1] ? 0 : 1))
				}
				swap(&prev, &cur)
			}
			return prev[b.count]
		}
	}

	static func similarity(_ x: Key, _ y: Key) -> Double {
		if x.isEmpty && y.isEmpty { return 1 }
		return 1 - Double(levenshtein(x, y)) / Double(max(x.count, y.count))
	}

	static func similarity(_ a: String, _ b: String) -> Double {
		similarity(a.unicodeScalars.filter { $0 != " " }, b.unicodeScalars.filter { $0 != " " })
	}

	static func bestWindow(_ target: String, in pool: String) -> Double {
		let tw = target.split(separator: " "), pw = pool.split(whereSeparator: { $0 == " " || $0 == "\n" })
		guard !tw.isEmpty, !pw.isEmpty else { return 0 }
		let keys = soundKeys(target)
		var best = 0.0
		for n in max(1, tw.count - 1)...(tw.count + 2) {
			guard n <= pw.count else { break }
			for i in 0...(pw.count - n) {
				best = max(best, soundSimilarity(keys, soundKeys(pw[i..<(i + n)].joined(separator: " "))))
			}
		}
		return best
	}

	static func hasLatin(_ s: String) -> Bool {
		s.unicodeScalars.contains { ("A"..."Z").contains($0) || ("a"..."z").contains($0) }
	}

	static func hasCyrillic(_ s: String) -> Bool {
		s.unicodeScalars.contains { ("А"..."я").contains($0) || $0 == "Ё" || $0 == "ё" }
	}

	static func latinShare(_ s: String) -> Double {
		var latin = 0, all = 0
		for u in s.unicodeScalars where CharacterSet.letters.contains(u) {
			all += 1
			if u.isASCII { latin += 1 }
		}
		return all == 0 ? 0 : Double(latin) / Double(all)
	}
}

final class Speller: @unchecked Sendable {
	private var cache: [String: Bool] = [:]
	private let lock = NSLock()
	var extraWords: Set<String> {
		get {
			lock.lock()
			defer { lock.unlock() }
			return _extraWords
		}
		set {
			lock.lock()
			_extraWords = newValue
			lock.unlock()
		}
	}
	private var _extraWords: Set<String> = []

	func isWord(_ w: String) -> Bool {
		let lw = w.lowercased()
		if Glossary.slang.contains(lw) || Glossary.slang.contains(lw.replacingOccurrences(of: "ё", with: "е"))
			|| extraWords.contains(lw) { return true }
		lock.lock()
		if let c = cache[w] {
			lock.unlock()
			return c
		}
		lock.unlock()
		let ok = MainActor.assumeIsolatedOrSync {
			NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: "ru", wrap: false,
			                                    inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
		}
		lock.lock()
		cache[w] = ok
		lock.unlock()
		return ok
	}

	func unknownWords(_ s: String) -> [String] {
		s.components(separatedBy: CharacterSet.letters.inverted)
			.filter { $0.count > 1 && TextMetrics.hasCyrillic($0) && !isWord($0) }
	}

	func knownWords(_ s: String) -> [String] {
		s.components(separatedBy: CharacterSet.letters.inverted).filter {
			$0.count > 1 && TextMetrics.hasCyrillic($0) && !Glossary.slang.contains($0.lowercased()) && isWord($0)
		}
	}
}

extension MainActor {
	static func assumeIsolatedOrSync<T>(_ body: @MainActor () -> T) -> T {
		if Thread.isMainThread { return MainActor.assumeIsolated(body) }
		return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
	}
}

struct EditValidator {
	let speller: Speller
	var userTerms: Set<String> = [] {
		didSet { userTermWords = Set(userTerms.flatMap { Glossary.latinWords($0) }) }
	}
	private(set) var userTermWords: Set<String> = []

	init(speller: Speller, userTerms: Set<String> = []) {
		self.speller = speller
		self.userTerms = userTerms
		userTermWords = Set(userTerms.flatMap { Glossary.latinWords($0) })
	}

	static let negations: Set<String> = ["не", "ни", "нет"]

	static func locate(_ fragment: String, in text: String) -> Range<String.Index>? {
		var search = text.startIndex..<text.endIndex
		while let r = text.range(of: fragment, options: [.caseInsensitive], range: search) {
			let beforeOK = r.lowerBound == text.startIndex || !text[text.index(before: r.lowerBound)].isLetter
			let afterOK = r.upperBound == text.endIndex || !text[r.upperBound].isLetter
			if beforeOK && afterOK { return r }
			search = r.upperBound..<text.endIndex
		}
		return nil
	}

	static func alignFromHint(_ fragment: String, text: String, hint: String) -> Range<String.Index>? {
		let n = TextMetrics.phonetic(fragment).split(separator: " ").count
		guard n > 0 else { return nil }
		let words = wordRanges(text)
		let keys = TextMetrics.soundKeys(fragment)
		var best: (Double, Range<String.Index>)?
		for len in max(1, n - 1)...(n + 1) where len <= words.count {
			for i in 0...(words.count - len) {
				let r = words[i].lowerBound..<words[i + len - 1].upperBound
				let s = TextMetrics.soundSimilarity(TextMetrics.soundKeys(String(text[r])), keys)
				if s > (best?.0 ?? 0) { best = (s, r) }
			}
		}
		guard let best, best.0 >= 0.7 else { return nil }
		return best.1
	}

	static func align(_ text: [String], _ hint: [String]) -> [Int?] {
		let n = text.count, m = hint.count
		guard n > 0, m > 0 else { return Array(repeating: nil, count: n) }
		var d = Array(repeating: Array(repeating: 0.0, count: m + 1), count: n + 1)
		for i in 0...n { d[i][0] = Double(i) }
		for j in 0...m { d[0][j] = Double(j) }
		var sub = Array(repeating: Array(repeating: 0.0, count: m), count: n)
		let tk = text.map(TextMetrics.soundKeys), hk = hint.map(TextMetrics.soundKeys)
		for i in 0..<n {
			for j in 0..<m { sub[i][j] = 1 - TextMetrics.soundSimilarity(tk[i], hk[j]) }
		}
		for i in 1...n {
			for j in 1...m {
				d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + sub[i - 1][j - 1] * 1.2)
			}
		}
		var out = [Int?](repeating: nil, count: n)
		var i = n, j = m
		while i > 0 && j > 0 {
			if abs(d[i][j] - (d[i - 1][j - 1] + sub[i - 1][j - 1] * 1.2)) < 1e-9 {
				out[i - 1] = j - 1
				i -= 1
				j -= 1
			} else if abs(d[i][j] - (d[i - 1][j] + 1)) < 1e-9 {
				i -= 1
			} else {
				j -= 1
			}
		}
		return out
	}

	final class HintAlignment {
		let text: String, hint: String
		private lazy var parts: (tr: [Range<String.Index>], hw: [String], map: [Int?]) = {
			let tr = EditValidator.wordRanges(text), hr = EditValidator.wordRanges(hint)
			let hw = hr.map { String(hint[$0]) }
			return (tr, hw, EditValidator.align(tr.map { String(text[$0]) }, hw))
		}()

		init(text: String, hint: String) {
			self.text = text
			self.hint = hint
		}

		func span(for range: Range<String.Index>) -> String {
			let (tr, hw, map) = parts
			var lo = Int.max, hi = Int.min
			for (i, r) in tr.enumerated() where r.overlaps(range) {
				let j = map[i] ?? (stride(from: i, through: 0, by: -1).lazy.compactMap { map[$0] }.first)
					?? map[i...].compactMap { $0 }.first
				if let j {
					lo = min(lo, j)
					hi = max(hi, j)
				}
			}
			guard lo <= hi else { return hint }
			return hw[max(0, lo - 1)...min(hw.count - 1, hi + 1)].joined(separator: " ")
		}
	}

	static func hintSpan(for range: Range<String.Index>, text: String, hint: String) -> String {
		HintAlignment(text: text, hint: hint).span(for: range)
	}

	static func wordRanges(_ text: String) -> [Range<String.Index>] {
		var out: [Range<String.Index>] = []
		var start: String.Index?
		var i = text.startIndex
		while i < text.endIndex {
			let c = text[i]
			let inWord = c.isLetter || c.isNumber || c == "-" || c == "_"
			if inWord, start == nil { start = i }
			if !inWord, let s = start {
				out.append(s..<i)
				start = nil
			}
			i = text.index(after: i)
		}
		if let s = start { out.append(s..<text.endIndex) }
		return out
	}

	func judge(_ edit: Edit, text: String, hint: String?, alignment: HintAlignment? = nil) -> (EditDecision, Range<String.Index>?) {
		func no(_ why: String) -> (EditDecision, Range<String.Index>?) { (EditDecision(edit: edit, accepted: false, reason: why), nil) }
		let aligned = alignment ?? hint.map { HintAlignment(text: text, hint: $0) }
		let src = edit.source.trimmingCharacters(in: .whitespaces), dst = edit.replacement.trimmingCharacters(in: .whitespaces)
		guard !src.isEmpty, !dst.isEmpty else { return no("пустая") }
		var range = Self.locate(src, in: text)
		if range == nil || src == dst {
			range = Self.alignFromHint(src, text: text, hint: hint ?? "")
		}
		guard let range else { return no("нет в тексте") }
		let actual = String(text[range])
		guard actual != dst else { return no("пустая") }
		guard dst.count <= actual.count * 5 / 2 + 12 else { return no("слишком длинная") }
		if TextMetrics.letters(actual) == TextMetrics.letters(dst) {
			if actual.lowercased().contains("ё") && !dst.lowercased().contains("ё") { return no("ё → е") }
			let words = { (s: String) in s.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty } }
			if words(actual).count != words(dst).count, TextMetrics.hasCyrillic(dst) {
				guard speller.unknownWords(dst).isEmpty else { return no("граница слова: не слова") }
				let simHint = aligned.map { TextMetrics.bestWindow(dst, in: $0.span(for: range)) } ?? 0
				guard !speller.unknownWords(actual).isEmpty || simHint >= 0.9 && words(dst).allSatisfy({ $0.count >= 2 })
				else { return no("граница слова: не подтверждается") }
			}
			return (EditDecision(edit: edit, accepted: true, reason: "регистр/пунктуация"), range)
		}
		let srcWords = Set(TextMetrics.phonetic(actual).split(separator: " ").map(String.init))
		let dstWords = Set(TextMetrics.phonetic(dst).split(separator: " ").map(String.init))
		guard srcWords.intersection(Self.negations) == dstWords.intersection(Self.negations) else { return no("отрицание") }
		let simSrc = TextMetrics.soundSimilarity(actual, dst)
		let simHint = aligned.map { TextMetrics.bestWindow(dst, in: $0.span(for: range)) } ?? 0
		let info = String(format: "src %.2f, hint %.2f", simSrc, simHint)
		if TextMetrics.hasLatin(dst) {
			guard simSrc >= 0.45 || simHint >= 0.6 else { return no("не похоже по звучанию (\(info))") }
			if TextMetrics.hasCyrillic(actual), dst == dst.lowercased(), !dst.contains(" "), !actual.contains(" ") {
				return no("перевод слова (\(info))")
			}
			let heard = Glossary.latinWords(actual) + (aligned.map { Glossary.latinWords($0.span(for: range)) } ?? [])
			for w in Glossary.latinWords(dst) where !Glossary.knownWords.contains(w) && !userTermWords.contains(w) {
				guard heard.contains(where: { TextMetrics.similarity($0, w) >= 0.75 }) else {
					return no("«\(w)» нет в словаре терминов (\(info))")
				}
			}
			let dropped = droppedWords(actual, dst)
			if !dropped.isEmpty {
				guard Glossary.known.contains(dst.lowercased()) || userTerms.contains(dst.lowercased()) else {
					return no("перевод русского слова «\(dropped[0])» (\(info))")
				}
				let parts = dst.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
				for w in dropped where !parts.contains(where: { TextMetrics.soundSimilarity(w, $0) >= 0.5 }) {
					return no("пропадает слово «\(w)» (\(info))")
				}
			}
			return (EditDecision(edit: edit, accepted: true, reason: "термин (\(info))"), range)
		}
		let unknownAfter = speller.unknownWords(dst)
		guard !speller.unknownWords(actual).isEmpty else {
			let a = actual.split(separator: " "), b = dst.split(separator: " ")
			let swapped = zip(a, b).filter { $0.0.lowercased() != $0.1.lowercased() }
			guard a.count == b.count, a.count <= 3, !swapped.isEmpty, unknownAfter.isEmpty, simSrc >= 0.7, simHint >= 0.9,
			      swapped.allSatisfy({ $0.0.count >= 4 && !Self.sameStem(String($0.0), String($0.1)) })
			else { return no("исходные слова существуют (\(info))") }
			return (EditDecision(edit: edit, accepted: true, reason: "слово подтверждено второй расшифровкой (\(info))"), range)
		}
		if let w = droppedWords(actual, dst).first { return no("пропадает слово «\(w)» (\(info))") }
		guard unknownAfter.isEmpty || simHint >= 0.85 else { return no("исправление не из словаря (\(info))") }
		guard simSrc >= 0.5 else { return no("слишком непохоже (\(info))") }
		guard simHint >= 0.6 || hint == nil || simSrc >= 0.85 else { return no("не подтверждается второй расшифровкой (\(info))") }
		return (EditDecision(edit: edit, accepted: true, reason: "искажённое слово (\(info))"), range)
	}

	static func sameStem(_ a: String, _ b: String) -> Bool {
		let x = Array(a.lowercased().replacingOccurrences(of: "ё", with: "е")), y = Array(b.lowercased().replacingOccurrences(of: "ё", with: "е"))
		let common = zip(x, y).prefix { $0 == $1 }.count
		return common >= 3 && Double(common) >= 0.6 * Double(min(x.count, y.count))
	}

	private func droppedWords(_ source: String, _ replacement: String) -> [String] {
		let kept = Set(replacement.lowercased().replacingOccurrences(of: "ё", with: "е")
			.components(separatedBy: CharacterSet.letters.inverted))
		return speller.knownWords(source).filter { !kept.contains($0.lowercased().replacingOccurrences(of: "ё", with: "е")) }
	}

	static func parse(_ raw: String) -> [Edit] {
		var edits: [Edit] = []
		for line in raw.split(whereSeparator: \.isNewline) {
			var l = line.trimmingCharacters(in: .whitespaces)
			while let f = l.first, "-•*".contains(f) { l.removeFirst() }
			let parts = l.components(separatedBy: "=>")
			guard parts.count == 2 else { continue }
			let strip = CharacterSet(charactersIn: " «»\"'`")
			edits.append(Edit(source: parts[0].trimmingCharacters(in: strip), replacement: parts[1].trimmingCharacters(in: strip)))
		}
		return edits
	}

	func apply(_ raw: String, to text: String, hint: String?) -> (String, [EditDecision]) {
		var decisions: [EditDecision] = []
		var accepted: [(Range<String.Index>, String)] = []
		let alignment = hint.map { HintAlignment(text: text, hint: $0) }
		for edit in Self.parse(raw) {
			var (d, r) = judge(edit, text: text, hint: hint, alignment: alignment)
			if let rr = r, accepted.contains(where: { $0.0.overlaps(rr) }) {
				d = EditDecision(edit: edit, accepted: false, reason: "пересекается с другой правкой")
				r = nil
			}
			decisions.append(d)
			if let r { accepted.append((r, edit.replacement.trimmingCharacters(in: .whitespaces))) }
		}
		var out = ""
		var cursor = text.startIndex
		for (r, dst) in accepted.sorted(by: { $0.0.lowerBound < $1.0.lowerBound }) {
			var repl = dst
			let atStart = r.lowerBound == text.startIndex
				|| text[..<r.lowerBound].trimmingCharacters(in: .whitespaces).last.map { ".!?…".contains($0) } == true
			if atStart, let f = repl.first, f.isLowercase, text[r.lowerBound].isUppercase, !TextMetrics.hasLatin(repl) {
				repl = f.uppercased() + repl.dropFirst()
			}
			out += text[cursor..<r.lowerBound]
			out += repl
			cursor = r.upperBound
		}
		out += text[cursor...]
		return (out, decisions)
	}
}
