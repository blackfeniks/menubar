import AppKit
import SwiftUI

@MainActor
enum Snapshot {
	static func run(dir: String) -> Int32 {
		_ = NSApplication.shared
		Bar.offscreen = true
		let out = URL(fileURLWithPath: dir)
		try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
		let states: [(String, (HUDModel) -> Void)] = [
			("recording", { m in
				m.phase = .recording
				m.level = 0.7
				m.resumedAt = Date().addingTimeInterval(-12)
				m.text = "Открой pull request на GitHub и посмотри, что там упало в тестах,"
				m.draft = "а потом напиши мне"
			}),
			("recording-handsfree", { m in
				m.phase = .recording
				m.handsFree = true
				m.level = 0.2
				m.resumedAt = Date().addingTimeInterval(-75)
			}),
			("paused", { m in
				m.phase = .recording
				m.handsFree = true
				m.paused = true
				m.elapsedBase = 42
				m.text = "Сначала нужно собрать требования и обсудить их с командой, потом напишем прототип"
			}),
			("paused-empty", { m in
				m.phase = .recording
				m.handsFree = true
				m.paused = true
				m.elapsedBase = 3
			}),
			("processing", { m in
				m.phase = .processing
				m.text = "Скинь мне ссылку в Telegram, я посмотрю после Zoom."
			}),
			("done", { m in
				m.phase = .done
				m.text = "Дизайнер прислал фидбэк по макетам в Figma."
			}),
			("message", { m in
				m.phase = .message
				m.symbol = "doc.on.clipboard"
				m.message = "Не удалось вернуться в Telegram — текст в буфере обмена"
			}),
		]
		for (name, configure) in states {
			let model = HUDModel()
			configure(model)
			let renderer = ImageRenderer(content: HUDView(model: model).background(Color(white: 0.3)))
			renderer.scale = 2
			guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
			      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
				print("! cannot render \(name)")
				return 1
			}
			let url = out.appendingPathComponent("hud-\(name).png")
			try? png.write(to: url)
			print(url.path)
		}
		return historyList(out)
	}

	private static func historyList(_ out: URL) -> Int32 {
		let phrases = ["Глобально, да, если он таким же останется, то всё будет хорошо и даже немного лучше", "Я поэтому такой расслабленный и хожу",
		               "Когда нажимаю на иконку с меню-бара, ничего не происходит", "Не совсем понял про линию под полем ввода"]
		let items = (0..<47).map { HistoryItem(text: phrases[$0 % phrases.count], date: Date(), app: nil, seconds: 1) }
		let controller = Controller()
		let settle: (BarWheel?) -> Void = { w in for _ in 0..<240 where w?.advance(1.0 / 60) == true {} }
		let states: [(String, (MenuPanelModel) -> Void)] = [
			("panel", { _ in }),
			("panel-hover", { m in
				m.history?.pointer(42)
				settle(m.history)
			}),
			("panel-more", { m in
				m.toggleExpanded()
				m.history?.scrollBy(12)
				m.history?.pointer(120)
				settle(m.history)
			}),
			("panel-unload", { m in
				m.open(.unload)
				settle(m.picker)
			}),
			("panel-microphone", { m in
				m.open(.microphone)
				settle(m.picker)
			}),
		]
		for (name, configure) in states {
			let model = MenuPanelModel(controller: controller, items: items, close: {}, hint: { _, _ in })
			let host = NSHostingView(rootView: MenuPanelView(model: model).barGlass().padding(16).background(Color(red: 0.17, green: 0.19, blue: 0.24)))
			render(host, name, to: out, prepare: { configure(model) })
		}
		render(NSHostingView(rootView: HintView(text: phrases[0] + ". " + phrases[2] + ". " + phrases[3]).padding(16).background(Color(red: 0.17, green: 0.19, blue: 0.24))), "bubble", to: out)
		return 0
	}

	private static func render(_ host: NSView, _ name: String, to out: URL, prepare: () -> Void = {}) {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
		window.appearance = NSAppearance(named: .darkAqua)
		window.contentView = host
		for pass in 0..<4 {
			if pass == 1 { prepare() }
			host.layoutSubtreeIfNeeded()
			let size = host.fittingSize
			window.setContentSize(size)
			host.frame = NSRect(origin: .zero, size: size)
			RunLoop.current.run(until: Date().addingTimeInterval(0.5))
		}
		guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
		host.cacheDisplay(in: host.bounds, to: rep)
		let url = out.appendingPathComponent(name + ".png")
		try? rep.representation(using: .png, properties: [:])?.write(to: url)
		print(url.path)
	}
}
