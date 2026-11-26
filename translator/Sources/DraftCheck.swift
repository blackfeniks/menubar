import AppKit
import SwiftUI

@MainActor
enum DraftCheck {
	private static var failed = 0
	private static var passed = 0
	private static var copied: [String] = []

	private static func check(_ ok: Bool, _ what: String) {
		if ok { passed += 1 } else { failed += 1 }
		print((ok ? "  ✓ " : "  ✗ ") + what)
	}

	static func run() -> Int32 {
		MotionFlags.glass = false
		let base = ProcessInfo.processInfo.environment["TRANSLATOR_DIR"].map { URL(fileURLWithPath: $0) }
			?? FileManager.default.temporaryDirectory
		let dir = base.appendingPathComponent("draft-check-\(getpid())")
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		setenv("TRANSLATOR_DIR", dir.path, 1)
		unsetenv("TRANSLATOR_LLM")
		defer { try? FileManager.default.removeItem(at: dir) }
		guard AppPaths.data.path.hasPrefix(dir.path), ModelFiles.llm == nil else {
			print("✗ не удалось уйти во временную папку без модели — проверка не запущена")
			return 1
		}
		_ = NSApplication.shared
		Engine.shared.idleUnload = 600
		History.shared.add(HistoryItem(input: "замок", kind: .card, result: "castle | крепость, дворец\nlock | дверной, на сейфе\npadlock | навесной"))
		History.shared.add(HistoryItem(input: "awkward", kind: .card, result: "неловкий | о ситуации\nнеуклюжий | о движениях"))

		closing()
		explicit()
		swapping()
		pictures()
		restart()
		engine()
		files()
		demos()
		field()
		dragging()
		logic()

		print(failed == 0 ? "✓ \(passed) checks passed" : "✗ \(failed) failed, \(passed) passed")
		return failed == 0 ? 0 : 1
	}

	private static func launch() -> (AppDelegate, PanelController) {
		let app = AppDelegate()
		let c = app.panelForTests
		c.offscreen = true
		c.clipboard = { copied.append($0) }
		c.session.keep(in: .app)
		active = c
		return (app, c)
	}

	private static weak var active: PanelController?

	private static func spin(_ seconds: Double = 0.05) {
		RunLoop.main.run(until: Date().addingTimeInterval(seconds))
		active?.window?.contentView?.layoutSubtreeIfNeeded()
	}

