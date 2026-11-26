import AppKit
import Observation

@MainActor @Observable
final class Session {
	enum Kind: String, Codable, Equatable { case none, card, text }
	enum Overlay: String, Codable, Equatable { case none, history, alternatives, ask }

	private(set) var input = ""
	private(set) var inputVersion = 0

	private(set) var kind: Kind = .none
	private(set) var answeredInput: String?
	private(set) var direction: Direction = .toEnglish
	private(set) var status: String?
	private(set) var failure: String?
	private(set) var loadingModel = false
	private(set) var streaming = false
	private(set) var restyling = false

	private(set) var lines: [CardLine] = []
	var selected = 0

	private(set) var answer = ""
	private(set) var answerMarks: [NSRange] = []
	private(set) var style = Style()
	private var undo: [(style: Style, answer: String, marks: [NSRange])] = []

	private(set) var overlay: Overlay = .none
	private(set) var picked: NSRange?
	private(set) var alternatives: [CardLine] = []
	private(set) var alternativesPending = false
	var altSelected = 0
	var ownWord = ""
	var askText = ""
	private(set) var historyRows: [HistoryItem] = []
	var historySelected: Int?

	private(set) var previous: [Draft] = []
	static let keptDrafts = 3
	private var origin: String?
	private var pendingResume: Draft.Resume?
	private var freshField = false
	private(set) var isOpen = false

	var onCopy: ((String) -> Void)?
	var onClose: (() -> Void)?
	var onFocusInput: (() -> Void)?
	var onStartOver: (() -> Void)?

	var isStale: Bool { answeredInput != nil && answeredInput != input }

	static let loadingNote = "Loading the model…"
	var waitsForModel: Bool { loadingModel || (engine.state.reading && streaming) }
	var statusLine: String? { engine.state.reading && (restyling || alternativesPending) ? Self.loadingNote : status }

	private(set) var inputOpened = false
	var inputFolded: Bool { !inputOpened && kind != .none && !isStale }

	func openInput() {
		inputOpened = true
	}
	var canGoBack: Bool { (!undo.isEmpty || canReturn) && !isStale }
	private var canReturn: Bool {
		guard !previous.isEmpty, overlay == .none else { return false }
		return input.isEmpty ? freshField : answeredInput == input
	}
	var copyPromised: Bool { copyWhenDone }

	var enterLabel: String? {
		switch overlay {
		case .history: return historySelected != nil ? "Open" : (input.isEmpty ? nil : "Translate")
		case .alternatives: return altSelected == 0 && ownWord.isEmpty ? "Keep" : "Replace"
		case .ask: return "Apply"
		case .none: break
		}
		if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
		if restarting { return nil }
		if failure != nil && answeredInput == input {
			if !repairable { return nil }
			return restartFailed ? "Restart the app" : "Restart"
		}
		if failure != nil { return "Translate" }
		if answeredInput != input { return "Translate" }
		switch kind {
		case .none: return "Translate"
		case .card: return lines.indices.contains(selected) ? "Copy “\(lines[selected].term)”" : nil
		case .text: return "Copy"
		}
	}

	private final class Job {
		let input: String
		let kind: Kind
		var token = CancelToken()
		var text = ""
		var lines: [CardLine] = []
		var done = false
		var error: Error?
		var shown = false
		var note: String?
		init(input: String, kind: Kind) {
			self.input = input
			self.kind = kind
		}
	}

	private var job: Job?
	private var sideToken: CancelToken?
	private var speculate: DispatchWorkItem?
	private var copyWhenDone = false
	private let engine = Engine.shared
	private let history = History.shared

	func open(with selection: String?) {
		isOpen = true
		engine.prepare()
		guard let selection, !selection.isEmpty else {
			startOver(.fresh)
			return
		}
		if selection != input {
			startOver(.selected(selection))
			enter()
			return
		}
		if failure != nil || answeredInput != input { translate() }
		resume()
	}

	func closed() {
		isOpen = false
		copyWhenDone = false
		speculate?.cancel()
		speculate = nil
		saveNow()
	}

	func keyboardLeft() {
		copyWhenDone = false
	}

