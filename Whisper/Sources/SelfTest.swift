import AppKit
import SwiftUI

enum SelfTest {
	private static var failures = 0
	private static var passed = 0

	private static func check(_ ok: Bool, _ what: String, file: String = #fileID, line: Int = #line) {
		if ok {
			passed += 1
		} else {
			failures += 1
			print("FAIL \(what) (\(file):\(line))")
		}
	}

	static func run() -> Int32 {
		hotkey()
		polish()
		dictionary()
		validator()
		terms()
		segmentation()
		hud()
		historyList()
		continuation()
		english()
		detokenizer()
		print("selftest: \(passed) passed, \(failures) failed")
		return failures == 0 ? 0 : 1
	}

	private static func hotkey() {
		var h = HotkeyLogic()
		check(h.handle(.down, at: 0) == .start, "down starts")
		check(h.handle(.up, at: 1.2) == .stop, "long hold then release stops (push-to-talk)")
		check(h.state == .idle, "idle after stop")

		check(h.handle(.down, at: 10) == .start, "tap starts")
		check(h.handle(.up, at: 10.1) == .none, "short tap latches")
		check(h.state == .latched, "latched")
		check(h.handle(.down, at: 20) == .stop, "next press stops hands-free")
		check(h.handle(.up, at: 20.1) == .none, "release after stop is ignored")
		check(h.state == .idle, "idle after hands-free stop")

		check(h.handle(.down, at: 30) == .start, "start before chord")
		check(h.handle(.chord, at: 30.05) == .cancel, "⌥+key cancels")
		check(h.handle(.up, at: 30.2) == .none, "release after chord ignored")

		check(h.handle(.down, at: 40) == .start, "start before esc")
		check(h.handle(.escape, at: 41) == .cancel, "esc cancels while holding")
		check(h.handle(.escape, at: 42) == .cancelPending, "esc when idle cancels pending insertion")

		_ = h.handle(.down, at: 50)
		_ = h.handle(.up, at: 50.1)
		check(h.handle(.chord, at: 55) == .none, "typing during hands-free does not cancel")
		check(h.handle(.escape, at: 56) == .cancel, "esc cancels hands-free")

		check(h.handle(.down, at: 60) == .start, "start before a slow tap")
		check(h.handle(.up, at: 60.5, heardSpeech: false) == .none && h.state == .latched, "slow quiet tap latches")
		check(h.handle(.down, at: 70) == .stop, "the next press stops it")
		_ = h.handle(.down, at: 80)
		check(h.handle(.up, at: 80.5, heardSpeech: true) == .stop, "a short push-to-talk with speech stops")
		_ = h.handle(.down, at: 90)
		check(h.handle(.up, at: 91.2, heardSpeech: false) == .stop, "a long silent hold is push-to-talk all the same")

		_ = h.handle(.down, at: 100)
		_ = h.handle(.up, at: 100.1, heardSpeech: false)
		check(h.handle(.down, at: 100.3, heardSpeech: false) == .none && h.state == .latched, "doubled tap keeps recording")
		check(h.handle(.up, at: 100.4, heardSpeech: false) == .none, "its release is ignored")
		check(h.handle(.down, at: 100.5, heardSpeech: true) == .stop, "a press after speech stops even early")
		_ = h.handle(.down, at: 110)
		_ = h.handle(.up, at: 110.1, heardSpeech: false)
		check(h.handle(.down, at: 111, heardSpeech: false) == .stop, "a later press stops a silent hands-free recording")
	}

