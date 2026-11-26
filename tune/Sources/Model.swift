import AppKit
import CoreAudio
import Observation
import SwiftUI

struct AppRow: Identifiable, Equatable {
    let key: String
    let name: String
    let gain: Float
    let presetID: UUID?
    let presetName: String?
    let playing: Bool
    var inCall = false
    var id: String { key }
}

@MainActor
@Observable
final class Model {
    @ObservationIgnored let engine: Engine
    var settings: SettingsStore { engine.settings }

    private(set) var outputs: [AudioDevice] = []
    private(set) var defaultOutput: AudioObjectID = noObject
    private(set) var outputVolume: Double = 0
    private(set) var outputSettable = true
    private(set) var inputs: [AudioDevice] = []
    private(set) var defaultInput: AudioObjectID = noObject
    private(set) var inputVolume: Double = 0
    private(set) var inputSettable = true
    private(set) var micActive = false
    private(set) var apps: [AppRow] = []
    private(set) var appKeys: [String] = []
    private(set) var presets: [Preset] = []
    private(set) var permission: CapturePermission.State = .unknown
    private(set) var captureFailing = false
    private(set) var fineTuneRunning = false

    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private let recent: TimeInterval = 300
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var previewMode = false
    @ObservationIgnored var pinnedKey: String? {
        didSet { if pinnedKey != oldValue { refresh() } }
    }
    @ObservationIgnored private var draggingOutput = false
    @ObservationIgnored private var draggingInput = false
    @ObservationIgnored private var expiry: DispatchWorkItem?

    init(engine: Engine) {
        self.engine = engine
    }

