import AppKit
import Foundation

struct Preset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var gains: [Float]

    init(id: UUID = UUID(), name: String, gains: [Float]) {
        self.id = id
        self.name = name
        self.gains = Preset.normalized(gains)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Preset"
        gains = Preset.normalized((try? c.decode([Float].self, forKey: .gains)) ?? [])
    }

    static func normalized(_ gains: [Float]) -> [Float] {
        (0..<EQMath.bands).map { i in
            let g = i < gains.count && gains[i].isFinite ? gains[i] : 0
            return min(max(g, -EQMath.maxGain), EQMath.maxGain)
        }
    }
}

struct AppPrefs: Codable, Equatable {
    var gain: Float = 1
    var presetID: UUID? = nil
    var name: String? = nil

    init(gain: Float = 1, presetID: UUID? = nil, name: String? = nil) {
        self.gain = gain
        self.presetID = presetID
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gain = (try? c.decodeIfPresent(Float.self, forKey: .gain)) ?? 1
        presetID = try? c.decodeIfPresent(UUID.self, forKey: .presetID)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
    }
}

struct SettingsData: Codable, Equatable {
    var version = 1
    var presets: [Preset] = []
    var apps: [String: AppPrefs] = [:]
    var importedFromFineTune = false
    var micSourceUID: String? = nil

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        presets = ((try? c.decodeIfPresent([Lossy<Preset>].self, forKey: .presets)) ?? []).compactMap(\.value)
        apps = (try? c.decodeIfPresent([String: AppPrefs].self, forKey: .apps)) ?? [:]
        importedFromFineTune = (try? c.decodeIfPresent(Bool.self, forKey: .importedFromFineTune)) ?? false
        micSourceUID = try? c.decodeIfPresent(String.self, forKey: .micSourceUID)
    }
}

private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

final class SettingsStore {
    private(set) var data: SettingsData
    let url: URL
    private var saveWork: DispatchWorkItem?

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tune/settings.json")
    }
    static var fineTuneURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FineTune/settings.json")
    }

    init(url: URL = SettingsStore.defaultURL, fineTune: URL? = SettingsStore.fineTuneURL) {
        self.url = url
        let raw = try? Data(contentsOf: url)
        if let raw, let decoded = try? JSONDecoder().decode(SettingsData.self, from: raw) {
            data = decoded
        } else {
            if raw != nil {
                let aside = url.appendingPathExtension("unreadable")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.copyItem(at: url, to: aside)
                Log.line("Settings unreadable; kept a copy at \(aside.lastPathComponent)")
            }
            data = SettingsData()
            if let fineTune, let imported = FineTuneImport.load(from: fineTune) {
                data = imported
                Log.line("Imported FineTune settings: \(data.presets.count) presets, \(data.apps.count) apps")
            }
            saveNow()
        }
    }

    func prefs(_ key: String) -> AppPrefs { data.apps[key] ?? AppPrefs() }
    func preset(_ id: UUID?) -> Preset? { id.flatMap { id in data.presets.first { $0.id == id } } }
    func curve(for key: String) -> [Float]? { preset(prefs(key).presetID)?.gains }
    func needsProcessing(_ key: String) -> Bool {
        let p = prefs(key)
        return abs(p.gain - 1) > 0.0005 || (curve(for: key).map { !EQMath.isFlat($0) } ?? false)
    }

    func setGain(_ key: String, _ gain: Float) {
        data.apps[key, default: AppPrefs()].gain = min(max(gain, 0), Level.maxGain)
        save()
    }

    func remember(_ key: String, name: String) {
        guard data.apps[key]?.name != name, data.apps[key] != nil else { return }
        data.apps[key]?.name = name
        save()
    }

    func select(_ key: String, preset id: UUID?) {
        data.apps[key, default: AppPrefs()].presetID = id
        save()
    }

    func setBand(_ presetID: UUID, band: Int, gain: Float) {
        guard let i = data.presets.firstIndex(where: { $0.id == presetID }), band >= 0, band < EQMath.bands else { return }
        data.presets[i].gains[band] = min(max(gain, -EQMath.maxGain), EQMath.maxGain)
        save()
    }

    @discardableResult
    func addPreset(named base: String, gains: [Float]) -> Preset {
        let preset = Preset(name: uniqueName(base), gains: gains)
        data.presets.append(preset)
        save()
        return preset
    }

    func rename(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = data.presets.firstIndex(where: { $0.id == id }) else { return }
        data.presets[i].name = clean
        save()
    }

    func delete(_ id: UUID) {
        data.presets.removeAll { $0.id == id }
        for key in data.apps.keys where data.apps[key]?.presetID == id { data.apps[key]?.presetID = nil }
        save()
    }

    func uniqueName(_ base: String) -> String {
        let names = Set(data.presets.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private func save() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(data).write(to: url, options: .atomic)
        } catch {
            Log.line("Could not save settings: \(error.localizedDescription)")
        }
    }
}

enum FineTuneImport {
    private struct FT: Decodable {
        var appVolumes: [String: Float]?
        var appBoosts: [String: Float]?
        var appEQSettings: [String: EQ]?
        var userEQPresets: [UserPreset]?
        struct EQ: Decodable { var bandGains: [Float]; var isEnabled: Bool }
        struct UserPreset: Decodable { var name: String; var settings: EQ }
    }

    static func appKey(_ bundleID: String) -> String {
        if let r = bundleID.range(of: ".helper", options: .caseInsensitive) { return String(bundleID[..<r.lowerBound]) }
        return bundleID
    }

    static func load(from url: URL) -> SettingsData? {
        guard let raw = try? Data(contentsOf: url), let ft = try? JSONDecoder().decode(FT.self, from: raw) else { return nil }
        var out = SettingsData()
        out.importedFromFineTune = true
        for p in ft.userEQPresets ?? [] where !p.name.isEmpty {
            out.presets.append(Preset(name: p.name, gains: p.settings.bandGains))
        }
        let keys = Set((ft.appVolumes ?? [:]).keys).union((ft.appEQSettings ?? [:]).keys)
        for bundle in keys.sorted() {
            let key = appKey(bundle)
            var prefs = out.apps[key] ?? AppPrefs()
            if let v = ft.appVolumes?[bundle] {
                prefs.gain = min(max(v * (ft.appBoosts?[bundle] ?? 1), 0), Level.maxGain)
            }
            if let eq = ft.appEQSettings?[bundle], eq.isEnabled, !EQMath.isFlat(eq.bandGains) {
                let gains = Preset.normalized(eq.bandGains)
                let best = out.presets.map { p in (p, zip(p.gains, gains).map { abs($0 - $1) }.max() ?? 99) }
                    .min { $0.1 < $1.1 }
                if let best, best.1 < 0.6 {
                    prefs.presetID = best.0.id
                } else {
                    let name = appName(for: key) ?? key
                    let preset = Preset(name: uniqueName(name, in: out.presets), gains: gains)
                    out.presets.append(preset)
                    prefs.presetID = preset.id
                }
            }
            prefs.name = prefs.name ?? appName(for: key)
            out.apps[key] = prefs
        }
        return out
    }

    private static func uniqueName(_ base: String, in presets: [Preset]) -> String {
        let names = Set(presets.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    static func appName(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let bundle = Bundle(url: url)
        return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }
}
