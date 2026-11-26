import AppKit
import UniformTypeIdentifiers
import Vision

struct HistoryItem: Codable, Equatable {
	enum Kind: String, Codable { case card, text }
	var input: String
	var kind: Kind
	var result: String
	var date = Date()

	var summary: String {
		kind == .card ? Reply.card(result, to: nil).prefix(3).map(\.term).joined(separator: ", ") : result
	}
}

final class History {
	static let shared = History()
	private(set) var items: [HistoryItem] = []
	private let url = AppPaths.data.appendingPathComponent("history.json")
	private static let limit = 300

	private init() {
		if let data = try? Data(contentsOf: url) {
			let decoder = JSONDecoder()
			decoder.dateDecodingStrategy = .iso8601
			items = (try? decoder.decode([HistoryItem].self, from: data)) ?? []
		}
	}

	func add(_ item: HistoryItem) {
		items.removeAll { $0.input == item.input && $0.kind == item.kind }
		items.insert(item, at: 0)
		if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
		save()
	}

	func find(_ input: String, kind: HistoryItem.Kind) -> HistoryItem? {
		items.first { $0.kind == kind && $0.input == input }
	}

	func search(_ query: String, limit: Int = 100) -> [HistoryItem] {
		guard !query.isEmpty else { return Array(items.prefix(limit)) }
		return Array(items.lazy.filter {
			$0.input.localizedCaseInsensitiveContains(query) || $0.result.localizedCaseInsensitiveContains(query)
		}.prefix(limit))
	}

	func clear() {
		items = []
		save()
	}

	private func save() {
		AppPaths.ensureData()
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.prettyPrinted]
		if let data = try? encoder.encode(items) { try? data.write(to: url, options: .atomic) }
	}
}

enum WordFix {
	struct Result: Equatable {
		var text: String
		var note: String
	}

	private static let latin = Array("`qwertyuiop[]asdfghjkl;'zxcvbnm,.")
	private static let cyrillic = Array("ёйцукенгшщзхъфывапролджэячсмитьбю")

	static func toCyrillic(_ s: String) -> String {
		String(s.lowercased().map { c in latin.firstIndex(of: c).map { cyrillic[$0] } ?? c })
	}

	static func toLatin(_ s: String) -> String {
		String(s.lowercased().map { c in cyrillic.firstIndex(of: c).map { latin[$0] } ?? c })
	}

	static func layoutNote(_ typed: String, _ meant: String) -> String { "Layout: \(typed) → \(meant)" }
	static func typoNote(_ typed: String, _ meant: String) -> String { "Typo: \(typed) → \(meant)" }

	static func fix(_ text: String) -> Result? {
		let letters = text.filter(\.isLetter)
		guard letters.count >= 3 else { return nil }
		let isLatin = letters.allSatisfy { $0.isASCII }
		let isCyrillic = letters.allSatisfy { ("а"..."я").contains($0.lowercased()) || $0.lowercased() == "ё" }
		if isLatin {
			if known(text, "en") { return nil }
			let ru = toCyrillic(text)
			if known(ru, "ru") { return Result(text: ru, note: layoutNote(text, ru)) }
			if let guess = correction(text, "en") { return Result(text: guess, note: typoNote(text, guess)) }
		} else if isCyrillic {
			if known(text, "ru") { return nil }
			let en = toLatin(text)
			if known(en, "en") { return Result(text: en, note: layoutNote(text, en)) }
			if let guess = correction(text, "ru") { return Result(text: guess, note: typoNote(text, guess)) }
		}
		return nil
	}

	private static func language(_ code: String) -> String? {
		let all = NSSpellChecker.shared.availableLanguages
		return all.first { $0 == code } ?? all.first { $0.hasPrefix(code + "_") || $0.hasPrefix(code + "-") }
	}

	private static func known(_ text: String, _ code: String) -> Bool {
		guard let lang = language(code) else { return false }
		let r = NSSpellChecker.shared.checkSpelling(of: text, startingAt: 0, language: lang, wrap: false,
		                                            inSpellDocumentWithTag: 0, wordCount: nil)
		return r.location == NSNotFound
	}

	private static func correction(_ text: String, _ code: String) -> String? {
		guard let lang = language(code), !text.contains(" ") else { return nil }
		let range = NSRange(location: 0, length: (text as NSString).length)
		guard let c = NSSpellChecker.shared.correction(forWordRange: range, in: text, language: lang, inSpellDocumentWithTag: 0),
		      c.lowercased() != text.lowercased(), isTypo(text, c) else { return nil }
		return c
	}

	static func isTypo(_ a: String, _ b: String) -> Bool {
		let x = Array(a.lowercased()), y = Array(b.lowercased())
		guard x != y, abs(x.count - y.count) <= 2, min(x.count, y.count) >= 3 else { return false }
		var d = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
		for i in 0...x.count { d[i][0] = i }
		for j in 0...y.count { d[0][j] = j }
		for i in 1...x.count {
			for j in 1...y.count {
				d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
				if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
			}
		}
		return d[x.count][y.count] <= (x.count >= 6 ? 2 : 1)
	}
}