	private static func polish() {
		check(TextPolish.finalize("Э-э, я думаю , что это ммм хорошо .") == "Я думаю, что это хорошо.", "hesitations")
		check(TextPolish.finalize("высота 4 892 м и 5 мм.") == "высота 4 892 м и 5 мм.", "metres survive")
		check(TextPolish.finalize("А-а, многовато надписей, а-а хочу, чтобы ааа ты м-м поправил, um, это") == "Многовато надписей, хочу, чтобы ты поправил, это", "drawn-out а and м go")
		check(TextPolish.finalize("А я думаю, а он нет") == "А я думаю, а он нет", "the word «а» stays")
		check(TextPolish.join([" Привет. ", "", "Как дела?"]) == "Привет. Как дела?", "join")
		let speller = Speller()
		func join(_ parts: [String]) -> String { TextPolish.join(parts, isWord: speller.isWord) }
		check(join(["И мне кажется, что", "Она плохо их воспринимает."]) == "И мне кажется, что она плохо их воспринимает.",
		      "a segment continuing a sentence starts lowercase")
		check(join(["Вчера я был в", "Москве по делам."]) == "Вчера я был в Москве по делам.", "names keep the capital at a joint")
		check(join(["Сделал всё.", "Теперь отдыхаю."]) == "Сделал всё. Теперь отдыхаю.", "a new sentence keeps the capital")
		check(join(["Он сказал «да».", "Потом ушёл."]) == "Он сказал «да». Потом ушёл.", "sentence end before a quote")
		check(join(["Открой проект в", "Xcode и собери."]) == "Открой проект в Xcode и собери.", "Latin terms untouched")
		check(TextPolish.finalize("Эм, ну ладно") == "Ну ладно", "leading hesitation, capitalized")
		check(TextPolish.finalize("и ещё одно") == "и ещё одно", "lowercase start kept")
		check(TextPolish.finalize("Это хорошо, э.") == "Это хорошо.", "hesitation before the final period")
		check(TextPolish.finalize("Пишем на .NET и Python .") == "Пишем на .NET и Python.", ".NET keeps its dot")
	}

	private static func dictionary() {
		let d = UserDictionary()
		d.parse("# comment\nклод код => Claude Code\nгитхаб -> GitHub\n")
		check(d.apply("Запусти клод-код и открой Гитхаб.") == "Запусти Claude Code и открой GitHub.", "dictionary")
		check(d.terms == ["Claude Code", "GitHub"], "dictionary terms")
		check(d.apply("гитхабе") == "гитхабе", "whole words only")
	}