	private static func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = [], _ c: PanelController) -> NSEvent {
		NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
		                 windowNumber: c.window?.windowNumber ?? 0, context: nil, characters: chars,
		                 charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
	}

	private static func type(_ text: String, _ c: PanelController) {
		guard let f = c.inputView else { return check(false, "нет поля ввода") }
		f.insertText(text, replacementRange: f.selectedRange())
		spin()
	}

	private static var onDisk: Draft.Saved? { DraftStore.app.load() }

	private static func survives(_ how: String, _ c: PanelController, close: () -> Void) {
		let s = c.session
		let before = s.draft
		close()
		check(!c.isVisible, "\(how): окно закрылось")
		check(s.draft == before, "\(how): в памяти всё как было")
		check(onDisk?.current == before, "\(how): черновик записан на диск")
		c.show(selection: nil)
		spin()
		check(c.isVisible && s.input.isEmpty && s.kind == .none && c.inputView?.string == "", "\(how): открыл снова — новое пустое поле")
		check(s.previous.last == before && s.canGoBack, "\(how): прежнее отложено на шаг назад")
		s.back()
		spin()
		check(s.draft == before && c.inputView?.string == before.input, "\(how): ⌘Z вернул всё как было")
	}

	private static func stays(_ how: String, _ c: PanelController, _ event: () -> Void) {
		let s = c.session
		let before = s.draft
		event()
		spin()
		check(c.isVisible && s.draft == before, "\(how): окно на месте, всё как было")
	}

	private static func closing() {
		let (app, c) = launch()
		let s = c.session

		print("Набранный текст — Esc")
		c.show(selection: nil)
		spin()
		let text = "Курьер опять опоздал на два часа, напиши в поддержку"
		type(text, c)
		check(s.input == text, "набранное дошло до окна")
		survives("Esc", c) { c.inputView?.keyDown(with: key(53, "\u{1b}", [], c)) }

		print("В новом поле набор — это набор: ⌘Z отменяет его, а не достаёт черновик")
		c.hide()
		c.show(selection: nil)
		spin()
		type("x", c)
		check(s.input == "x" && !s.canGoBack, "пока набираю, ⌘Z принадлежит полю")
		c.inputView?.undoManager?.undo()
		spin()
		check(s.input.isEmpty && !s.canGoBack, "⌘Z поля отменил набор; поле стало пустым руками, черновик не трогаем")
		s.showDemo("01-empty")

		print("Ответ, «Проще ×2» и версия для «Назад» — ⌘W")
		s.showDemo("10-simpler")
		spin()
		survives("⌘W", c) { _ = c.inputView?.performKeyEquivalent(with: key(13, "w", .command, c)) }
		s.back()
		check(s.answer.hasPrefix("I want to complain") && s.style == Style(), "«Назад» после открытия вернул прежнюю версию")

		print("Карточка и выбранная строка — щелчок мимо формы")
		s.showDemo("03-word")
		s.selected = 2
		spin()
		stays("щелчок мимо", c) {
			if let w = c.window, let e = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 4, y: 4), modifierFlags: [],
			                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
			                                                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
				w.sendEvent(e)
			}
		}
		check(s.enterLabel == "Copy “padlock”", "выбрана та же строка: \(s.enterLabel ?? "-")")

		print("Список замен и своё слово — окно потеряло клавиатуру")
		s.showDemo("09-alternatives")
		s.altSelected = 2
		s.ownWord = "grumble"
		spin()
		stays("другое окно взяло клавиатуру", c) {
			c.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: c.window))
		}
		check(s.overlay == .alternatives && s.ownWord == "grumble" && s.altSelected == 2, "список открыт, своё слово и выбор на месте")

		print("Просьба в поле просьбы — правый ⌘")
		s.showDemo("11-ask")
		s.askText = "для письма в поддержку"
		spin()
		survives("правый ⌘", c) { app.toggleWindow() }
		spin(0.1)
		let editor = c.window?.firstResponder as? NSTextView
		check(s.overlay == .ask && (editor?.delegate as? NSTextField)?.stringValue == "для письма в поддержку",
		      "просьба на месте, клавиатура в поле просьбы")

		print("Окно без клавиатуры, пока читается выделенное, и отмена")
		s.showDemo("07-text")
		spin()
		let kept = s.draft
		c.hide()
		c.showPending()
		check(c.isVisible, "окно на экране сразу")
		check(s.input.isEmpty && s.previous.last == kept, "пока читается выделенное, окно пустое, прежнее отложено")
		c.hide()
		check(!c.isVisible && s.previous.last == kept, "отмена: прежнее на шаг назад")

		print("Выделил текст при окне, оставленном на экране: перевод здесь же, рамка не прыгает")
		c.show(selection: nil)
		s.showDemo("07-text")
		spin()
		let frame = c.window?.frame
		c.show(selection: "замок")
		spin()
		check(s.input == "замок" && s.kind == .card && c.window?.frame == frame, "выделенное переведено в том же окне")
		s.reset()

		print("Просьба, закрытая набором в поле, при новом ⌘5 на месте")
		s.showDemo("11-ask")
		s.askText = "парой слов"
		let source = s.input
		s.edited(source + "!")
		s.edited(source)
		check(s.overlay == .none, "набор в поле закрыл просьбу")
		s.startAsk()
		check(s.overlay == .ask && s.askText == "парой слов", "⌘5: просьба на месте")
		s.escape()
		s.startAsk()
		check(s.askText.isEmpty, "после «Отмена» (Esc) — пусто: это явный отказ")
		s.escape()
		app.toggleWindow()

		print("Модель выгрузилась, пока окно закрыто")
		c.show(selection: nil)
		s.showDemo("10-simpler")
		spin()
		let answered = s.draft
		app.toggleWindow()
		Engine.shared.unload()
		check(s.draft == answered, "выгрузка не тронула окно")
		c.show(selection: nil)
		spin()
		s.back()
		check(s.draft == answered && s.canGoBack, "открыл, ⌘Z: ответ и его версии на месте")

		print("Enter во время перевода, потом окно закрылось или потеряло клавиатуру: в буфер ничего не уходит")
		s.showDemo("02-loading")
		s.enter()
		check(s.copyPromised, "Enter обещал скопировать, когда перевод придёт")
		app.toggleWindow()
		check(!s.copyPromised, "окно закрыто: обещание снято, буфер не тронут")
		c.show(selection: nil)
		s.showDemo("02-loading")
		s.enter()
		c.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: c.window))
		check(!s.copyPromised && c.isVisible, "ушёл в другое окно: обещание снято, окно на экране")
		check(copied.isEmpty, "в буфер ничего не писалось")
		c.hide()
	}

	private static func explicit() {
		let (_, c) = launch()
		let s = c.session
		s.reset()

		print("Новое выделенное: черновик уходит в «Назад»")
		c.show(selection: nil)
		spin()
		type("Черновик ответа клиенту", c)
		let mine = s.draft
		c.hide()
		c.show(selection: "замок")
		spin()
		check(s.input == "замок" && s.kind == .card && s.lines.count == 3, "выделенное переведено (из истории, без модели)")
		check(s.previous == [mine], "прежний черновик отложен целиком")
		check(s.canGoBack, "«Назад» доступно")
		s.back()
		check(s.draft == mine && s.previous.isEmpty, "«Назад» вернул черновик")
		c.hide()

		print("Выделенное за выделенным: нетронутое выделенное не вытесняет черновик")
		c.show(selection: "замок")
		c.hide()
		c.show(selection: "awkward")
		spin()
		check(s.input == "awkward" && s.previous == [mine], "отложен по-прежнему только черновик")

		print("Скопировал результат — окно закрылось (явно): черновик по-прежнему на шаг назад")
		s.enter()
		check(copied.last == "неловкий" && !c.isVisible, "скопировано «\(copied.last ?? "")», окно закрыто")
		check(s.input.isEmpty && s.previous == [mine], "окно пустое, черновик отложен")
		check(onDisk?.previous == [mine], "и на диске тоже")
		c.show(selection: nil)
		spin()
		check(s.input.isEmpty && s.canGoBack, "открыл: пустое поле")
		s.back()
		check(s.draft == mine && s.previous.isEmpty, "⌘Z: черновик вернулся")

		print("Скопировал результат, отложенного нет: окно пустое, на диске ничего")
		s.showDemo("07-text")
		s.enter()
		check(copied.last?.hasPrefix("I want to complain") == true && !c.isVisible, "скопирован перевод, окно закрыто")
		check(s.input.isEmpty && s.kind == .none && s.answer.isEmpty, "окно начинается заново")
		check(!FileManager.default.fileExists(atPath: DraftStore.app.url.path), "файл черновика удалён")

		print("Стёр поле (явно): ответ уходит, ⌘Z поля возвращает текст")
		c.show(selection: nil)
		s.showDemo("07-text")
		spin()
		let checked = s.input
		c.inputView?.selectAll(nil)
		c.inputView?.deleteBackward(nil)
		spin()
		check(s.input.isEmpty && s.kind == .none && s.answer.isEmpty, "поле пусто, ответа нет")
		c.inputView?.undoManager?.undo()
		spin()
		check(s.input == checked, "⌘Z поля вернул текст")

		print("Открыл запись истории (явно)")
		c.inputView?.selectAll(nil)
		c.inputView?.deleteBackward(nil)
		spin()
		check(s.move(1) && s.overlay == .history, "↓ в пустом поле: история")
		s.enter()
		check(s.input == "awkward" && s.kind == .card && s.overlay == .none, "запись открыта: «\(s.input)»")

		print("Картинка без текста: черновик не трогается")
		s.showDemo("07-text")
		let text = s.draft
		s.picture(nil)
		check(s.input == text.input && s.answer == text.answer, "текст и перевод на месте, только строка статуса")
		print("Картинка с текстом: черновик уходит в «Назад»")
		s.picture("Text from a picture")
		check(s.input == "Text from a picture" && s.previous.last?.input == text.input, "текст картинки в поле, прежний отложен")
		c.hide()
	}

	private static func swapping() {
		print("«Наоборот»: перевод в поле, и обратно")
		let (_, c) = launch()
		let s = c.session
		s.reset()
		c.show(selection: nil)
		let ru = "Я хочу пожаловаться на доставку, курьер опоздал на два часа."
		let en = "I want to complain about the delivery — the courier was two hours late."
		History.shared.add(HistoryItem(input: en, kind: .text, result: ru))
		History.shared.add(HistoryItem(input: "lock", kind: .card, result: "замок | на двери\nблокировка | доступа"))
		s.showDemo("07-text")
		spin()
		let pair = s.draft
		check(s.canSwap, "есть готовый перевод: кнопка есть")
		_ = c.inputView?.performKeyEquivalent(with: key(15, "r", .command, c))
		spin()
		check(s.input == en && c.inputView?.string == en && s.answer == ru && s.direction == .toRussian, "⌘R: «\(s.input)» → «\(s.answer)»")
		check(s.canSwap && s.canGoBack && s.previous.last == pair, "прежняя пара на шаг назад")
		s.back()
		spin()
		check(s.draft == pair && s.previous.isEmpty, "«Назад» вернул пару как была")

		s.showDemo("03-word")
		s.selected = 1
		s.swapDirection()
		spin()
		check(s.input == "lock" && s.kind == .card && s.lines.first?.term == "замок" && s.direction == .toRussian, "карточка: наоборот — выбранная строка (\(s.input))")

		s.showDemo("08-stale")
		check(!s.canSwap, "старый ответ (текст уже другой): кнопки нет")
		s.showDemo("09-alternatives")
		check(!s.canSwap, "открыт список замен: кнопки нет")
		s.showDemo("17-failure")
		check(!s.canSwap, "сбой: кнопки нет")
		s.showDemo("01-empty")
		check(!s.canSwap, "пустое поле: кнопки нет")
		s.swapDirection()
		check(s.input.isEmpty, "и ничего не происходит")
		s.showDemo("13-russian")
		s.demoAnswer("Claude", streaming: false)
		check(!s.canSwap, "ответ без русских букв (имя): наоборот было бы то же самое, кнопки нет")
		s.reset()
		c.hide()
	}

	private final class FakeDrag: NSObject, NSDraggingInfo {
		let draggingPasteboard: NSPasteboard
		@MainActor init(_ board: NSPasteboard) { draggingPasteboard = board }
		var draggingDestinationWindow: NSWindow? { nil }
		var draggingSourceOperationMask: NSDragOperation { .copy }
		var draggingLocation: NSPoint { .zero }
		var draggedImageLocation: NSPoint { .zero }
		var draggedImage: NSImage? { nil }
		var draggingSource: Any? { nil }
		var draggingSequenceNumber: Int { 1 }
		func slideDraggedImage(to screenPoint: NSPoint) {}
		var draggingFormation: NSDraggingFormation = .default
		var animatesToDestination = false
		var numberOfValidItemsForDrop = 1
		func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
		                            searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
		                            using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
		var springLoadingHighlight: NSSpringLoadingHighlight { .none }
		func resetSpringLoading() {}
	}

	private static func picturePNG(_ text: String) -> Data {
		let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
		                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
		NSColor.white.setFill()
		NSRect(x: 0, y: 0, width: 1600, height: 300).fill()
		(text as NSString).draw(at: NSPoint(x: 40, y: 110), withAttributes: [.font: NSFont.systemFont(ofSize: 72), .foregroundColor: NSColor.black])
		NSGraphicsContext.restoreGraphicsState()
		return rep.representation(using: .png, properties: [:])!
	}

	private static func pictures() {
		let (_, c) = launch()
		let s = c.session
		let board = NSPasteboard(name: NSPasteboard.Name("com.ilya.translator.draft-check.\(getpid())"))
		EditKeys.board = board
		defer {
			EditKeys.board = .general
			board.releaseGlobally()
		}
		func arrived(_ what: String, _ want: String) {
			let end = Date().addingTimeInterval(8)
			while !s.input.contains(want), Date() < end { spin(0.02) }
			check(s.input.contains(want), "\(what): текст с картинки в поле: «\(s.input)»")
		}
		func fresh() {
			s.reset()
			c.show(selection: nil)
			spin()
		}

		print("⌘V: снимок экрана, ссылка рядом с картинкой")
		fresh()
		board.clearContents()
		board.setData(picturePNG("Hello from a screenshot"), forType: .png)
		c.inputView?.paste(nil)
		check(s.status == Session.readingPicture && c.ui.thumbnail != nil, "пока читается: «\(s.status ?? "-")», миниатюра видна")
		arrived("снимок", "Hello from a screenshot")
		spin(0.1)
		check(c.ui.thumbnail != nil, "миниатюра осталась")
		fresh()
		check(c.ui.thumbnail == nil, "новый запрос: миниатюры нет")
		board.clearContents()
		let item = NSPasteboardItem()
		item.setData(picturePNG("Picture copied in a browser"), forType: .png)
		item.setString("https://example.com/pic.png", forType: .string)
		board.writeObjects([item])
		c.inputView?.paste(nil)
		arrived("картинка из браузера", "Picture copied in a browser")

		print("Перетаскивание: на поле и на форму")
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("translator-draft-check-\(getpid())")
		try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let file = folder.appendingPathComponent("drop.png")
		try? picturePNG("Dropped on the field").write(to: file)
		fresh()
		board.clearContents()
		let dragged = NSPasteboardItem()
		dragged.setString(file.absoluteString, forType: .fileURL)
		dragged.setString("drop.png", forType: .string)
		board.writeObjects([dragged])
		let drag = FakeDrag(board)
		guard let field = c.inputView, let sheet = c.window?.contentView else { return check(false, "нет поля") }
		check(field.draggingEntered(drag) == .copy && c.ui.dropping, "файл-картинка над полем: принимается, форма показывает это")
		field.draggingExited(drag)
		check(!c.ui.dropping, "увёл мимо: подсветки нет")
		check(field.draggingEntered(drag) == .copy, "снова над полем")
		check(field.prepareForDragOperation(drag) && field.performDragOperation(drag) && !c.ui.dropping, "отпустил над полем")
		check(field.string != file.path && field.string != file.absoluteString, "путь файла в поле не вставлен")
		arrived("на поле", "Dropped on the field")

		try? picturePNG("Dropped on the form").write(to: file)
		fresh()
		check(sheet.draggingEntered(drag) == .copy, "над формой: принимается")
		check(sheet.performDragOperation(drag), "отпустил над формой")
		arrived("на форму", "Dropped on the form")

		print("Картинка, брошенная из другого приложения: окно без клавиатуры её принимает")
		try? picturePNG("Dropped from another app").write(to: file)
		fresh()
		c.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: c.window))
		check(c.isVisible && sheet.performDragOperation(drag), "окно на экране, картинка принята")
		arrived("из другого приложения", "Dropped from another app")

		print("Текст и ссылка над полем — это обычный текст")
		fresh()
		board.clearContents()
		board.setString("просто текст", forType: .string)
		check(!OCR.accepts(board) && !c.ui.dropping, "текст не считается картинкой")

		print("Пустая картинка и битая")
		fresh()
		board.clearContents()
		let blank = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
		                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
		board.setData(blank.representation(using: .png, properties: [:])!, forType: .png)
		c.inputView?.paste(nil)
		let end = Date().addingTimeInterval(8)
		while s.status == Session.readingPicture, Date() < end { spin(0.02) }
		check(s.status == Session.noTextOnPicture && s.input.isEmpty && c.ui.thumbnail == nil, "без текста: «\(s.status ?? "-")», миниатюры нет")
		c.hide()
	}

	private static func restart() {
		print("Выход и новый запуск: всё, что было в окне, на шаг назад")
		let (app, c) = launch()
		let s = c.session
		s.reset()
		c.show(selection: nil)
		s.showDemo("07-text")
		spin()
		let textPixels = pixels(s)
		c.show(selection: "замок")
		s.selected = 1
		spin()
		let before = s.saved
		let cardPixels = pixels(s)
		app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
		check(onDisk == before, "при выходе записано: карточка и отложенный перевод")

		let (_, c2) = launch()
		let s2 = c2.session
		check(s2.saved == before, "после запуска: то же самое")
		check(cardPixels != nil && pixels(s2) == cardPixels, "окно выглядит так же, до точки")
		check(s2.enterLabel == "Copy “lock”", "выбранная строка та же: \(s2.enterLabel ?? "-")")
		s2.back()
		check(textPixels != nil && pixels(s2) == textPixels, "«Назад»: перевод как был")

		print("Перевод шёл, когда приложение закрылось")
		s2.showDemo("02-loading")
		s2.saveNow()
		check(onDisk?.current.resume == .translate && onDisk?.current.answer == "", "записано поле и «перевести ещё раз», не половина ответа")
		let (_, c3) = launch()
		let s3 = c3.session
		check(s3.input == "замок" && s3.kind == .none, "после запуска: поле на месте, модель не тронута до открытия")
		c3.show(selection: nil)
		spin()
		check(s3.input.isEmpty, "хоткей: новое поле")
		s3.back()
		spin()
		check(s3.kind == .card && s3.lines.count == 3, "⌘Z: перевод продолжился сам")
		c3.hide()
	}

	private static func engine() {
		print("Модель: выгружается после простоя, даже если окно осталось на экране")
		let e = Engine.shared
		e.prepare()
		e.queue.sync {}
		check(e.unloadArmed, "окно открылось: таймер идёт, окно на экране модель не держит")
		e.scheduleUnload()
		check(e.unloadArmed, "окно закрыто: таймер выгрузки идёт")
		var done = false
		e.ask(Query<String>.translation("Проверка после закрытия окна"), done: { _ in done = true })
		while !done { spin(0.01) }
		e.queue.sync {}
		check(e.unloadArmed, "после запроса таймер запущен заново")
		e.scheduleUnload()
	}

	private static func files() {
		print("Файл черновика: битый и от другой версии")
		let url = DraftStore.app.url
		try? Data("не json".utf8).write(to: url)
		let (_, c) = launch()
		check(c.session.input.isEmpty, "битый файл: пустое окно, без падения")
		try? Data(#"{"current": {"input": "старый черновик", "kind": "что-то новое", "selected": "x"}}"#.utf8).write(to: url)
		let (_, c2) = launch()
		check(c2.session.input == "старый черновик" && c2.session.kind == .none, "незнакомые и пропущенные поля: черновик всё равно на месте")
		try? FileManager.default.removeItem(at: url)
	}

	private static func logic() {
		let (_, c) = launch()
		let s = c.session

		print("Enter во время перевода, потом правка: обещанной копии больше нет")
		c.show(selection: nil)
		spin()
		type("Курьер опоздал на два часа, напиши в поддержку", c)
		s.enter()
		s.enter()
		check(s.copyPromised, "Enter во время перевода обещал копию")
		c.inputView?.insertText("!", replacementRange: c.inputView?.selectedRange() ?? NSRange())
		check(!s.copyPromised, "правка сняла обещание: копии старого ответа посреди набора не будет")
		spin(0.2)

		print("Перезапуск модели, а тем временем новое выделение")
		c.show(selection: "Курьер опоздал на два часа")
		spin(0.2)
		check(s.failure != nil && s.enterLabel == "Restart", "без модели — сбой и «Перезапустить» (\(s.failure ?? "-"))")
		s.enter()
		check(s.restarting, "перезапуск идёт")
		c.show(selection: "Напиши в поддержку")
		check(!s.restarting && s.streaming && s.input == "Напиши в поддержку", "новое выделение переводится сразу, не ждёт перезапуска")
		spin(0.3)
		check(!(s.failure ?? "").hasPrefix(Session.restartDidNotHelp) && s.status != Session.restartingNote,
		      "конец старого перезапуска ничего не тронул (\(s.failure ?? "-"))")

		print("Временные строки статуса не пишутся в черновик")
		s.pictureStarted()
		check(s.status == Session.readingPicture && s.draft.status == nil, "«Читаю картинку…» на экране, но не в черновике")
		c.hide()
	}

	private static func fieldOK(_ what: String, _ c: PanelController, folded: Bool) {
		guard let v = c.inputView, let scroll = v.enclosingScrollView, let tc = v.textContainer, let lm = v.layoutManager else {
			return check(false, "\(what): нет поля")
		}
		var problems: [String] = []
		if v.folded != folded { problems.append(folded ? "поле не свёрнуто" : "поле свёрнуто") }
		if abs(tc.size.width - v.bounds.width) > 0.5 { problems.append("текст разложен на \(tc.size.width) pt, поле \(v.bounds.width)") }
		let want = InputTextView.height(of: v.string, width: scroll.bounds.width, folded: c.session.inputFolded)
		if abs(scroll.frame.height - want) > 0.5 { problems.append("поле \(scroll.frame.height) pt, тексту нужно \(want)") }
		if v.frame.height < scroll.contentSize.height - 0.5 { problems.append("текст не заполняет поле: \(v.frame.height) из \(scroll.contentSize.height)") }
		lm.ensureLayout(for: tc)
		let laid = ceil(max(lm.usedRect(for: tc).height, Look.inputFont.boundingRectForFont.height)) + 1
		if abs(laid - TextHeight.shared.of(v.string, font: Look.inputFont, width: v.bounds.width)) > 0.5 { problems.append("замер разошёлся с полем") }
		if folded && abs(scroll.contentView.bounds.minY) > 0.5 { problems.append("свёрнутое поле прокручено на \(scroll.contentView.bounds.minY)") }
		if let rep = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) {
			scroll.cacheDisplay(in: scroll.bounds, to: rep)
			let scale = CGFloat(rep.pixelsHigh) / scroll.bounds.height
			let lit = (0..<rep.pixelsHigh).filter { y in (0..<rep.pixelsWide).contains { x in (rep.colorAt(x: x, y: y)?.brightnessComponent ?? 0) > 0.6 } }
			fieldTops[what] = lit.first
			if folded, let last = lit.last, CGFloat(last) / scale > InputTextView.oneLine { problems.append("свёрнутое поле рисует ниже первой строки") }
			if lit.isEmpty { problems.append("в поле ничего не видно") }
		}
		check(problems.isEmpty, "\(what): поле \(Int(scroll.frame.height)) pt" + (problems.isEmpty ? "" : " — " + problems.joined(separator: "; ")))
	}

	private static var fieldTops: [String: Int] = [:]

	private static func click(_ c: PanelController, onWord word: String) -> NSRange? {
		guard let w = c.window, let v = c.inputView, let lm = v.layoutManager, let tc = v.textContainer else { return nil }
		let range = (v.string as NSString).range(of: word)
		guard range.location != NSNotFound else { return nil }
		let rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: tc)
		let point = v.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
		func event(_ type: NSEvent.EventType) -> NSEvent? {
			NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
			                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
		}
		guard let down = event(.leftMouseDown), let up = event(.leftMouseUp), let content = w.contentView else { return nil }
		check(w.isOnForm?(point) == true, "клик по полю — по форме")
		let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
		check(hit === v, "под точкой — само поле (\(hit.map { String(describing: Swift.type(of: $0)) } ?? "ничего"))")
		NSApp.postEvent(up, atStart: false)
		hit?.mouseDown(with: down)
		spin()
		return range
	}

	private static func field() {
		let (_, c) = launch()
		let s = c.session
		let title = "Windows 11 портировали на «раскладушку» OnePlus"
		let long = title + "\n\nРазработчик рассказал, что самостоятельно написал драйверы для железа и сенсорного экрана, а также создал кастомный UEFI, но в итоге система запустилась нативно и более-менее стабильно функционирует."
		let answer = "Windows 11 has been ported to the OnePlus flip phone.\n\nThe developer shared that they wrote the drivers for the hardware and touchscreen from scratch."
		History.shared.add(HistoryItem(input: long, kind: .text, result: answer))

		print("Поле: выделенный текст в несколько абзацев, ответ из истории — одна строка")
		c.show(selection: long)
		spin(0.1)
		check(s.kind == .text && s.answer == answer, "ответ на месте")
		fieldOK("выделение с ответом", c, folded: true)

		print("Клик по слову — поле раскрылось, каретка там, где кликнули")
		let word = click(c, onWord: "раскладушку")
		spin(0.1)
		fieldOK("после клика", c, folded: false)
		if let word, let v = c.inputView {
			let caret = v.selectedRange()
			check(caret.length == 0 && NSLocationInRange(caret.location, NSRange(location: word.location, length: word.length + 1)),
			      "каретка в слове «раскладушку» (\(caret.location), слово с \(word.location))")
		}
		check(fieldTops["выделение с ответом"] == fieldTops["после клика"], "первая строка не сдвинулась при раскрытии (\(fieldTops["выделение с ответом"] ?? -1) → \(fieldTops["после клика"] ?? -1))")

		print("Набор в раскрытом поле: поле открыто, ответ бледный")
		type("!", c)
		check(s.isStale, "ответ устарел")
		fieldOK("после набора", c, folded: false)
		c.inputView?.undoManager?.undo()
		spin()
		check(s.input == long && !s.isStale, "⌘Z вернул текст, ответ снова к нему")
		fieldOK("после ⌘Z", c, folded: false)

		print("Набор в свёрнутом поле раскрывает его")
		c.show(selection: nil)
		spin()
		c.show(selection: long)
		spin(0.1)
		fieldOK("то же выделение снова", c, folded: true)
		c.inputView?.setSelectedRange(NSRange(location: (s.input as NSString).length, length: 0))
		type(" ok", c)
		fieldOK("набор в свёрнутом", c, folded: false)

		print("Много строк с прокруткой, потом ответ — одна чистая строка")
		let lines = (1...12).map { "Строка \($0): курьер опоздал на два часа, а поддержка так и не ответила" }.joined(separator: "\n")
		History.shared.add(HistoryItem(input: lines, kind: .text, result: "Line 1: the courier was two hours late."))
		c.show(selection: nil)
		spin()
		type(lines, c)
		fieldOK("12 строк набрано", c, folded: false)
		if let scroll = c.inputView?.enclosingScrollView {
			check(scroll.contentView.bounds.minY > 10, "поле прокручено к каретке (\(Int(scroll.contentView.bounds.minY)) pt)")
		}
		s.enter()
		spin(0.1)
		check(s.kind == .text, "Enter: ответ из истории")
		fieldOK("ответ после прокрутки", c, folded: true)

		print("Ответ, который помещается в строку: поле как было, с кареткой")
		History.shared.add(HistoryItem(input: "Привет, как у тебя дела сегодня?", kind: .text, result: "Hi, how are you today?"))
		c.show(selection: "Привет, как у тебя дела сегодня?")
		spin(0.1)
		check(s.inputFolded && c.inputView?.folded == false, "короткий текст не сворачивается")
		fieldOK("короткий текст", c, folded: false)
		c.hide()
	}

	private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, _ c: PanelController) -> NSEvent {
		NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
		                   windowNumber: c.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
	}

	private static func dragging() {
		print("Окно тянется за пустое место формы, место запоминается")
		let screen = NSRect(x: 0, y: 0, width: 1512, height: 982), visible = NSRect(x: 0, y: 0, width: 1512, height: 944)
		var pointer = NSPoint(x: 700, y: 500)
		func launched() -> PanelController {
			let (_, c) = launch()
			c.screens = { [(screen, visible)] }
			c.pointer = { pointer }
			return c
		}
		let c = launched()
		let s = c.session
		s.reset()
		Settings.shared.windowPlace = nil
		c.show(selection: nil)
		spin()
		guard let w = c.window, let field = c.inputView else { return check(false, "нет окна") }
		func spot() -> NSPoint { NSPoint(x: w.frame.minX + Look.margin.left, y: w.frame.maxY - Look.margin.top) }
		func at(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: Look.margin.left + x, y: w.frame.height - Look.margin.top - y) }
		func drag(from p: NSPoint, by: CGSize, press: ((NSEvent) -> Void)? = nil, held: Bool = false) -> CGSize {
			let from = spot(), size = w.frame.size
			pointer = NSPoint(x: w.frame.minX + p.x, y: w.frame.minY + p.y)
			let down = mouse(.leftMouseDown, at: p, c)
			if let press { press(down) } else { _ = w.takes(down) }
			for step in 1...4 {
				pointer.x += by.width / 4
				pointer.y += by.height / 4
				_ = w.takes(mouse(.leftMouseDragged, at: p, c))
				if step == 2, w.frame.size != size { check(false, "окно меняет размер посреди перетаскивания") }
			}
			let went = CGSize(width: spot().x - from.x, height: spot().y - from.y)
			if !held { _ = w.takes(mouse(.leftMouseUp, at: p, c)) }
			spin()
			return went
		}
		let home = spot()
		check(home == NSPoint(x: 456, y: 717), "без сохранённого места — посередине экрана с мышью (\(home))")
		check(w.isMovableByWindowBackground == false, "AppKit окно сам не двигает: двигает форма")

		print("Пустое поле: тянется вся форма")
		var strip: NSPoint { at(300, 8) }
		var label: NSPoint { at(560, 34) }
		var bottom: NSPoint { at(300, 56) }
		var inField: NSPoint { at(120, 34) }
		check(w.isGlass?(strip) == true && w.isGlass?(label) == true && w.isGlass?(bottom) == true, "воздух над полем, под ним и подпись справа — пустое место")
		check(w.isGlass?(inField) == false, "само поле — не пустое место (оно решает само)")
		check(w.isGlass?(at(-10, 30)) == false && w.isGlass?(at(-6, -6)) == false && w.isGlass?(at(300, 400)) == false,
		      "мимо формы и крестик — не пустое место")
		var went = drag(from: strip, by: CGSize(width: 120, height: -80))
		check(went == CGSize(width: 120, height: -80) && spot() == NSPoint(x: home.x + 120, y: home.y - 80), "за верхний край: форма ушла на 120, −80 (\(went))")
		check(Settings.shared.windowPlace == spot(), "место записано в настройки")
		let json = (try? Data(contentsOf: AppPaths.data.appendingPathComponent("settings.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
		let onDisk = json?["windowPlace"] as? [String: Double]
		check(onDisk?["x"] == Double(spot().x) && onDisk?["top"] == Double(spot().y), "и в settings.json на диске")
		let placed = spot()
		went = drag(from: strip, by: CGSize(width: 2, height: -1))
		check(went == .zero && spot() == placed, "щелчок с дрожью в пару точек окно не двигает")
		went = drag(from: inField, by: CGSize(width: -60, height: 40), press: { field.mouseDown(with: $0) })
		check(went == CGSize(width: -60, height: 40), "за пустое поле: форма ушла на −60, 40 (\(went))")
		check(w.firstResponder === field, "и поле при этом взяло клавиатуру")
		let dragged = spot()

		print("Закрыл и открыл, перезапустил: форма там, где оставил")
		c.hide()
		pointer = NSPoint(x: 30, y: 30)
		c.show(selection: nil)
		spin()
		check(spot() == dragged, "открыл снова: на том же месте (\(spot()))")
		c.hide()
		let c2 = launched()
		c2.show(selection: nil)
		spin()
		let w2 = c2.window
		check(w2.map { NSPoint(x: $0.frame.minX + Look.margin.left, y: $0.frame.maxY - Look.margin.top) } == dragged, "новый запуск: на том же месте")
		c2.hide()

		print("Текст и кнопки не тянут окно, пустое место рядом с ними тянет")
		c.show(selection: nil)
		s.showDemo("07-text")
		spin(0.4)
		let areas = c.ui.press.frames
		let flow = areas.first { abs($0.width - (Look.width - 2 * Look.side)) < 0.5 && $0.minY > 62 }
		let buttons = areas.filter { $0.minY > (flow?.maxY ?? 0) }
		check(flow != nil && buttons.count >= 6, "форма знает свой ответ и кнопки панели (\(buttons.count))")
		check(buttons.allSatisfy { w.isGlass?(at($0.midX, $0.midY)) == false }, "кнопки панели — не пустое место")
		if let flow {
			check(w.isGlass?(at(flow.minX + 6, flow.minY + 14)) == false, "слово ответа — не пустое место")
			let blank = at(flow.maxX - 4, flow.maxY - 14)
			check(w.isGlass?(blank) == true, "пустой конец последней строки ответа — пустое место")
			check(w.isGlass?(at(flow.midX, flow.minY - 8)) == true && w.isGlass?(at(8, flow.midY)) == true, "воздух над ответом и поле формы слева — тоже")
			let from = spot()
			went = drag(from: blank, by: CGSize(width: 30, height: 30))
			check(went == CGSize(width: 30, height: 30), "за него окно тянется (\(went))")
			went = drag(from: blank, by: CGSize(width: -30, height: -30))
			check(spot() == from, "и обратно")
		}
		check(w.isGlass?(at(120, 34)) == false, "поле с текстом — не пустое место")
		let before = spot()
		NSApp.postEvent(mouse(.leftMouseUp, at: inField, c), atStart: false)
		field.mouseDown(with: mouse(.leftMouseDown, at: inField, c))
		pointer.x += 80
		_ = w.takes(mouse(.leftMouseDragged, at: inField, c))
		_ = w.takes(mouse(.leftMouseUp, at: inField, c))
		check(spot() == before && !field.string.isEmpty, "нажатие в тексте поля окно не двигает: это выделение текста")
		s.showDemo("26-long-ask")
		spin(0.4)
		check(c.ui.press.frames.contains { $0.minY > 62 && $0.width > 150 && w.isGlass?(at($0.midX, $0.midY)) == false }, "поле просьбы — не пустое место")
		s.showDemo("03-word")
		spin(0.4)
		check(w.isGlass?(at(300, 100)) == false, "строка карточки — не пустое место")
		s.showDemo("15-no-text")
		spin(0.4)
		check(w.isGlass?(at(300, 84)) == true, "строка статуса — пустое место")
		s.showDemo("01-empty")
		spin(0.6)
		check(c.ui.press.frames.count == 1, "пустое окно: из своего осталось одно поле (\(c.ui.press.frames.count))")

		print("Бросил за краем экрана — форма вернулась на экран; спрятал посреди перетаскивания — место сохранено")
		_ = drag(from: strip, by: CGSize(width: 2000, height: 700))
		check(spot() == NSPoint(x: visible.maxX - Look.width - 8, y: visible.maxY - 8), "вправо-вверх за экран: у края под меню-баром (\(spot()))")
		_ = drag(from: strip, by: CGSize(width: -3000, height: -2000))
		check(spot().x == visible.minX + 8 && spot().y - visible.minY >= 160 + Look.screenGap, "влево-вниз за экран: у края, с местом для ответа (\(spot()))")
		check(Settings.shared.windowPlace == spot(), "записано место на экране, а не за ним")
		_ = drag(from: strip, by: CGSize(width: 300, height: 200), held: true)
		let midway = spot()
		c.hide()
		check(Settings.shared.windowPlace == midway, "спрятал с зажатой кнопкой: место записано")
		_ = w.takes(mouse(.leftMouseDragged, at: strip, c))
		check(spot() == midway, "запоздалое движение мыши закрытое окно не двигает")

		print("Экран, где стояла форма, отключён")
		Settings.shared.windowPlace = CGPoint(x: 5000, y: 700)
		c.show(selection: nil)
		spin()
		check(spot() == home, "форма посередине экрана с мышью (\(spot()))")
		check(Settings.shared.windowPlace == CGPoint(x: 5000, y: 700), "а место на том экране помнится: вернётся экран — вернётся и форма")
		c.hide()
		Settings.shared.windowPlace = nil
	}

	private static func demos() {
		print("Все состояния окна: запись и чтение, вид до точки")
		let url = DraftStore.app.url.deletingLastPathComponent().appendingPathComponent("demo.json")
		let store = DraftStore(url: url)
		for name in Snapshot.states {
			let s = Session.demo(name)
			let saved = s.saved
			store.save(saved)
			let back = Session()
			back.keep(in: store)
			switch name {
			case "02-loading":
				check(back.draft.resume == .translate && back.answer.isEmpty, "\(name): поле и «перевести ещё раз»")
			case "14-picture":
				check(back.saved == saved && back.status == nil && s.status == Session.readingPicture, "\(name): строка «Читаю картинку…» не хранится")
			case "32-input-open":
				check(back.saved == saved && back.inputFolded && !s.inputFolded, "\(name): черновик тот же, поле снова свёрнуто")
			case "16-history", "25-long-history":
				check(back.saved == saved && back.overlay == .history, "\(name): история открыта, выбор на месте")
			default:
				check(back.saved == saved && pixels(back) == pixels(s), "\(name)")
			}
		}
	}

	private static func pixels(_ s: Session) -> Data? {
		let host = NSHostingView(rootView: PanelView(session: s, ui: PanelUI(), onPicture: { _ in }))
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Look.width, height: 400), styleMask: .borderless,
		                      backing: .buffered, defer: false)
		window.isReleasedWhenClosed = false
		window.contentView = host
		window.appearance = NSAppearance(named: .darkAqua)
		for _ in 0..<3 {
			host.layoutSubtreeIfNeeded()
			let size = host.fittingSize
			window.setContentSize(size)
			host.frame = NSRect(origin: .zero, size: size)
			RunLoop.current.run(until: Date().addingTimeInterval(0.03))
		}
		guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds), host.bounds.height > 0 else { return nil }
		host.cacheDisplay(in: host.bounds, to: rep)
		guard let bytes = rep.bitmapData else { return nil }
		return Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
	}
}