	private func resume() {
		if let r = pendingResume {
			pendingResume = nil
			switch r {
			case .translate:
				if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { translate() }
			case .alternatives:
				if overlay == .alternatives, let range = picked { requestAlternatives(range) }
			}
		}
		if overlay == .history {
			refreshHistory()
			if historyRows.isEmpty {
				overlay = .none
				historySelected = nil
			} else if let i = historySelected {
				historySelected = min(i, historyRows.count - 1)
			}
		}
		if overlay != .history, answeredInput != input, job?.input != input,
		   !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			scheduleSpeculation()
		}
	}

	enum StartOver {
		case fresh
		case copied
		case cleared
		case history(HistoryItem)
		case selected(String)
		case picture(String)
		case swapped(String)
	}

	func startOver(_ why: StartOver) {
		switch why {
		case .fresh:
			keepAside(worthKeeping)
			wipe()
			freshField = true
		case .copied:
			wipe()
		case .cleared:
			cancelAll()
			clearResult()
			askText = ""
			ownWord = ""
			origin = nil
			pendingResume = nil
			if overlay == .history { refreshHistory() } else { overlay = .none }
		case let .history(item):
			wipe()
			setInput(item.input)
			origin = item.input
			startJob(adopt: true)
		case let .selected(text), let .picture(text):
			keepAside(worthKeeping)
			wipe()
			setInput(text)
			if case .selected = why { origin = text }
		case let .swapped(text):
			keepAside(true)
			wipe()
			setInput(text)
			origin = text
		}
		onStartOver?()
	}

	private func keepAside(_ worth: Bool) {
		guard worth else { return }
		previous.append(draft)
		if previous.count > Self.keptDrafts { previous.removeFirst(previous.count - Self.keptDrafts) }
	}

	private var worthKeeping: Bool {
		guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
		let untouched = origin == input && undo.isEmpty && style.isEmpty && ownWord.isEmpty && askText.isEmpty
		return !untouched
	}

	func reset() {
		wipe()
		previous = []
	}

	private func wipe() {
		cancelAll()
		setInput("")
		clearResult()
		overlay = .none
		historySelected = nil
		askText = ""
		ownWord = ""
		origin = nil
		pendingResume = nil
	}

	private func clearResult() {
		inputOpened = false
		restarting = false
		restartRun += 1
		restartFailed = false
		repairable = true
		freshField = false
		kind = .none
		answeredInput = nil
		status = nil
		failure = nil
		loadingModel = false
		streaming = false
		restyling = false
		lines = []
		selected = 0
		answer = ""
		answerMarks = []
		style = Style()
		undo = []
		picked = nil
		alternatives = []
		alternativesPending = false
		altSelected = 0
		direction = .toEnglish
	}

	private func cancelAll() {
		job?.token.cancel()
		job = nil
		sideToken?.cancel()
		sideToken = nil
		speculate?.cancel()
		speculate = nil
		copyWhenDone = false
	}

	private func setInput(_ text: String) {
		input = text
		inputVersion += 1
	}

	func edited(_ text: String) {
		guard text != input else { return }
		input = text
		freshField = false
		copyWhenDone = false
		if overlay == .alternatives { closeAlternatives() } else if overlay == .ask { overlay = .none }
		if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			startOver(.cleared)
			return
		}
		if overlay == .history {
			refreshHistory()
			historySelected = nil
			if historyRows.isEmpty { overlay = .none }
		}
		if text == answeredInput, streaming, job?.input != text {
			translate()
			return
		}
		scheduleSpeculation()
	}

	private func scheduleSpeculation() {
		speculate?.cancel()
		let work = DispatchWorkItem { [weak self] in
			guard let self, self.answeredInput != self.input, self.overlay != .history else { return }
			self.startJob(adopt: false)
		}
		speculate = work
		DispatchQueue.main.asyncAfter(deadline: .now() + (Mode(of: input) == .word ? 0.25 : 0.5), execute: work)
	}

	func enter() {
		switch overlay {
		case .history:
			if let i = historySelected, historyRows.indices.contains(i) {
				startOver(.history(historyRows[i]))
				return
			}
			overlay = .none
		case .alternatives:
			applyAlternative()
			return
		case .ask:
			applyAsk()
			return
		case .none:
			break
		}
		guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !restarting else { return }
		if failure != nil && answeredInput == input {
			guard repairable else { return }
			restartFailed ? onRelaunch?(input) : restart()
		} else if failure != nil || answeredInput != input {
			translate()
		} else if streaming || restyling {
			copyWhenDone = true
		} else {
			copy()
		}
	}

	func escape() {
		switch overlay {
		case .alternatives:
			closeAlternatives()
		case .ask:
			overlay = .none
			askText = ""
			onFocusInput?()
		case .history:
			overlay = .none
			historySelected = nil
		case .none:
			onClose?()
		}
	}

	func move(_ delta: Int) -> Bool {
		switch overlay {
		case .history:
			guard !historyRows.isEmpty else { return false }
			historySelected = max(0, min(historyRows.count - 1, (historySelected ?? -1) + delta))
			return true
		case .alternatives:
			altSelected = max(0, min(alternatives.count - 1, altSelected + delta))
			return true
		case .ask:
			return false
		case .none:
			if input.isEmpty && delta > 0 {
				openHistory()
				return true
			}
			guard kind == .card, !isStale, !lines.isEmpty, !input.contains("\n") else { return false }
			selected = max(0, min(lines.count - 1, selected + delta))
			return true
		}
	}

	private(set) var restarting = false
	private(set) var restartFailed = false
	var onRelaunch: ((String) -> Void)?
	private var restartedFor: String?
	private var restartRun = 0
	static let restartingNote = "Restarting the model"
	static let restartDidNotHelp = "The restart didn't help: "
	private(set) var repairable = true

	func restart() {
		cancelAll()
		let source = input
		failure = nil
		restarting = true
		loadingModel = true
		status = Self.restartingNote
		restartRun += 1
		let run = restartRun
		engine.restart { [weak self] error in
			guard let self, run == self.restartRun else { return }
			self.restarting = false
			self.loadingModel = false
			self.status = nil
			guard self.input == source else { return }
			if let error {
				self.restartFailed = true
				self.failure = Self.restartDidNotHelp + error
				return
			}
			self.restartFailed = false
			self.restartedFor = source
			self.translate()
		}
	}

	private func translate() {
		overlay = .none
		failure = nil
		if let job, job.input == input, job.error == nil {
			adopt(job)
		} else {
			startJob(adopt: true)
		}
	}

	private func prepared(_ text: String) -> (text: String, note: String?) {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		if Mode(of: trimmed) == .word, let fix = WordFix.fix(trimmed) { return (fix.text, fix.note) }
		return (trimmed, nil)
	}

	private func startJob(adopt: Bool) {
		job?.token.cancel()
		cancelSide()
		let source = input
		let (text, note) = prepared(source)
		let j = Job(input: source, kind: Mode(of: text) == .word ? .card : .text)
		j.note = note
		job = j
		let progress = { [weak self, weak j] in
			guard let self, let j, j.shown else { return }
			self.showProgress(j)
		}
		let finished = { [weak self, weak j] (error: Error?) in
			guard let self, let j else { return }
			j.error = error
			j.done = true
			if j.shown { self.finish(j) }
		}
		if j.kind == .card {
			let q = Query<[CardLine]>.word(text)
			if let cached = history.find(text, kind: .card), let lines = q.read(cached.result) {
				j.lines = lines
				j.done = true
			} else {
				j.token = engine.ask(q, onPreview: { [weak j] lines in
					j?.lines = lines
					progress()
				}, done: { [weak j] result in
					if case let .success(lines) = result { j?.lines = lines }
					finished(result.failureValue)
				})
			}
		} else {
			let q = Query<String>.translation(text)
			if let cached = history.find(text, kind: .text), let answer = q.read(cached.result) {
				j.text = answer
				j.done = true
			} else {
				j.token = engine.ask(q, onPreview: { [weak j] text in
					j?.text = text
					progress()
				}, done: { [weak j] result in
					if case let .success(text) = result { j?.text = text }
					finished(result.failureValue)
				})
			}
		}
		if adopt { self.adopt(j) }
	}

	private func adopt(_ j: Job) {
		j.shown = true
		clearResult()
		kind = j.kind
		answeredInput = j.input
		direction = Direction(of: prepared(j.input).text)
		status = j.note
		loadingModel = !j.done && !engine.isLoaded
		streaming = !j.done
		showProgress(j)
		if j.done { finish(j) }
	}

	private func showProgress(_ j: Job) {
		guard job === j else { return }
		if !j.text.isEmpty || !j.lines.isEmpty { loadingModel = false }
		switch j.kind {
		case .card: lines = j.lines
		case .text: answer = j.text
		case .none: break
		}
	}

	static let failed = "Couldn't translate: "

	private func finish(_ j: Job) {
		guard job === j else { return }
		streaming = false
		loadingModel = false
		if let error = j.error {
			let tooLong = error is TextTooLong
			failure = tooLong ? "\(error)" : Self.failed + "\(error)"
			repairable = !tooLong
			kind = .none
			copyWhenDone = false
			if restartedFor == j.input { restartFailed = true }
			return
		}
		restartedFor = nil
		showProgress(j)
		let text = prepared(j.input).text
		if j.kind == .card {
			history.add(HistoryItem(input: text, kind: .card, result: Reply.cardText(lines)))
		} else {
			answerMarks = Self.filledWords(answer: answer, input: text)
			history.add(HistoryItem(input: text, kind: .text, result: answer))
		}
		if copyWhenDone { copy() }
	}

	private var shownTranslation: String? {
		switch kind {
		case .card: return lines.indices.contains(selected) ? lines[selected].term : nil
		case .text: return answer.isEmpty ? nil : answer
		case .none: return nil
		}
	}

	var canSwap: Bool {
		guard overlay == .none, !isStale, !streaming, !restyling, failure == nil, answeredInput != nil, let text = shownTranslation else { return false }
		return Direction(of: text) != direction
	}

	func swapDirection() {
		guard canSwap, let text = shownTranslation else { return }
		startOver(.swapped(text))
		startJob(adopt: true)
	}

	func copy() {
		copyWhenDone = false
		guard let text = shownTranslation else { return }
		onCopy?(text)
	}

	func copyLine(_ i: Int) {
		guard lines.indices.contains(i) else { return }
		selected = i
		copy()
	}

	enum Tweak { case simpler, casual, polite, shorter }

	func tweak(_ t: Tweak) {
		guard kind == .text, !isStale, !answer.isEmpty, !streaming, !restyling else { return }
		lastTweak = t
		escalated = false
		let next = Self.bump(style, t)
		if Self.level(next, t) > Style.maxLevel || (t == .shorter && Reply.words(answer) <= Style.shortest) {
			status = Self.nowhere(t)
			return
		}
		restyle(next)
	}

	private var lastTweak: Tweak?
	private var escalated = false

	private static func bump(_ style: Style, _ t: Tweak) -> Style {
		var s = style
		switch t {
		case .simpler: s.simpler += 1
		case .casual:
			s.casual += 1
			s.polite = 0
		case .polite:
			s.polite += 1
			s.casual = 0
		case .shorter: s.shorter += 1
		}
		return s
	}

	private static func level(_ style: Style, _ t: Tweak) -> Int {
		switch t {
		case .simpler: style.simpler
		case .casual: style.casual
		case .polite: style.polite
		case .shorter: style.shorter
		}
	}

	static func nowhere(_ t: Tweak) -> String {
		switch t {
		case .simpler: "Already as simple as it gets"
		case .casual: "Already as casual as it gets"
		case .polite: "Already as polite as it gets"
		case .shorter: "Already as short as it gets"
		}
	}

	static func saysLimit(_ status: String?) -> Bool {
		status.map { [Tweak.simpler, .casual, .polite, .shorter].map(nowhere).contains($0) } ?? false
	}

	static let nothingChanged = "The model changed nothing"
	static let restyleFailed = "Couldn't change the translation"
	static let editFailed = "Couldn't replace the word"
	static let noAlternatives = "No alternatives found — type your own word"
	static let currentNote = "current"

	private func sameAgain() {
		copyWhenDone = false
		guard let t = lastTweak else {
			stepBack()
			status = Self.nothingChanged
			return
		}
		let stronger = Self.bump(style, t)
		if !escalated, Self.level(stronger, t) <= Style.maxLevel {
			escalated = true
			style = stronger
			runRestyle()
			return
		}
		stepBack()
		status = Self.nowhere(t)
	}

	func startAsk() {
		guard kind == .text, !isStale, !streaming, !restyling else { return }
		overlay = .ask
	}

	private func applyAsk() {
		let request = askText.trimmingCharacters(in: .whitespacesAndNewlines)
		overlay = .none
		onFocusInput?()
		guard !request.isEmpty else { return }
		var s = style
		s.request = request
		askText = ""
		lastTweak = nil
		restyle(s)
	}

	private func restyle(_ s: Style) {
		undo.append((style, answer, answerMarks))
		style = s
		clearChangeStatus()
		runRestyle()
	}

	private func clearChangeStatus() {
		if let s = status, Self.saysLimit(s) || [Self.nothingChanged, Self.restyleFailed, Self.editFailed, Self.noAlternatives].contains(s) {
			status = nil
		}
	}

	private func runRestyle() {
		sideToken?.cancel()
		let text = prepared(input).text, current = answer
		restyling = true
		sideToken = engine.ask(.restyle(text, style: style, current: current), done: { [weak self] result in
			guard let self else { return }
			self.restyling = false
			switch result {
			case let .success(new):
				if Reply.same(new, current) || (self.lastTweak == .shorter && Reply.words(new) >= Reply.words(current)) {
					self.sameAgain()
					return
				}
				self.answer = new
				self.answerMarks = Self.filledWords(answer: new, input: text)
				if self.copyWhenDone { self.copy() }
			case .failure:
				self.stepBack()
				self.status = Self.restyleFailed
				self.copyWhenDone = false
			}
		})
	}

	func back() {
		if undo.isEmpty, canReturn, let last = previous.popLast() {
			wipe()
			apply(last)
			onStartOver?()
			if isOpen { resume() }
			return
		}
		stepBack()
	}

	private func stepBack() {
		sideToken?.cancel()
		sideToken = nil
		restyling = false
		guard let last = undo.popLast() else { return }
		style = last.style
		answer = last.answer
		answerMarks = last.marks
	}

	private func cancelSide() {
		if restyling {
			stepBack()
		} else {
			sideToken?.cancel()
			sideToken = nil
		}
		alternativesPending = false
	}

	func pick(_ range: NSRange) {
		guard kind == .text, !isStale, !streaming, !restyling else { return }
		let ns = answer as NSString
		guard range.length > 0, NSMaxRange(range) <= ns.length else { return }
		let word = ns.substring(with: range)
		picked = range
		alternatives = [CardLine(term: word, note: Self.currentNote)]
		altSelected = 0
		ownWord = ""
		overlay = .alternatives
		clearChangeStatus()
		requestAlternatives(range)
	}

	private func requestAlternatives(_ range: NSRange) {
		let ns = answer as NSString
		guard range.length > 0, NSMaxRange(range) <= ns.length else { return }
		let word = ns.substring(with: range)
		alternativesPending = true
		sideToken?.cancel()
		sideToken = engine.ask(.alternatives(source: prepared(input).text, text: answer, range: range), done: { [weak self] result in
			guard let self, self.overlay == .alternatives, self.picked == range else { return }
			self.alternativesPending = false
			switch result {
			case let .success(more) where !more.isEmpty: self.alternatives = [CardLine(term: word, note: Self.currentNote)] + more.prefix(5)
			default: self.status = Self.noAlternatives
			}
		})
	}

	private func closeAlternatives() {
		if alternativesPending { sideToken?.cancel() }
		overlay = .none
		picked = nil
		ownWord = ""
		alternativesPending = false
		if status == Self.noAlternatives { status = nil }
		onFocusInput?()
	}

	private func applyAlternative() {
		guard let range = picked else { return overlay = .none }
		let own = ownWord.trimmingCharacters(in: .whitespacesAndNewlines)
		let choice = own.isEmpty ? (alternatives.indices.contains(altSelected) ? alternatives[altSelected].term : "") : own
		closeAlternatives()
		let ns = answer as NSString
		guard !choice.isEmpty, altSelected != 0 || !own.isEmpty, NSMaxRange(range) <= ns.length,
		      choice.lowercased() != ns.substring(with: range).lowercased() else { return }
		let text = prepared(input).text, current = answer
		undo.append((style, answer, answerMarks))
		restyling = true
		sideToken?.cancel()
		sideToken = engine.ask(.edit(source: text, text: current, range: range, with: choice), done: { [weak self] result in
			guard let self else { return }
			self.restyling = false
			switch result {
			case let .success(new) where !Reply.same(new, current):
				self.answer = new
				self.answerMarks = Reply.changedWords(old: current, new: new)
				if self.copyWhenDone { self.copy() }
			default:
				self.stepBack()
				self.status = Self.editFailed
				self.copyWhenDone = false
			}
		})
	}

	func openHistory() {
		refreshHistory()
		guard !historyRows.isEmpty else { return }
		overlay = .history
		historySelected = 0
	}

	private func refreshHistory() {
		historyRows = history.search(input.trimmingCharacters(in: .whitespacesAndNewlines))
	}

	static let readingPicture = "Reading the picture…"
	static let noTextOnPicture = "No text found in the picture"
	static let pictureUnreadable = "Couldn't open the picture"
	static let fromPicture = "Text from the picture — fix it in the field if needed"

	func pictureStarted() {
		status = Self.readingPicture
	}

	func pictureFailed() {
		status = Self.pictureUnreadable
	}

	func picture(_ text: String?) {
		guard let text, !text.isEmpty else {
			status = Self.noTextOnPicture
			return
		}
		startOver(.picture(text))
		startJob(adopt: true)
		status = Self.fromPicture
	}

	var draft: Draft {
		var d = Draft()
		d.input = input
		d.origin = origin
		d.ownWord = ownWord
		d.askText = askText
		d.resume = pendingResume
		if streaming {
			d.resume = .translate
			return d
		}
		d.kind = kind
		d.answeredInput = answeredInput
		d.toRussian = direction == .toRussian
		d.status = [Self.readingPicture, Self.restartingNote].contains(status) ? nil : status
		d.failure = failure
		d.repairable = repairable
		d.lines = lines
		d.selected = selected
		d.answer = answer
		d.answerMarks = answerMarks.map(Draft.Span.init)
		d.style = style
		d.versions = undo.map { Draft.Version(style: $0.style, answer: $0.answer, marks: $0.marks.map(Draft.Span.init)) }
		if restyling, let last = d.versions.popLast() {
			d.style = last.style
			d.answer = last.answer
			d.answerMarks = last.marks
		}
		d.overlay = overlay
		d.historySelected = historySelected
		d.picked = picked.map(Draft.Span.init)
		d.alternatives = alternatives
		d.altSelected = altSelected
		if alternativesPending { d.resume = .alternatives }
		return d
	}

	private func apply(_ d: Draft) {
		setInput(d.input)
		origin = d.origin
		kind = d.kind
		answeredInput = d.answeredInput
		direction = d.toRussian ? .toRussian : .toEnglish
		status = d.status
		failure = d.failure
		repairable = d.repairable
		lines = d.lines
		selected = max(0, min(d.selected, lines.count - 1))
		answer = d.answer
		answerMarks = d.answerMarks.map(\.range)
		style = d.style
		undo = d.versions.map { (style: $0.style, answer: $0.answer, marks: $0.marks.map(\.range)) }
		overlay = d.overlay
		historySelected = d.historySelected
		picked = d.picked?.range
		alternatives = d.alternatives
		altSelected = max(0, min(d.altSelected, alternatives.count - 1))
		ownWord = d.ownWord
		askText = d.askText
		pendingResume = d.resume
		if overlay == .alternatives && (picked == nil || alternatives.isEmpty) || overlay == .ask && kind != .text {
			overlay = .none
			picked = nil
		}
		if overlay == .history {
			refreshHistory()
			if historyRows.isEmpty {
				overlay = .none
				historySelected = nil
			}
		}
	}

	private var store: DraftStore?
	private var lastSaved: Draft.Saved?
	private var saveDue = false

	var saved: Draft.Saved { Draft.Saved(current: draft, previous: previous) }

	func keep(in store: DraftStore) {
		self.store = store
		if let saved = store.load() {
			wipe()
			apply(saved.current)
			previous = Array(saved.previous.filter { !$0.input.isEmpty }.suffix(Self.keptDrafts))
			lastSaved = self.saved
		}
		watch()
	}

	private func watch() {
		withObservationTracking { _ = self.saved } onChange: { [weak self] in
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					guard let self else { return }
					self.saveSoon()
					self.watch()
				}
			}
		}
	}

	private func saveSoon() {
		guard !saveDue else { return }
		saveDue = true
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
			MainActor.assumeIsolated { self?.saveNow() }
		}
	}

	func saveNow() {
		saveDue = false
		guard let store else { return }
		let s = saved
		guard s != lastSaved else { return }
		store.save(s)
		lastSaved = s
	}

	static func filledWords(answer: String, input: String) -> [NSRange] {
		let hasLatin = input.unicodeScalars.contains { ("a"..."z").contains(Character($0).lowercased()) }
		guard Reply.hasCyrillic(input), hasLatin else { return [] }
		let tokens = input.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
		let cyrillicWords = tokens.filter(Reply.hasCyrillic).count
		guard tokens.count - cyrillicWords >= cyrillicWords else { return [] }
		let given = Set(tokens)
		var marks: [NSRange] = []
		let ns = answer as NSString
		ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { word, range, _, _ in
			if let word, !given.contains(word.lowercased()) { marks.append(range) }
		}
		return marks
	}
}

