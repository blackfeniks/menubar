import Foundation

enum AppPaths {
	static let root: URL = ProcessInfo.processInfo.environment["TRANSLATOR_DIR"].map { URL(fileURLWithPath: $0) }
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

	private init() {
		values = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
	}

	private func set(_ key: String, _ value: Any?) {
		values[key] = value
		AppPaths.ensureData()
		if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) {
			try? data.write(to: url, options: .atomic)
		}
	}

	var unloadMinutes: Int {
		get { values["unloadMinutes"] as? Int ?? 3 }
		set { set("unloadMinutes", newValue) }
	}

	var translateSelection: Bool {
		get { values["translateSelection"] as? Bool ?? true }
		set { set("translateSelection", newValue) }
	}

	var windowPlace: CGPoint? {
		get {
			guard let place = values["windowPlace"] as? [String: Any], let x = (place["x"] as? NSNumber)?.doubleValue,
			      let top = (place["top"] as? NSNumber)?.doubleValue, x.isFinite, top.isFinite else { return nil }
			return CGPoint(x: x, y: top)
		}
		set { set("windowPlace", newValue.map { ["x": Double($0.x), "top": Double($0.y)] }) }
	}
}
