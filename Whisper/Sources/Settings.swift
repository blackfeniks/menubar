import Foundation

enum AppPaths {
	static let root: URL = ProcessInfo.processInfo.environment["WHISPER_DIR"].map { URL(fileURLWithPath: $0) }
		?? Bundle.main.bundleURL.deletingLastPathComponent()
	static let models = root.appendingPathComponent("Models")
	static let data = root.appendingPathComponent("Data")

	static func ensureData() {
		try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
	}
}

final class Settings {
	static let shared = Settings()
	private let url = AppPaths.data.appendingPathComponent("settings.json")
	private var values: [String: Any]
	private static let defaults: [String: Any] = [
		"hintsEnabled": true, "unloadMinutes": 5,
	]

	private init() {
		values = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
	}

	private func get(_ key: String) -> Any? { values[key] ?? Self.defaults[key] }

	private func set(_ key: String, _ value: Any?) {
		values[key] = value
		AppPaths.ensureData()
		if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) {
			try? data.write(to: url, options: .atomic)
		}
	}

	var deviceUID: String? {
		get { get("deviceUID") as? String }
		set { set("deviceUID", newValue) }
	}

	let llmEnabled = true
	let livePreview = true
	let showHUD = true
	let sounds = true
	let dropFinalPeriod = true

	var hintsEnabled: Bool {
		get { get("hintsEnabled") as? Bool ?? true }
		set { set("hintsEnabled", newValue) }
	}

	var unloadMinutes: Int {
		get { max(1, get("unloadMinutes") as? Int ?? 5) }
		set { set("unloadMinutes", newValue) }
	}

	var askedPermissions: Bool {
		get { get("askedPermissions") as? Bool ?? false }
		set { set("askedPermissions", newValue) }
	}

	var hudOrigin: CGPoint? {
		get {
			guard let a = get("hudOrigin") as? [Double], a.count == 2 else { return nil }
			return CGPoint(x: a[0], y: a[1])
		}
		set { set("hudOrigin", newValue.map { [Double($0.x), Double($0.y)] }) }
	}
}

struct HistoryItem: Codable, Equatable {
	var id = UUID()
	var text: String
	var date: Date
	var app: String?
	var seconds: Double
}

final class History {
	static let url = AppPaths.data.appendingPathComponent("history.json")
	static let limit = 50
	private(set) var items: [HistoryItem] = []

	init() {
		if let data = try? Data(contentsOf: Self.url),
		   let decoded = try? JSONDecoder.iso.decode([HistoryItem].self, from: data) {
			items = decoded
		}
	}

	func add(_ item: HistoryItem) {
		items.insert(item, at: 0)
		if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
		save()
	}

	func clear() {
		items.removeAll()
		save()
	}

	private func save() {
		try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
		if let data = try? JSONEncoder.iso.encode(items) { try? data.write(to: Self.url, options: .atomic) }
	}
}

extension JSONDecoder {
	static var iso: JSONDecoder {
		let d = JSONDecoder()
		d.dateDecodingStrategy = .iso8601
		return d
	}
}

extension JSONEncoder {
	static var iso: JSONEncoder {
		let e = JSONEncoder()
		e.dateEncodingStrategy = .iso8601
		e.outputFormatting = [.prettyPrinted]
		return e
	}
}