struct Draft: Codable, Equatable {
	struct Span: Codable, Equatable {
		var location: Int
		var length: Int
		init(_ r: NSRange) {
			location = r.location
			length = r.length
		}
		var range: NSRange { NSRange(location: location, length: length) }
	}

	struct Version: Codable, Equatable {
		var style: Style
		var answer: String
		var marks: [Span]
	}

	enum Resume: String, Codable { case translate, alternatives }

	struct Saved: Codable, Equatable {
		var current = Draft()
		var previous: [Draft] = []

		var isEmpty: Bool { current == Draft() && previous.isEmpty }

		init(current: Draft, previous: [Draft]) {
			self.current = current
			self.previous = previous
		}

		init(from decoder: Decoder) throws {
			let c = try decoder.container(keyedBy: CodingKeys.self)
			current = (try? c.decodeIfPresent(Draft.self, forKey: .current)) ?? Draft()
			previous = (try? c.decodeIfPresent([Draft].self, forKey: .previous)) ?? []
		}
	}

	var input = ""
	var kind: Session.Kind = .none
	var answeredInput: String?
	var toRussian = false
	var status: String?
	var failure: String?
	var repairable = true
	var lines: [CardLine] = []
	var selected = 0
	var answer = ""
	var answerMarks: [Span] = []
	var style = Style()
	var versions: [Version] = []
	var overlay: Session.Overlay = .none
	var historySelected: Int?
	var picked: Span?
	var alternatives: [CardLine] = []
	var altSelected = 0
	var ownWord = ""
	var askText = ""
	var origin: String?
	var resume: Resume?