	private static func validator() {
		let v = EditValidator(speller: Speller())
		func run(_ raw: String, _ text: String, _ hint: String?) -> String { v.apply(raw, to: text, hint: hint).0 }
		check(run("гитхабе => GitHub", "Открой пул реквест на гитхабе.", nil) == "Открой пул реквест на GitHub.", "latin term")
		check(run("сможет => не сможет", "Он сможет прийти.", "Он сможет прийти.") == "Он сможет прийти.", "negation blocked")
		check(run("прислать => присла", "Не могли бы вы прислать договор?", "Не могли бы вы присла договор?")
			== "Не могли бы вы прислать договор?", "valid word not replaced by a garble")
		check(run("латынском => латинском", "на латынском языке", "на латинском языке") == "на латинском языке", "garble fixed")
		check(run("Ютуб => YouTube", "ссылку на ютуп.", "ссылку на Ютуб.") == "ссылку на YouTube.", "fragment from hint aligned")
		check(run("хроме => Chrome", "открыто в хроме.", "открыто в хроме.") == "открыто в Chrome.", "brand in Latin")
		check(run("смёрджил => merged", "ты уже смёрджил ветку?", nil) == "ты уже смёрджил ветку?", "no anglicizing slang verbs")
		check(run("ветку => branch", "смёрджил ветку?", nil) == "смёрджил ветку?", "no translation of real words")
		check(run("линтер => linter", "прогони линтер.", nil) == "прогони линтер.", "slang stays Cyrillic")
		check(run("Бэкин => бэкенд", "а Бэкин оставили", "а Бэкента ставили") == "а бэкенд оставили", "slang counts as a word")
		check(run("гид-статус => git status", "выполни гид-статус.", "выполни Git Status.") == "выполни git status.", "multiword command")
		check(run("докер образ => Docker-Image\nизлоид => Docker", "пересобрать докер образ излоид на прод.",
		          "пересобрать докер образ и задеплоить на прод.") == "пересобрать докер образ излоид на прод.",
		      "no partial translation, hint must match at the same place")
		check(run("питоне => Python", "оставили на питоне.", "оставили на питоне.") == "оставили на Python.", "glossary term")
		check(run("на латынском языке => на латинском", "на латынском языке", "на латинском языке") == "на латынском языке",
		      "an edit may not drop a real word")
		check(run("докер образ => Docker", "собери докер образ.", "собери докер образ.") == "собери докер образ.",
		      "a term may not swallow a neighbouring word")
		check(run("гид-статус => git status", "выполни гид-статус.", "выполни Git Status.") == "выполни git status.",
		      "words that sound like the term may go")
		check(run("истёк => истек", "токен истёк.", nil) == "токен истёк.", "ё kept")
		check(run("Казабранка => Casablanca", "в Казабранке и Казабранка.", "в Казабланке") == "в Казабранке и Казабранка.",
		      "place names stay Cyrillic")
		check(run("Poynt Morion => Point Marion", "между Poynt Morion и", nil) == "между Point Marion и", "Latin already heard")
		var withUser = EditValidator(speller: Speller())
		withUser.userTerms = ["grafana"]
		check(withUser.apply("графана => Grafana", to: "открой графана", hint: nil).0 == "открой Grafana", "user term allowed")
		check(run("Клод-Code => Claude Code", "Запусти клод-код в терминале.", nil) == "Запусти Claude Code в терминале.", "misquoted fragment located")
		check(run("нет", "Всё хорошо.", nil) == "Всё хорошо.", "no edits")
		check(run("Google Meet => Google Meet", "Созвон в Google Mid.", "Созвон в Google Meet.") == "Созвон в Google Meet.",
		      "fixed form quoted as the source")
		check(run("а => б\nб => в", "", nil) == "", "empty text")
		check(run("не казалось => не оказалось", "Там никого не казалось.", "Там никого не оказалось.") == "Там никого не оказалось.",
		      "a real word misheard as another one, confirmed by the second transcript")
		check(run("отдельные => отдельной", "выделены в отдельные дисциплины", "выделены в отдельной дисциплины")
			== "выделены в отдельные дисциплины", "endings stay the main recognizer's call")
		check(run("на латинском языке => на латинском", "на латинском языке.", "на латинском.") == "на латинском языке.",
		      "a confirmed fix may not drop a word")
		check(run("Слалом => с лалом", "Её первым соревнованием был слалом.", "Её первым соревнованием был с лалом.")
			== "Её первым соревнованием был слалом.", "a word is not split into non-words")
		check(run("дотуда => до туда", "не могли добраться дотуда.", "не могли добраться до того.") == "не могли добраться дотуда.",
		      "a real word is not split without confirmation")
		check(run("налоги => на логи", "Можешь сильно налоги не смотреть.", "Можешь сильно на логи не смотреть.")
			== "Можешь сильно на логи не смотреть.", "a confirmed split into real words")
		check(run("толпа => трупа", "разозлённая толпа женщин", "разозлённая трупа женщин") == "разозлённая толпа женщин",
		      "a confirmed swap still has to sound alike")
		check(run("стол => стул", "Поставь стол к окну.", "Поставь стол к окну.") == "Поставь стол к окну.",
		      "a real word is not replaced without confirmation")
		check(run("комиты => коммиты", "Сделай комиты и всё.", "Сделай коммит и всё.") == "Сделай коммиты и всё.",
		      "a near-identical spelling fix needs no confirmation")
		check(run("докероб изодиплоид на прот => Docker-образ и задеплоить на прод",
		          "Нужно пересобрать докероб изодиплоид на прот.", "Нужно пересобрать докер образ и задеплоить на прод.")
			== "Нужно пересобрать Docker-образ и задеплоить на прод.", "garbled jargon with hint")
	}

