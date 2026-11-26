import AppKit

@MainActor
enum SessionTest {
	private static var failed = 0

	private static func check(_ ok: Bool, _ what: String) {
		print((ok ? "  ✓ " : "  ✗ ") + what)
		if !ok { failed += 1 }
	}

	private static func wait(_ seconds: Double = 20, until done: () -> Bool) -> Bool {
		let end = Date().addingTimeInterval(seconds)
		while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
		return done()
	}

	private static func type(_ s: Session, _ text: String) {
		var typed = ""
		for ch in text {
			typed.append(ch)
			s.edited(typed)
			RunLoop.main.run(until: Date().addingTimeInterval(0.03))
		}
	}

	static func run() -> Int32 {
		_ = NSApplication.shared
		let s = Session()
		var copied: String?
		s.onCopy = { copied = $0 }
		s.onClose = {}
		s.open(with: nil)
		_ = wait(30) { Engine.shared.isLoaded }

		print("Слово: «замок», Enter, Enter")
		type(s, "замок")
		RunLoop.main.run(until: Date().addingTimeInterval(1.2))
		let t0 = Date()
		s.enter()
		let shownAt = Date().timeIntervalSince(t0)
		check(s.kind == .card, "карточка слова")
		check(wait { !s.streaming && !s.lines.isEmpty }, "варианты пришли: \(s.lines.map(\.term))")
		print(String(format: "  первая строка через %.0f мс после Enter (перевод начат заранее)", shownAt * 1000))
		check(s.enterLabel?.hasPrefix("Copy “") == true, "Enter теперь копирует: \(s.enterLabel ?? "-")")
		_ = s.move(1)
		check(s.selected == 1, "↓ выбирает вторую строку")
		s.enter()
		check(copied == s.lines[1].term, "второй Enter скопировал «\(copied ?? "")»")

		print("Правка после перевода")
		s.edited("замки")
		check(s.isStale && s.enterLabel == "Translate", "старый ответ тускнеет, Enter = «Перевести»")

		print("Раскладка: «pfvjr»")
		s.reset()
		type(s, "pfvjr")
		s.enter()
		check(s.status == WordFix.layoutNote("pfvjr", "замок"), "понял раскладку: \(s.status ?? "-")")
		check(wait { !s.streaming && !s.lines.isEmpty } && s.direction == .toEnglish, "перевёл «замок»: \(s.lines.map(\.term))")

		print("Фраза, «Проще», «Назад», замена слова")
		s.reset()
		let phrase = "Я хочу пожаловаться на доставку, курьер опоздал на два часа."
		type(s, phrase)
		s.enter()
		check(s.kind == .text, "перевод фразы")
		check(wait { !s.streaming && !s.answer.isEmpty }, "перевод: \(s.answer)")
		let first = s.answer
		s.tweak(.simpler)
		check(s.restyling, "«Проще»: старый текст тускнеет до готового нового")
		check(wait(40) { !s.restyling } && (s.answer != first || s.status == Session.nowhere(.simpler)),
		      "проще: \(s.answer) \(s.status.map { "(\($0))" } ?? "") ×\(s.style.simpler)")
		let simpler = s.answer
		s.tweak(.shorter)
		check(wait(40) { !s.restyling } && s.answer != simpler && s.answer.split(separator: " ").count < simpler.split(separator: " ").count,
		      "ещё и короче: \(s.answer)")
		s.back()
		while s.canGoBack { s.back() }
		check(s.answer == first && s.style == Style(), "«Назад» вернул первый вариант")
		let ns = s.answer as NSString
		let r = ns.range(of: "complain")
		if r.location != NSNotFound {
			s.pick(r)
			check(s.overlay == .alternatives, "клик по слову открыл замены")
			check(wait { s.alternatives.count > 1 }, "замены: \(s.alternatives.map(\.term))")
			s.altSelected = min(1, s.alternatives.count - 1)
			let chosen = s.alternatives[s.altSelected].term
			s.enter()
			check(wait { !s.restyling } && s.answer.lowercased().contains(chosen.lowercased()), "фраза перестроена под «\(chosen)»: \(s.answer)")
		} else {
			print("  (в переводе нет «complain» — пропускаю замену)")
		}

		replacements(s)
		styleLimits(s)
		ownRequests(s)

		print("Английский в поле: перевод как перевод, и «Наоборот»")
		s.reset()
		let english = "Yesterday I have went to the office and my boss say me that project is delay."
		s.edited(english)
		s.enter()
		check(wait(30) { !s.streaming } && Reply.hasCyrillic(s.answer), "перевод на русский: \(s.answer)")
		check(s.enterLabel == "Copy" && s.canSwap, "никаких проверок: Enter копирует перевод, есть «Наоборот»")
		let russian = s.answer
		s.swapDirection()
		check(s.input == russian && s.direction == .toEnglish, "«Наоборот»: перевод в поле, направление сменилось")
		check(wait(30) { !s.streaming } && !s.answer.isEmpty && !Reply.hasCyrillic(s.answer), "обратно на английский: \(s.answer)")
		s.back()
		check(s.input == english && s.answer == russian, "«Назад» вернул пару как была")

		print("Окно закрылось во время перевода: перевод дошёл, буфер не тронут")
		s.reset()
		let clip = copied
		s.edited("Посылка пришла мятая, коробка порвана с одного угла.")
		s.enter()
		s.enter()
		s.closed()
		check(wait(40) { !s.streaming && !s.answer.isEmpty }, "перевод дошёл при закрытом окне: \(s.answer)")
		check(copied == clip, "в буфер ничего не ушло")
		s.open(with: nil)
		check(s.input.isEmpty && s.canGoBack, "хоткей: новое пустое поле, прежнее на шаг назад")
		s.back()
		check(s.enterLabel == "Copy" && !s.isStale, "⌘Z: перевод на месте, Enter копирует")

		print("История")
		s.reset()
		check(s.move(1) && s.overlay == .history, "↓ в пустом поле открыл историю (\(s.historyRows.count))")
		s.enter()
		check(s.kind != .none && !s.streaming, "открыл запись мгновенно: «\(s.input)»")

		print(failed == 0 ? "✓ все сценарии прошли" : "✗ провалов: \(failed)")
		return failed == 0 ? 0 : 1
	}