	init() {}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
		func opt<T: Decodable>(_ key: CodingKeys) -> T? { try? c.decodeIfPresent(T.self, forKey: key) }
		input = get(.input, "")
		kind = get(.kind, .none)
		answeredInput = opt(.answeredInput)
		toRussian = get(.toRussian, false)
		status = opt(.status)
		failure = opt(.failure)
		repairable = get(.repairable, true)
		lines = get(.lines, [])
		selected = get(.selected, 0)
		answer = get(.answer, "")
		answerMarks = get(.answerMarks, [])
		style = get(.style, Style())
		versions = get(.versions, [])
		overlay = get(.overlay, .none)
		historySelected = opt(.historySelected)
		picked = opt(.picked)
		alternatives = get(.alternatives, [])
		altSelected = get(.altSelected, 0)
		ownWord = get(.ownWord, "")
		askText = get(.askText, "")
		origin = opt(.origin)
		resume = opt(.resume)
	}
}

final class DraftStore {
	let url: URL
	init(url: URL) { self.url = url }

	static let app = DraftStore(url: AppPaths.data.appendingPathComponent("draft.json"))

	func load() -> Draft.Saved? {
		guard let data = try? Data(contentsOf: url) else { return nil }
		return try? JSONDecoder().decode(Draft.Saved.self, from: data)
	}