	private static func terms() {
		let cases: [(String, String)] = [
			("Открой пул реквист на гитхабе и посмотри.", "Открой pull request на GitHub и посмотри."),
			("Скинь в телеграм, я после зума посмотрю.", "Скинь в Telegram, я после Zoom посмотрю."),
			("Пересобери докер-образ и задеплой.", "Пересобери Docker-образ и задеплой."),
			("Напиши скрипт на питоне.", "Напиши скрипт на Python."),
			("В зоопарке живёт огромный питон.", "В зоопарке живёт огромный питон."),
			("Купи редиску и редис на рынке.", "Купи редиску и редис на рынке."),
			("Перезапусти редис на сервере.", "Перезапусти Redis на сервере."),
			("Открой иксикод и запусти сборку.", "Открой Xcode и запусти сборку."),
			("Попроси чат джипити, а потом клод код.", "Попроси ChatGPT, а потом Claude Code."),
			("Гит статус показывает изменения.", "Git status показывает изменения."),
			("Ты можешь погуглить это?", "Ты можешь погуглить это?"),
			("Запушь в джиру и фигму.", "Запушь в Jira и Figma."),
			("Мой гид по Риму был отличный.", "Мой гид по Риму был отличный."),
			("Кубернетис под рестартится.", "Kubernetes под рестартится."),
			("Подключи эйрподсы к макбуку.", "Подключи AirPods к MacBook."),
			("У меня Macbook и Iphone, код на Github.", "У меня MacBook и iPhone, код на GitHub."),
			("Открой Word и напиши письмо.", "Открой Word и напиши письмо."),
			("Git показывает изменения, поставь NPM пакет.", "Git показывает изменения, поставь npm пакет."),
			("Iphone сел. Обнови IOS.", "iPhone сел. Обнови iOS."),
			("Айфон завис, перезагрузи.", "iPhone завис, перезагрузи."),
			("Мне пришла телеграмма от бабушки.", "Мне пришла телеграмма от бабушки."),
			("Налей воды из графина.", "Налей воды из графина."),
			("Мы гуляли по Версалю.", "Мы гуляли по Версалю."),
			("Мой друг Джейсон приехал.", "Мой друг Джейсон приехал."),
			("В джейсоне не хватает поля, поправь код.", "В JSON не хватает поля, поправь код."),
		]
		let speller = Speller()
		for (input, expected) in cases {
			let out = TermMatcher.apply(input, isRussianWord: speller.isWord)
			check(out == expected, "terms: «\(input)» → «\(out)»")
		}
	}

	private static func segmentation() {
		func run(_ plan: [(seconds: Double, speech: Bool)]) -> [(Double, Double)] {
			var audio: [Float] = []
			var rng = SystemRandomNumberGenerator()
			for (sec, speech) in plan {
				let amp: Float = speech ? 0.3 : 0.001
				for _ in 0..<Int(sec * 16000) { audio.append(Float.random(in: -amp...amp, using: &rng)) }
			}
			let q = DispatchQueue(label: "selftest.asr")
			let s = DictationSession(speechProbability: { f in
				let rms = sqrt(f.reduce(0) { $0 + $1 * $1 } / Float(f.count))
				return rms > 0.05 ? 0.95 : 0.05
			}, asrQueue: q, recognize: { _ in ("x", nil) }, quickRecognize: { _ in AsrResult(text: "", tokens: []) })
			var i = 0
			while i < audio.count {
				s.append(Array(audio[i..<min(audio.count, i + 1600)]))
				i += 1600
			}
			return s.finish().map { (Double($0.start) / 16000, Double($0.end) / 16000) }
		}
		var plan: [(Double, Bool)] = [(1.0, false)]
		for _ in 0..<6 { plan += [(2.7, true), (0.3, false)] }
		plan += [(8.0, true), (1.0, false)]
		let segs = run(plan)
		let firstEnd = segs.first?.1 ?? 0
		check(segs.count >= 2 && firstEnd < 21, "cut at the last breath, not mid-word at the hard limit (first segment ends at \(firstEnd))")
		let segs2 = run([(0.5, false), (19.0, true), (0.8, false), (3.0, true), (1.0, false)])
		check(segs2.count == 2 && abs((segs2.first?.1 ?? 0) - 20.2) < 0.6, "soft cut in the 0.8 s pause: \(segs2)")
		check(run([(5.0, false)]).isEmpty, "silence gives no segments")
		let preview = [("▁При", 100), ("вет", 200), (",", 300), ("▁мир", 900), ("!", 950)].map { (piece: $0.0, at: $0.1) }
		let (head, rest) = DictationSession.split(preview, at: 600)
		check(head == "Привет," && Detokenizer.join(rest.map(\.piece)) == "мир!", "preview split at a cut: «\(head)» | \(rest)")
		let (head2, rest2) = DictationSession.split([("▁раз", 100), (",", 700), ("▁два", 900)].map { (piece: $0.0, at: $0.1) }, at: 600)
		check(head2 == "раз" && rest2.map(\.piece) == ["▁два"], "punctuation right after a cut is not carried over")
	}

