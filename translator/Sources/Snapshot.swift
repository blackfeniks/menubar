import AppKit
import SwiftUI

enum Snapshot {
	static let states = ["01-empty", "02-loading", "03-word", "04-idiom", "05-english-word", "06-layout", "07-text", "08-stale",
	                     "09-alternatives", "10-simpler", "11-ask", "12-mixed", "13-russian", "14-picture", "15-no-text",
	                     "16-history", "17-failure",
	                     "18-counts-two", "19-counts-max", "20-counts-keys", "21-swap-keys", "22-long-word", "23-long-term",
	                     "24-too-long", "25-long-history", "26-long-ask", "27-long-failure", "28-long-alternatives", "29-hover", "29-drop", "32-input-open",
	                     "30-settings", "31-settings-worst", "33-settings-list"]

	@MainActor
	static func run(_ dir: String, only: String?) -> Int32 {
		_ = NSApplication.shared
		try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		var failed = 0
		for name in states where only == nil || name.contains(only!) {
			RowCheck.items = [:]
			let ok: Bool
			if name.contains("settings") {
				ok = settings(name, dir: dir)
			} else {
				let session = Session.demo(name)
				let ui = PanelUI()
				ui.commandHeld = name.hasSuffix("-keys")
				ui.pointerOverForm = name.hasSuffix("-hover")
				ui.dropping = name.hasSuffix("-drop")
				let m = Look.margin
				let root = PanelView(session: session, ui: ui, onPicture: { _ in })
					.padding(EdgeInsets(top: m.top, leading: m.left, bottom: m.bottom, trailing: m.right))
					.background(Color(red: 0.17, green: 0.19, blue: 0.24))
				let host = NSHostingView(rootView: root)
				render(host, name, dir: dir)
				ok = verify(name, width: Look.width, in: host)
			}
			if !ok { failed += 1 }
		}
		RowCheck.items = nil
		print(failed == 0 ? "✓ все строки по правилам" : "✗ состояний с нарушениями: \(failed)")
		return failed == 0 ? 0 : 1
	}