	func save(_ saved: Draft.Saved) {
		guard !saved.isEmpty else {
			try? FileManager.default.removeItem(at: url)
			return
		}
		try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		if let data = try? encoder.encode(saved) { try? data.write(to: url, options: .atomic) }
	}
}

extension Session {
	static func demo(_ name: String) -> Session {
		let s = Session()
		s.showDemo(name)
		return s
	}

	func demoInput(_ text: String) { setInput(text) }
	func demoAnswer(_ text: String, streaming: Bool) {
		answer = text
		self.streaming = streaming
	}
	func demoStatus(_ text: String?) { status = text }

	func showDemo(_ name: String) {
		let s = self
		s.reset()
		s.historyRows = []
		let castle = [CardLine(term: "castle", note: "рыцарский, крепость"), CardLine(term: "lock", note: "дверной, на сейфе"),
		              CardLine(term: "padlock", note: "навесной")]
		let ru = "Я хочу пожаловаться на доставку, курьер опоздал на два часа."
		let en = "I want to complain about the delivery — the courier was two hours late."
		func card(_ input: String, _ lines: [CardLine], note: String? = nil) {
			s.input = input
			s.answeredInput = input
			s.kind = .card
			s.lines = lines
			s.status = note
		}
		func text(_ input: String, _ answer: String) {
			s.input = input
			s.answeredInput = input
			s.kind = .text
			s.answer = answer
			s.direction = Direction(of: input)
		}
		switch name {
		case "01-empty": break
		case "02-loading":
			s.input = "замок"
			s.answeredInput = "замок"
			s.kind = .card
			s.loadingModel = true
			s.streaming = true
		case "03-word": card("замок", castle)
		case "04-idiom":
			card("когда делаешь вид, что не слышишь", [CardLine(term: "turn a deaf ear", note: "идиома"),
			                                            CardLine(term: "play deaf", note: "разг."), CardLine(term: "pretend not to hear", note: "дословно")])
		case "05-english-word":
			card("awkward", [CardLine(term: "неловкий", note: "о ситуации, моменте"), CardLine(term: "неуклюжий", note: "о движениях"),
			                 CardLine(term: "неудобный", note: "о вещи, форме")])
		case "06-layout": card("pfvjr", castle, note: WordFix.layoutNote("pfvjr", "замок"))
		case "07-text": text(ru, en)
		case "08-stale":
			text(ru, en)
			s.input = ru.replacingOccurrences(of: "два", with: "три")
		case "09-alternatives":
			text(ru, en)
			let r = (en as NSString).range(of: "complain")
			s.picked = r
			s.overlay = .alternatives
			s.alternatives = [CardLine(term: "complain", note: Session.currentNote), CardLine(term: "make a complaint", note: "то же, чуть официальнее"),
			                  CardLine(term: "report a problem", note: "мягче: сообщить о проблеме"), CardLine(term: "gripe", note: "разг.: поворчать")]
		case "10-simpler":
			text(ru, "My delivery came two hours late. I want to complain.")
			s.style.simpler = 2
			s.undo = [(Style(), en, [])]
		case "11-ask":
			text(ru, en)
			s.overlay = .ask
		case "12-mixed":
			text("I want to пожаловаться about the delivery", "I want to complain about the delivery.")
			s.answerMarks = Session.filledWords(answer: s.answer, input: s.input)
		case "13-russian":
			text("I want to complain about the delivery — the courier was two hours late.", "Хочу пожаловаться на доставку: курьер опоздал на два часа.")
			s.direction = .toRussian
		case "14-picture":
			s.status = Session.readingPicture
		case "15-no-text":
			s.status = Session.noTextOnPicture
		case "16-history":
			s.historyRows = [HistoryItem(input: "отмазка", kind: .card, result: "excuse | обычная\ncop-out | разг."),
			                 HistoryItem(input: "awkward", kind: .card, result: "неловкий | о ситуации\nнеуклюжий | о движениях"),
			                 HistoryItem(input: "Не в службу, а в дружбу — глянь мой код", kind: .text, result: "Do me a favor and take a look at my code"),
			                 HistoryItem(input: "заморочиться", kind: .card, result: "go to the trouble | приложить усилия\nbother | утруждаться")]
			s.overlay = .history
			s.historySelected = 0
		case "17-failure":
			s.input = "замок"
			s.answeredInput = "замок"
			s.failure = Session.failed + Engine.notLoaded
		case "18-counts-two":
			text(ru, "My delivery was two hours late, so I want to complain.")
			s.style.simpler = 1
			s.style.shorter = 1
			s.undo = [(Style(), en, [])]
		case "19-counts-max", "20-counts-keys":
			text(ru, "Delivery: two hours late. Complaint.")
			s.style = Style(simpler: Style.maxLevel, casual: 0, polite: Style.maxLevel, shorter: Style.maxLevel, request: "для письма в поддержку")
			s.undo = [(Style(), en, [])]
		case "21-swap-keys": s.showDemo("13-russian")
		case "22-long-word":
			card("sightseeing", [CardLine(term: "осмотр достопримечательностей", note: "туризм, экскурсии"),
			                     CardLine(term: "высококвалифицированный", note: "проверка самого длинного слова"),
			                     CardLine(term: "экскурсия", note: "с гидом")])
			s.direction = .toRussian
		case "23-long-term":
			card("когда из кожи вон лезешь, чтобы гостям было хорошо", [
				CardLine(term: "go out of one's way to make the guests feel completely at home and welcome", note: "развёрнуто"),
				CardLine(term: "bend over backwards", note: "разг., сильнее"), CardLine(term: "roll out the red carpet", note: "о пышном приёме")])
		case "24-too-long":
			s.input = "Очень длинный текст"
			s.answeredInput = s.input
			s.failure = TextTooLong().description
			s.repairable = false
		case "29-hover": s.showDemo("13-russian")
		case "32-input-open":
			s.showDemo("13-russian")
			s.openInput()
		case "29-drop": s.showDemo("07-text")
		case "25-long-history":
			s.historyRows = [
				HistoryItem(input: "Не в службу, а в дружбу — глянь мой код, пожалуйста, перед тем как я отправлю его на ревью", kind: .text,
				            result: "Do me a favor and take a look at my code, please, before I send it for review"),
				HistoryItem(input: "Скажи коротко, что я задержусь на полчаса из-за пробок на Ленинградском шоссе, начинайте без меня",
				            kind: .text, result: "Running 30 min late"),
				HistoryItem(input: "sightseeing", kind: .card, result: "осмотр достопримечательностей | туризм\nэкскурсия | с гидом\nдостопримечательности | места"),
				HistoryItem(input: "ok", kind: .text,
				            result: "Хорошо, давай так и сделаем: я подготовлю черновик к понедельнику, а ты посмотришь его во вторник утром")]
			s.overlay = .history
			s.historySelected = 0
		case "26-long-ask":
			text(ru, en)
			s.overlay = .ask
			s.askText = "сделай как письмо в поддержку интернет-магазина: вежливо, но твёрдо, и попроси вернуть деньги за доставку"
		case "27-long-failure":
			s.input = "замок"
			s.answeredInput = "замок"
			s.failure = Session.failed + "couldn't load Models/gemma-4-26B_q4_0-it.gguf"
		case "28-long-alternatives":
			text(ru, en)
			s.picked = (en as NSString).range(of: "complain")
			s.overlay = .alternatives
			s.alternatives = [CardLine(term: "complain", note: Session.currentNote),
			                  CardLine(term: "lodge a formal complaint", note: "официально, письменно, в вышестоящую инстанцию"),
			                  CardLine(term: "raise a concern", note: "мягче: обратить внимание на проблему"),
			                  CardLine(term: "kick up a fuss", note: "разг.: устроить скандал")]
			s.altSelected = 1
		default: break
		}
		s.inputVersion += 1
	}
}