	private static func continuation() {
		MainActor.assumeIsolated {
			let speller = Speller()
			Inserter.isWord = { speller.isWord($0) }
			let cases: [(String, String?, String)] = [
				("Как дела?", "Привет, ", "как дела?"),
				("Как дела?", "Привет,", " как дела?"),
				("Москва большая.", "и ", "Москва большая."),
				("Я думаю.", "Ну", " Я думаю."),
				("Второе предложение.", "Первое.", " Второе предложение."),
				("Новый абзац.", "Конец.\n", "Новый абзац."),
				("GitHub упал.", "кстати, ", "GitHub упал."),
				("ВВП растёт.", "а ", "ВВП растёт."),
				("Привет.", nil, "Привет."),
			]
			for (text, before, want) in cases {
				let got = Inserter.adapt(text, before: before)
				check(got == want, "continuation «\(before ?? "nil")» + «\(text)» → «\(got)»")
			}
		}
	}

	private static func hud() {
		let long = String(repeating: "слово ", count: 100) + "конец"
		let t = MainActor.assumeIsolated { HUDContent.tail(long) }
		check(t.hasPrefix("…") && t.hasSuffix("конец") && t.count <= 232 && !t.contains("…сл") || t.hasPrefix("…слово"),
		      "pill shows the end of a long text from a word boundary")
		check(MainActor.assumeIsolated { HUDContent.tail("коротко") } == "коротко", "short text untouched")
		let parts = MainActor.assumeIsolated { HUDContent.tail("Готово уже", "а это ещё нет") }
		check(parts == ("Готово уже", " а это ещё нет"), "pill: recognized and draft parts \(parts)")
		let longParts = MainActor.assumeIsolated { HUDContent.tail(long, "хвост") }
		check(longParts.0.hasPrefix("…") && longParts.0.hasSuffix("конец") && longParts.1 == " хвост",
		      "pill: long text cut at the start, draft kept whole \(longParts.0.suffix(12))|\(longParts.1)")
		check(MainActor.assumeIsolated { HUDContent.tail("", "только черновик") } == ("", "только черновик"), "pill: draft only")
	}