	@MainActor
	private static func render(_ host: NSView, _ name: String, dir: String) {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: .borderless,
		                      backing: .buffered, defer: false)
		window.contentView = host
		window.appearance = NSAppearance(named: .darkAqua)
		for _ in 0..<3 {
			host.layoutSubtreeIfNeeded()
			let size = host.fittingSize
			window.setContentSize(size)
			host.frame = NSRect(origin: .zero, size: size)
			RunLoop.current.run(until: Date().addingTimeInterval(0.05))
		}
		guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
		host.cacheDisplay(in: host.bounds, to: rep)
		let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
		try? rep.representation(using: .png, properties: [:])?.write(to: url)
		print("✓ \(url.path)")
	}

	@MainActor
	private static func settings(_ name: String, dir: String) -> Bool {
		let worst = name.hasSuffix("worst")
		Bar.offscreen = true
		func view() -> some View {
			let model = SettingsModel(hotkeyOn: !worst, historyCount: worst ? 300 : 0, onOpenAccessibility: {})
			if name.hasSuffix("list") { model.openUnload() }
			return SettingsView(model: model).barGlass().environment(\.colorScheme, .dark)
		}
		let controller = NSHostingController(rootView: view())
		let atOpen = controller.view.fittingSize
		let window = NSWindow(contentRect: NSRect(origin: .zero, size: atOpen), styleMask: .borderless, backing: .buffered, defer: false)
		window.appearance = NSAppearance(named: .darkAqua)
		window.contentViewController = controller
		for _ in 0..<3 {
			controller.view.layoutSubtreeIfNeeded()
			RunLoop.current.run(until: Date().addingTimeInterval(0.05))
		}
		let settled = controller.view.fittingSize
		let steady = abs(atOpen.width - settled.width) < 0.5 && abs(atOpen.height - settled.height) < 0.5
		print((steady ? "  ✓ " : "  ✗ ") + "\(name): размер при открытии \(Int(atOpen.width))×\(Int(atOpen.height)), "
			+ "после раскладки \(Int(settled.width))×\(Int(settled.height))")
		RowCheck.items = [:]
		let host = NSHostingView(rootView: view().padding(14).background(Color(white: 0.3)))
		render(host, name, dir: dir)
		return verify(name, width: SettingsView.width, in: host) && steady
	}

	@MainActor
	private static func verify(_ name: String, width: CGFloat, in host: NSView) -> Bool {
		let items = (RowCheck.items ?? [:]).values.filter { !$0.frame.isNull }
			.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
		var problems: [String] = []
		func n(_ x: CGFloat) -> String { String(format: "%.1f", x) }
		for it in items {
			let f = it.frame, given = it.frame.size, what = "«\(it.text)»"
			switch it.kind {
			case .label:
				if given.width < it.ideal.width - 0.5 { problems.append("подпись \(what) уже своего текста: \(n(given.width)) из \(n(it.ideal.width))") }
				if given.height > it.ideal.height + 0.5 { problems.append("подпись \(what) переносится: высота \(n(given.height)) вместо \(n(it.ideal.height))") }
			case .shortened:
				if given.height > it.ideal.height + 0.5 { problems.append("\(what) не в одну строку: высота \(n(given.height))") }
				if given.width < min(it.ideal.width, 72) - 0.5 { problems.append("\(what) сжат почти до нуля: \(n(given.width)) из \(n(it.ideal.width))") }
			case .wrapping:
				if given.width < it.minWidth - 0.5 { problems.append("\(what) рвёт слово: колонка \(n(given.width)), слово \(n(it.minWidth))") }
			}
			if f.minX < -0.5 || f.maxX > width + 0.5 { problems.append("\(what) за краем: \(n(f.minX))…\(n(f.maxX)) из \(n(width))") }
		}
		for (i, a) in items.enumerated() {
			for b in items[(i + 1)...] where (a.row == "keys") == (b.row == "keys") {
				let x = a.frame.intersection(b.frame)
				if !x.isNull, x.width > 0.5, x.height > 0.5 { problems.append("«\(a.text)» налезает на «\(b.text)»") }
			}
		}
		var edges: [RowCheck.Edge: [RowCheck.Item]] = [:]
		for it in items { if let e = it.edge { edges[e, default: []].append(it) } }
		for (edge, group) in edges {
			let xs: [CGFloat], label: String
			switch edge {
			case let .leading(g): xs = group.map(\.frame.minX); label = "левый край «\(g)»"
			case let .trailing(g): xs = group.map(\.frame.maxX); label = "правый край «\(g)»"
			}
			if let lo = xs.min(), let hi = xs.max(), hi - lo > 0.5 {
				problems.append("\(label) разъехался: " + zip(group, xs).map { "«\($0.text)» \(n($1))" }.joined(separator: ", "))
			}
		}
		for field in textFields(in: host) where !field.stringValue.isEmpty {
			let needs = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: field.bounds.width, height: 10_000)).height ?? 0
			if needs > field.bounds.height + 0.5 {
				problems.append("поле «\(field.stringValue.prefix(24))…» переносит текст за свой край: нужно \(n(needs)), видно \(n(field.bounds.height))")
			}
		}
		let cut = items.filter { $0.kind == .shortened && $0.frame.width < $0.ideal.width - 0.5 }.map { "«\($0.text.prefix(24))»" }
		let summary = "\(name): текстов \(items.count)" + (cut.isEmpty ? "" : ", сокращено с «…»: " + cut.joined(separator: ", "))
		print((problems.isEmpty ? "  ✓ " : "  ✗ ") + summary)
		for p in problems { print("      " + p) }
		return problems.isEmpty
	}

	@MainActor
	private static func textFields(in view: NSView) -> [NSTextField] {
		view.subviews.flatMap { v -> [NSTextField] in
			(v as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? textFields(in: v)
		}
	}
}