enum OCR {
	@MainActor static var dragTypes: [NSPasteboard.PasteboardType] {
		var types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]
		types += [UTType.jpeg, .heic, .gif, .webP, .bmp].map { NSPasteboard.PasteboardType($0.identifier) }
		types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
		return types
	}

	private static func isPicture(_ url: URL) -> Bool {
		let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
		return type?.conforms(to: .image) == true
	}

	private static func files(on board: NSPasteboard) -> [URL]? {
		guard let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return nil }
		return urls
	}

	private static func promises(on board: NSPasteboard) -> [NSFilePromiseReceiver] {
		let all = board.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
		return all.filter { $0.fileTypes.contains { UTType($0)?.conforms(to: .image) == true } }
	}

	static func carriesText(_ board: NSPasteboard) -> Bool {
		guard let raw = board.string(forType: .string) else { return false }
		let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return false }
		guard !text.contains(where: \.isNewline) else { return true }
		if !text.contains(where: \.isWhitespace), let scheme = URL(string: text)?.scheme?.lowercased(),
		   ["http", "https", "file", "data", "blob"].contains(scheme) { return false }
		return UTType(filenameExtension: (text as NSString).pathExtension)?.conforms(to: .image) != true
	}

	private static func imageTypes(on board: NSPasteboard) -> [NSPasteboard.PasteboardType] {
		(board.types ?? []).filter { UTType($0.rawValue)?.conforms(to: .image) == true }
	}

	static func image(from board: NSPasteboard) -> CGImage? {
		if let files = files(on: board) { return files.lazy.filter(isPicture).compactMap(decode(file:)).first }
		guard !carriesText(board) else { return nil }
		for type in imageTypes(on: board) {
			if let data = board.data(forType: type), let source = CGImageSourceCreateWithData(data as CFData, nil), let image = decode(source) { return image }
		}
		return NSImage(pasteboard: board)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
	}

	static func accepts(_ board: NSPasteboard) -> Bool {
		if let files = files(on: board) { return files.contains(where: isPicture) }
		if !promises(on: board).isEmpty { return true }
		return !carriesText(board) && !imageTypes(on: board).isEmpty
	}

	@MainActor static func read(drag board: NSPasteboard, done: @escaping (CGImage?) -> Void) {
		if let image = image(from: board) { return done(image) }
		guard let promise = promises(on: board).first else { return done(nil) }
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("translator-drop-\(UUID().uuidString)")
		guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return done(nil) }
		let queue = OperationQueue()
		queue.qualityOfService = .userInitiated
		queue.maxConcurrentOperationCount = 1
		var answered = false
		promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { url, error in
			guard !answered else { return }
			answered = true
			let image = error == nil ? decode(file: url) : nil
			try? FileManager.default.removeItem(at: folder)
			DispatchQueue.main.async { done(image) }
		}
	}

	private static func decode(file url: URL) -> CGImage? {
		CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(decode)
	}

	private static func decode(_ source: CGImageSource) -> CGImage? {
		guard CGImageSourceGetCount(source) > 0 else { return nil }
		let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
		let side = max(info?[kCGImagePropertyPixelWidth] as? Int ?? 0, info?[kCGImagePropertyPixelHeight] as? Int ?? 0)
		let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
		                                kCGImageSourceShouldCacheImmediately: true,
		                                kCGImageSourceThumbnailMaxPixelSize: side > 0 ? min(side, 12_000) : 12_000]
		return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
	}

	struct Line {
		var text: String
		var box: CGRect
	}

	static func recognize(_ image: CGImage, done: @escaping (String?) -> Void) {
		DispatchQueue.global(qos: .userInitiated).async {
			let request = VNRecognizeTextRequest()
			request.recognitionLevel = .accurate
			request.recognitionLanguages = ["ru-RU", "en-US"]
			request.usesLanguageCorrection = true
			try? VNImageRequestHandler(cgImage: image).perform([request])
			let lines = (request.results ?? []).compactMap { o in o.topCandidates(1).first.map { Line(text: $0.string, box: o.boundingBox) } }
			let text = Selection.clean(joined(lines))
			DispatchQueue.main.async { done(text) }
		}
	}

	static func joined(_ lines: [Line]) -> String {
		guard var out = lines.first?.text else { return "" }
		let widest = lines.map(\.box.width).max() ?? 1
		for (line, next) in zip(lines, lines.dropFirst()) {
			guard flows(line, into: next, widest: widest) else {
				out += "\n" + next.text
				continue
			}
			if out.count > 2, out.hasSuffix("-"), out.dropLast().last?.isLetter == true, next.text.first?.isLowercase == true {
				out.removeLast()
				out += next.text
			} else {
				out += " " + next.text
			}
		}
		return out
	}

	private static func flows(_ line: Line, into next: Line, widest: CGFloat) -> Bool {
		let height = max(line.box.height, next.box.height)
		let gap = line.box.minY - next.box.maxY
		guard gap > -height * 0.5, gap < height * 0.9, abs(line.box.minX - next.box.minX) < height * 1.5 else { return false }
		guard line.box.width >= widest * 0.45, line.box.width >= next.box.width * 0.7 else { return false }
		if let last = line.text.last, ".!?…:;".contains(last) { return false }
		guard let first = next.text.first, !"-–—•*·".contains(first), !first.isNumber else { return false }
		return true
	}
}