	private static func historyList() {
		MainActor.assumeIsolated {
			_ = NSApplication.shared
			let rows = (0..<47).map { BarWheelRow(title: "Диктовка \($0)") {} }
			let wheel = BarWheel(rows: rows, visible: 9)
			let settle = { for _ in 0..<240 where wheel.advance(1.0 / 60) {} }
			wheel.scrollBy(3)
			wheel.advance(1.0 / 60)
			check(wheel.model.scroll > 0 && wheel.model.scroll < 3, "the wheel turns gradually: \(wheel.model.scroll)")
			settle()
			check(wheel.model.scroll == 3, "and stops exactly on a row")
			wheel.scrollBy(-100)
			check(wheel.scrollTarget == 0, "the wheel stops at the first row")
			wheel.scrollBy(1000)
			settle()
			let g = wheel.geometry
			check(wheel.model.scroll == 38, "and at the last")
			check(g.row(at: g.height - 1, scroll: wheel.model.scroll) == 46, "the last dictation can be reached")
			check(g.row(at: 1, scroll: 0) == 0 && g.row(at: -1, scroll: 0) == nil && g.row(at: g.height, scroll: 0) == nil, "rows answer only inside the wheel")
			var same = true
			for s in stride(from: 0.0, through: 30, by: 0.37) {
				for i in g.range(scroll: s) where abs(Double(i) - s - 4) <= 3 {
					same = same && g.row(at: g.centerY(of: Double(i), scroll: s), scroll: s) == i
				}
			}
			check(same, "the pointer picks the row drawn under it")
			var ordered = true
			for i in 1..<47 { ordered = ordered && g.centerY(of: Double(i), scroll: 10) >= g.centerY(of: Double(i - 1), scroll: 10) }
			check(ordered, "rows keep their order on the drum")
			let off = g.fx(row: 4, scroll: 0, lens: 0, lensOn: 0), on = g.fx(row: 4, scroll: 0, lens: 4, lensOn: 1)
			check(off.x == 0 && off.scale == 1 && on.x == 7 && on.scale == 1 && on.blur == 0 && on.opacity == 1, "the row under the pointer comes forward, none without a pointer")
			wheel.setVisible(3)
			settle()
			check(wheel.model.visible == 3 && wheel.model.scroll == 38, "the list rolls up without jumping")
			wheel.scrollBy(1000)
			settle()
			check(wheel.model.scroll == 44, "a rolled-up list reaches its end too")
			wheel.setVisible(9)
			settle()
			check(wheel.model.scroll == 38 && wheel.model.visible == 9, "unrolling at the end keeps full rows")
			check(BarWheel(rows: rows, visible: 5, checked: 30).model.scroll == 28, "a list opens on its current choice")
			let picker = BarWheel(rows: Array(rows.prefix(4)), visible: 5, checked: 2, picker: true)
			let settlePicker = { for _ in 0..<240 where picker.advance(1.0 / 60) {} }
			var geometry = picker.geometry
			check(picker.model.scroll == 2 && picker.model.lens == 2 && picker.model.lensOn == 1, "a picker opens with the current choice on the band")
			let chosen = geometry.fx(row: 2, scroll: 2, lens: 2, lensOn: 1), far = geometry.fx(row: 0, scroll: 2, lens: 2, lensOn: 1)
			check(chosen.x == 7 && chosen.tilt == 0 && abs(chosen.opacity - 1) < 1e-9 && far.tilt < 0 && far.opacity < 0.8 && far.blur > 0, "the chosen row comes forward, the others bend away")
			var inside = true
			for x in stride(from: 0.0, through: 3, by: 0.25) {
				for i in 0..<4 { inside = inside && geometry.centerY(of: Double(i), scroll: x) > 0 && geometry.centerY(of: Double(i), scroll: x) < geometry.height }
			}
			check(inside, "a short picker keeps all its rows in sight wherever it turns")
			picker.pointer(BarWheelGeometry.pitch * 0.5)
			settlePicker()
			check(picker.model.scroll == 0, "the pointer turns a short picker")
			picker.pointer(nil)
			settlePicker()
			check(picker.model.scroll == 2, "and it comes back to the current choice")
			picker.scrollBy(1)
			settlePicker()
			check(picker.model.scroll == 3, "the mouse wheel turns it too")
			picker.scrollBy(10)
			check(picker.scrollTarget == 3, "up to the last row")
			let longPicker = BarWheel(rows: rows, visible: 5, checked: 30, picker: true)
			geometry = longPicker.geometry
			check(longPicker.model.scroll == 30 && geometry.height == 5 * BarWheelGeometry.pitch, "a long picker opens on its choice, five rows tall")
			check(abs(geometry.centerY(of: 30, scroll: 30) - geometry.height / 2) < 1e-6, "and holds it in the middle")
			longPicker.pointer(5)
			check(longPicker.scrollTarget == 30, "the pointer does not turn a long picker")
			let short = BarWheel(rows: Array(rows.prefix(4)), visible: 5, checked: 3)
			check(short.model.visible == 4 && short.model.scroll == 0, "a short list shows all its rows and does not scroll")
		}
		guard ProcessInfo.processInfo.environment["WHISPER_DIR"] != nil else { return }
		MainActor.assumeIsolated {
			AppPaths.ensureData()
			let long = String(repeating: "очень длинная диктовка ", count: 12)
			var items = (0..<49).map { HistoryItem(text: "Диктовка \($0)", date: Date(), app: nil, seconds: 1) }
			items.insert(HistoryItem(text: long, date: Date(), app: nil, seconds: 1), at: 1)
			try? JSONEncoder.iso.encode(items).write(to: History.url)
			let controller = Controller()
			var closed = 0
			let model = MenuPanelModel(controller: controller, close: { closed += 1 }, hint: { _, _ in })
			guard let wheel = model.history else {
				check(false, "the panel has a history wheel")
				return
			}
			let settle = { for _ in 0..<240 where wheel.advance(1.0 / 60) {} }
			check(wheel.model.visible == 3 && wheel.rows.count == 50, "three rows at first, all fifty on the wheel")
			check(wheel.rows.prefix(4).map(\.key) == ["⌘1", "⌘2", "⌘3", nil], "⌘1–3 on the three recent dictations")
			check(wheel.rows[0].hint == nil && wheel.rows[1].hint == long, "the bubble only for a text the row cuts")
			model.toggleExpanded()
			settle()
			let half = (NSScreen.main?.visibleFrame.height ?? 800) / 2
			check(wheel.model.visible == Double(MenuPanelModel.expandedRows) && wheel.geometry.height <= half, "«Ещё» unrolls, at most half a screen")
			model.cancel()
			settle()
			check(!model.expanded && wheel.model.visible == 3 && closed == 0, "Esc rolls it up first and leaves the panel open")

			check(model.minutes == 5, "unload: the default is 5 minutes")
			model.open(.unload)
			check(model.picker?.rows.map(\.title) == ["1 min", "3 min", "5 min", "10 min"] && model.picker?.checked == 2, "unload: four choices, the current one ticked")
			model.picker?.rows.first?.pick()
			check(model.choice == nil && model.minutes == 1 && closed == 0, "unload: a choice closes only its list")
			check(controller.settings.unloadMinutes == 1 && controller.engine.idleUnload == 60, "unload: the choice reaches the engine")
			let saved = (try? Data(contentsOf: AppPaths.data.appendingPathComponent("settings.json")))
				.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
			check(saved?["unloadMinutes"] as? Int == 1, "unload: the choice is saved")
			wheel.frame = NSRect(x: 0, y: 0, width: 200, height: 80)
			wheel.pointer(30)
			settle()
			check(wheel.model.lensOn == 1 && wheel.hitTest(NSPoint(x: 5, y: 5)) === wheel, "the history answers the pointer while nothing lies over it")
			model.open(.microphone)
			check(model.choice == .microphone, "microphone: the list opens")
			settle()
			check(wheel.model.lensOn == 0 && wheel.hitTest(NSPoint(x: 5, y: 5)) == nil, "the history is out of play under a list to choose from")
			model.cancel()
			check(model.choice == nil && closed == 0 && wheel.isActive, "Esc closes the list first, the history is back")
			model.cancel()
			check(closed == 1, "then the panel")

			model.clearHistory()
			check(controller.history.items.isEmpty && model.historyCount == 0 && !model.canExpand, "«Очистить историю» clears it")
			check(!model.copyRecent(0), "nothing to copy from a cleared history")

			let host = NSHostingView(rootView: MenuPanelView(model: MenuPanelModel(controller: controller, close: {}, hint: { _, _ in })))
			check(host.fittingSize.width == MenuPanelView.width && host.fittingSize.height < 470, "the panel's size: \(host.fittingSize)")
			let c = controller.settings
			check(c.llmEnabled && c.livePreview && c.showHUD && c.sounds && c.dropFinalPeriod, "corrections, live text, pill and sounds on, no final period")
		}
	}