	private static func translated(_ s: Session, _ text: String) -> Bool {
		s.reset()
		s.edited(text)
		s.enter()
		return wait(40) { !s.streaming && !s.answer.isEmpty }
	}

	private static func occurrence(_ s: Session, _ word: String, _ n: Int = 1) -> NSRange? {
		let ns = s.answer as NSString
		var found: [NSRange] = []
		ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { w, r, _, _ in
			if w?.lowercased() == word.lowercased() { found.append(r) }
		}
		return found.indices.contains(n - 1) ? found[n - 1] : nil
	}

	private static func replace(_ s: Session, _ range: NSRange, with own: String) -> Bool {
		s.pick(range)
		guard s.overlay == .alternatives else { return false }
		s.ownWord = own
		s.enter()
		return wait(30) { !s.restyling }
	}

	private static func words(_ s: String) -> [String] { s.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init) }

	private static func noDoubles(_ s: String) -> Bool {
		let w = words(s)
		return !zip(w, w.dropFirst()).contains { $0 == $1 }
	}

	private static func replacements(_ s: Session) {
		print("Замены слова: соседние слова подстраиваются, повтор слова, серия, «Назад»")
		if translated(s, "Эти документы нужно подписать до пятницы."), let r = occurrence(s, "documents") {
			let before = s.answer
			let done = replace(s, r, with: "contract")
			let a = s.answer.lowercased() + " "
			let broken = ["these contract ", "this contracts", "contract need ", "contracts needs"].contains { a.contains($0) }
			check(done && a.contains("contract") && !broken, "«\(before)» → contract: \(s.answer)")
			check(!s.answerMarks.isEmpty, "изменённые слова отмечены: \(s.answerMarks.map { (s.answer as NSString).substring(with: $0) })")
		} else {
			check(false, "перевод с «documents»: \(s.answer)")
		}
		if translated(s, "Мне нравится твоя идея, и твоей сестре она тоже нравится."), occurrence(s, "your", 2) != nil {
			let before = s.answer
			check(replace(s, occurrence(s, "your", 2)!, with: "his") && occurrence(s, "your", 1) != nil && occurrence(s, "his") != nil
			      && occurrence(s, "your", 2) == nil, "второе «your» → his, первое на месте: «\(before)» → «\(s.answer)»")
		} else {
			print("  (в переводе нет двух «your»: \(s.answer) — пропускаю)")
		}
		if translated(s, "Я хочу пожаловаться на доставку, курьер опоздал на два часа.") {
			let first = s.answer
			let late = occurrence(s, "late")
			if let late, replace(s, late, with: "behind schedule") {
				let second = s.answer
				if let complain = occurrence(s, "complain"), replace(s, complain, with: "file a complaint") {
					let a = s.answer.lowercased()
					check(a.contains("behind schedule") && a.contains("complaint") && noDoubles(a) && Reply.words(a) <= Reply.words(first) + 6,
					      "серия замен: «\(first)» → «\(second)» → «\(s.answer)»")
				} else {
					check(false, "вторая замена: \(s.answer)")
				}
				if let two = occurrence(s, "two"), replace(s, two, with: "три") {
					check(!Reply.hasCyrillic(s.answer) && s.answer.lowercased().contains("three") && s.answer.lowercased().contains("behind schedule"),
					      "своё слово по-русски переведено, прошлые замены целы: \(s.answer)")
				}
				while s.canGoBack { s.back() }
				check(s.answer == first, "«Назад» до конца вернул первый перевод")
			} else {
				check(false, "замена «late»: \(s.answer)")
			}
			if let turn = occurrence(s, "complain") {
				check(replace(s, turn, with: "make a complaint") && noDoubles(s.answer) && s.answer.lowercased().contains("make a complaint"),
				      "слово → фраза без повторов: \(s.answer)")
			}
		}
	}

	private static func styleLimits(_ s: Session) {
		print("Кнопки стиля: уровни, предел, сочетания")
		guard translated(s, "Буду очень признателен, если вы найдёте время ознакомиться с документами до пятницы.") else { return check(false, "перевод") }
		var seen = [s.answer]
		var presses = 0
		while presses < 6, !Session.saysLimit(s.status) {
			s.tweak(.simpler)
			presses += 1
			if !s.restyling { break }
			_ = wait(40) { !s.restyling }
			seen.append(s.answer)
			print("    Проще ×\(s.style.simpler): \(s.answer)\(s.status.map { " (\($0))" } ?? "")")
		}
		check(s.style.simpler <= Style.maxLevel, "уровень не выше \(Style.maxLevel): ×\(s.style.simpler)")
		let level = s.style.simpler
		let answer = s.answer
		s.tweak(.simpler)
		if level == Style.maxLevel {
			check(!s.restyling && s.status == Session.nowhere(.simpler) && s.answer == answer, "на пределе модель не гоняется: \(s.status ?? "-")")
		}
		check(seen.allSatisfy { !$0.contains("\n") && !Reply.hasCyrillic($0) }, "ни одной версии с мусором или кириллицей")
		s.tweak(.casual)
		_ = wait(40) { !s.restyling }
		s.tweak(.polite)
		_ = wait(40) { !s.restyling }
		check(!s.answer.isEmpty && !Reply.hasCyrillic(s.answer) && !s.answer.contains("\n"), "Проще ×\(s.style.simpler) + Живее ×\(s.style.casual) + Вежливее ×\(s.style.polite): \(s.answer)")
		check(s.style.casual == 0 && s.style.polite >= 1 && !Session.saysLimit(s.status), "«Вежливее» после «Живее» сменило тон, а не упёрлось: \(s.status ?? "-")")
		var shorter = 0
		while shorter < 5, s.status != Session.nowhere(.shorter) {
			let before = Reply.words(s.answer)
			s.tweak(.shorter)
			shorter += 1
			guard s.restyling else { break }
			_ = wait(40) { !s.restyling }
			check(Session.saysLimit(s.status) || Reply.words(s.answer) < before, "Короче ×\(s.style.shorter): \(s.answer)\(s.status.map { " (\($0))" } ?? "")")
		}
		check(s.style.shorter <= Style.maxLevel && s.status == Session.nowhere(.shorter), "«Короче» упёрлось в предел: \(s.status ?? "-")")
	}

	private static func ownRequests(_ s: Session) {
		print("Своя просьба: всегда один текст")
		for request in ["дай три варианта", "объясни, почему здесь about", "напиши две версии: формальную и простую"] {
			guard translated(s, "Я хочу пожаловаться на доставку, курьер опоздал на два часа.") else { return check(false, "перевод") }
			let first = s.answer
			s.startAsk()
			s.askText = request
			s.enter()
			_ = wait(40) { !s.restyling }
			let a = s.answer
			check(!a.contains("\n") && !Reply.hasCyrillic(a) && !a.lowercased().contains("note") && (a != first || s.status == Session.nothingChanged),
			      "«\(request)»: \(a)\(s.status.map { " (\($0))" } ?? "")")
		}
		print("Несколько строк: «Вежливее» не склеивает их")
		if translated(s, "Привет, пришли отчёт до пятницы.\nСпасибо!") {
			let lines = s.answer.components(separatedBy: "\n").count
			s.tweak(.polite)
			_ = wait(40) { !s.restyling }
			check(s.answer.components(separatedBy: "\n").count == lines, "строк было \(lines), стало: \(s.answer.replacingOccurrences(of: "\n", with: " ⏎ "))")
		}
	}
}