    func start() {
        engine.onChange = { [weak self] in self?.refresh() }
        engine.devices.onVolume = { [weak self] in self?.refreshVolumes() }
        refreshFineTune()
        engine.start()
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == "com.finetuneapp.FineTune" else { return }
                let quit = name == NSWorkspace.didTerminateApplicationNotification
                MainActor.assumeIsolated { self?.fineTuneChanged(quit: quit) }
            })
        }
        refreshFineTune()
        refresh()
    }

    func refresh() {
        guard !previewMode else { return }
        let devices = engine.devices
        if outputs != devices.outputs { outputs = devices.outputs }
        if inputs != devices.inputs { inputs = devices.inputs }
        let moved = defaultOutput != devices.defaultOutput || defaultInput != devices.defaultInput
        if defaultOutput != devices.defaultOutput { defaultOutput = devices.defaultOutput }
        if defaultInput != devices.defaultInput { defaultInput = devices.defaultInput }
        if moved { refreshVolumes() }
        let now = Date()
        let listening = engine.active
        var rows = engine.processes.apps.values
            .filter { app in
                guard !ProcessMonitor.hiddenApps.contains(app.key) else { return false }
                if app.key == pinnedKey { return true }
                if app.isRecorder(at: now) { return app.playing && settings.needsProcessing(app.key) }
                return listening ? engine.isAudible(app, within: recent) : app.playing
            }
            .sorted { $0.firstSeen < $1.firstSeen }
            .map { app -> AppRow in
                let p = settings.prefs(app.key)
                return AppRow(key: app.key, name: app.name, gain: p.gain, presetID: p.presetID,
                              presetName: settings.preset(p.presetID)?.name, playing: app.playing, inCall: app.inCall)
            }
        if let key = pinnedKey, !rows.contains(where: { $0.key == key }), let old = apps.first(where: { $0.key == key }) {
            let p = settings.prefs(key)
            rows.append(AppRow(key: key, name: old.name, gain: p.gain, presetID: p.presetID,
                               presetName: settings.preset(p.presetID)?.name, playing: false))
        }
        setApps(rows)
        scheduleExpiry(now: now, listening: listening)
        let recording = engine.processes.apps.values.contains { $0.recording && !ProcessMonitor.hiddenApps.contains($0.key) }
        if micActive != recording {
            micActive = recording
            if recording { refreshVolumes() }
            Log.line(recording ? "Mic row shown (an app records)" : "Mic row hidden")
        }
        if presets != settings.data.presets { presets = settings.data.presets }
        if permission != engine.permission { permission = engine.permission }
        if captureFailing != engine.captureFailing { captureFailing = engine.captureFailing }
    }

    private func scheduleExpiry(now: Date, listening: Bool) {
        expiry?.cancel()
        expiry = nil
        guard listening else { return }
        let ends = engine.processes.apps.values.compactMap { app -> Date? in
            guard app.key != pinnedKey, appKeys.contains(app.key) else { return nil }
            return engine.audibleUntil(app, within: recent)
        }
        guard let next = ends.filter({ $0 > now }).min() else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + next.timeIntervalSince(now) + 0.2, execute: work)
    }

    private func setApps(_ rows: [AppRow]) {
        if rows != apps { apps = rows }
        let keys = rows.map(\.key)
        if keys != appKeys {
            appKeys = keys
            if !previewMode { Log.line("List: \(rows.isEmpty ? "nothing is playing" : rows.map(\.name).joined(separator: ", "))") }
        }
    }

    func refreshVolumes() {
        guard !previewMode else { return }
        let devices = engine.devices
        if !draggingOutput {
            let out = Double(devices.volume(defaultOutput) ?? 0) * (devices.isMuted(defaultOutput) ? 0 : 1)
            if abs(out - outputVolume) > 0.0005 { outputVolume = out }
        }
        let outSettable = devices.canSetVolume(defaultOutput)
        if outSettable != outputSettable { outputSettable = outSettable }
        if !draggingInput {
            let inp = Double(devices.volume(defaultInput, input: true) ?? 0)
            if abs(inp - inputVolume) > 0.0005 { inputVolume = inp }
        }
        let inSettable = devices.canSetVolume(defaultInput, input: true)
        if inSettable != inputSettable { inputSettable = inSettable }
    }

    private func fineTuneChanged(quit: Bool) {
        if fineTuneRunning != !quit { fineTuneRunning = !quit }
        if !previewMode { engine.conflict = fineTuneRunning }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { self?.refreshFineTune() }
        }
    }

    private func refreshFineTune() {
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.finetuneapp.FineTune").isEmpty
        if fineTuneRunning != running { fineTuneRunning = running }
        if !previewMode { engine.conflict = fineTuneRunning }
    }

    func panelOpened() {
        engine.refreshPermission()
        refreshFineTune()
        refresh()
        refreshVolumes()
    }

    func icon(_ key: String) -> NSImage {
        if let cached = icons[key] { return cached }
        let image = ProcessMonitor.icon(for: key) ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        icons[key] = image
        return image
    }

    func row(_ key: String) -> AppRow? { apps.first { $0.key == key } }

    func curve(_ key: String) -> [Float] {
        let id = row(key)?.presetID ?? settings.prefs(key).presetID
        return presets.first { $0.id == id }?.gains ?? [Float](repeating: 0, count: EQMath.bands)
    }

    func selectOutput(_ id: AudioObjectID) {
        guard id != defaultOutput else { return }
        engine.devices.setDefaultOutput(id)
        defaultOutput = id
        refreshVolumes()
    }

    func selectInput(_ id: AudioObjectID) {
        guard id != defaultInput else { return }
        engine.devices.setDefaultInput(id)
        defaultInput = id
        refreshVolumes()
    }

    func setOutputVolume(_ v: Double) {
        if outputVolume != v { outputVolume = v }
        engine.devices.setVolume(defaultOutput, Float(v))
    }

    func setInputVolume(_ v: Double) {
        if inputVolume != v { inputVolume = v }
        engine.devices.setVolume(defaultInput, Float(v), input: true)
    }

    func draggingOutput(_ on: Bool) {
        draggingOutput = on
        if !on { refreshVolumes() }
    }

    func draggingInput(_ on: Bool) {
        draggingInput = on
        if !on { refreshVolumes() }
    }

    func removeMicDriver() {
        MicDriver.uninstall { ok in
            Log.line(ok ? "Tune Mic removed" : "Tune Mic removal cancelled or failed")
        }
    }

    func setGain(_ key: String, _ gain: Double) {
        settings.setGain(key, Float(gain))
        engine.appChanged(key)
        patchRow(key)
    }

    func setDragging(_ key: String, _ on: Bool) {
        engine.setDragging(key, on)
    }

    func selectPreset(_ key: String, _ id: UUID?) {
        settings.select(key, preset: id)
        engine.appChanged(key)
        patchRow(key)
    }

    func setBand(_ key: String, _ band: Int, _ gain: Float) {
        if let id = settings.prefs(key).presetID, settings.preset(id) != nil {
            settings.setBand(id, band: band, gain: gain)
            engine.presetChanged(id)
        } else {
            guard gain != 0 else { return }
            var gains = [Float](repeating: 0, count: EQMath.bands)
            gains[band] = gain
            let preset = settings.addPreset(named: row(key)?.name ?? "Preset", gains: gains)
            settings.select(key, preset: preset.id)
            engine.appChanged(key)
        }
        if presets != settings.data.presets { presets = settings.data.presets }
        patchRow(key)
    }

    @discardableResult
    func newPreset(for key: String) -> UUID {
        let preset = settings.addPreset(named: row(key)?.name ?? "Preset", gains: curve(key))
        presets = settings.data.presets
        selectPreset(key, preset.id)
        return preset.id
    }

    func rename(_ id: UUID, _ name: String) {
        settings.rename(id, to: name)
        if presets != settings.data.presets { presets = settings.data.presets }
        for row in apps where row.presetID == id { patchRow(row.key) }
    }

    func delete(_ id: UUID) {
        let users = apps.filter { $0.presetID == id }.map(\.key)
        settings.delete(id)
        for key in users { engine.appChanged(key) }
        presets = settings.data.presets
        for key in users { patchRow(key) }
    }

    private func patchRow(_ key: String) {
        guard let i = apps.firstIndex(where: { $0.key == key }) else { return }
        let p = settings.prefs(key)
        let old = apps[i]
        let new = AppRow(key: key, name: old.name, gain: p.gain, presetID: p.presetID,
                         presetName: settings.preset(p.presetID)?.name, playing: old.playing, inCall: old.inCall)
        if new != old { apps[i] = new }
    }

    func quitFineTune() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.finetuneapp.FineTune") { app.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { self?.refreshFineTune() }
        }
    }

    func loadPreview(outputs: [AudioDevice], inputs: [AudioDevice], apps: [AppRow], presets: [Preset], mic: Bool = true) {
        previewMode = true
        self.outputs = outputs
        self.inputs = inputs
        defaultOutput = outputs.dropFirst().first?.id ?? outputs.first?.id ?? noObject
        defaultInput = inputs.first?.id ?? noObject
        outputVolume = 0.56
        inputVolume = 0.7
        micActive = mic
        setApps(apps)
        self.presets = presets
        permission = .granted
    }

    func setPreviewState(permission: CapturePermission.State, fineTune: Bool) {
        self.permission = permission
        fineTuneRunning = fineTune
    }

    func setPreviewMic(_ on: Bool) { micActive = on }
}