	private static func english() {
		check(Engine.isEnglish("Okay, let's meet tomorrow at seven.", main: "Okay, Let's Med Tomorod Seven"), "English speech goes to Parakeet")
		check(!Engine.isEnglish("Открой пул реквест на гитхабе.", main: "Открой пул реквист на гитхабе."), "Russian stays with GigaAM")
		check(!Engine.isEnglish("Open the pull request.", main: "Открой пул реквест."), "both recognizers must agree on Latin")
		check(!Engine.isEnglish("GitHub", main: "GitHub"), "a lone term is not English speech")
		check(!Engine.isEnglish("Залей фикс на GitHub и скинь в Slack.", main: "Залей фикс на гитхаб и скинь в слак."), "Russian with terms")
		check(abs(TextMetrics.latinShare("abc где") - 0.5) < 1e-9 && TextMetrics.latinShare("123") == 0, "latin share")
	}

	private static func detokenizer() {
		check(Detokenizer.join(["▁При", "вет", ",", "▁мир", "!"]) == "Привет, мир!", "detokenize punctuation")
		check(Detokenizer.join(["▁это", "▁", "—", "▁тест"]) == "это — тест", "dash keeps spaces")
		check(Detokenizer.join(["▁сказал", "▁«", "при", "вет", "»"]) == "сказал «привет»", "guillemets")
	}
}
