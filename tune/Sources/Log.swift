import Foundation

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Tune.log")
    nonisolated(unsafe) static var toStdout = false
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func line(_ message: String) {
        lock.withLock {
            let text = "[\(formatter.string(from: Date()))] \(message)\n"
            if toStdout { FileHandle.standardError.write(Data(text.utf8)); return }
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.uint64Value > 1_000_000 {
                let old = url.deletingLastPathComponent().appendingPathComponent("Tune.old.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            let data = Data(text.utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
