import AppKit
import CoreAudio
import Foundation

@MainActor
final class Engine {
    let devices = DeviceMonitor()
    let processes = ProcessMonitor()
    let settings: SettingsStore
    private(set) var units: [String: TapUnit] = [:]

    private(set) var permission: CapturePermission.State = CapturePermission.state
    private(set) var captureFailing = false
    private var everHeard = false
    private var silentPlaySeconds = 0.0
    private var silentApps: Set<String> = []
    private var silenceVerdicts = 0
    private var captureRetry: DispatchWorkItem?

    private enum Cause: Int { case wake = 0, device, format, stall }
    private var quietTimers: [String: DispatchWorkItem] = [:]
    private var dropTimers: [String: DispatchWorkItem] = [:]
    private var rebuildWork: [String: DispatchWorkItem] = [:]
    private var rebuildDue: [String: Date] = [:]
    private var pendingCause: [String: Cause] = [:]
    private var pendingReason: [String: String] = [:]
    private var pendingRecreate: Set<String> = []
    private var rebuildLog: [String: [Date]] = [:]
    private var failures: [String: (count: Int, retryAt: Date)] = [:]
    private var retryWork: DispatchWorkItem?
    private var stallLog: [String: [Date]] = [:]
    private var overloadsLogged: [String: (count: Int, at: Date)] = [:]
    private var graveyard: [TapUnit] = []
    private var dragging: Set<String> = []
    private var building = false
    private var reconcileAgain = false
    private var reconcileQueued = false
    private var health: Timer?
    private var healthTicks = 0
    private var permissionPoll: Timer?
    private var serviceListener: Listener?
    private var observers: [NSObjectProtocol] = []
    private var stopped = false

    var onChange: (() -> Void)?

    var conflict = false {
        didSet {
            guard conflict != oldValue else { return }
            Log.line(conflict ? "FineTune is running: Tune waits" : "FineTune gone")
            reconcile()
        }
    }

    var active: Bool { permission == .granted && !captureFailing && !conflict }

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func start() {
        TuneSession.apply()
        MicDriver.restoreDefaultInput(preferredUID: settings.data.micSourceUID)
        devices.onChange = { [weak self] in self?.appDevicesChanged() }
        devices.onOutputFormat = { [weak self] in
            guard let self else { return }
            self.rebuildOn(device: self.devices.defaultOutput, "output format")
        }
        processes.onChange = { [weak self] in self?.processesChanged() }
        processes.onDevicesChange = { [weak self] in self?.appDevicesChanged() }
        devices.start()
        processes.start()
        serviceListener = Listener(systemObject, address(kAudioHardwarePropertyServiceRestarted)) { [weak self] in self?.serviceRestarted() }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.line("Woke from sleep")
                self?.rebuildAll(.wake, after: 1.5)
            }
        })
        Log.line("Engine started; capture permission: \(permission)")
        pollPermissionIfNeeded()
        reconcile()
    }

    func shutdown() {
        stopped = true
        permissionPoll?.invalidate()
        permissionPoll = nil
        health?.invalidate()
        health = nil
        retryWork?.cancel()
        captureRetry?.cancel()
        stopProbe()
        meterWork?.cancel()
        for key in Array(units.keys) { dropUnit(key, "quit") }
        processes.stop()
        devices.stop()
        serviceListener?.cancel()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        settings.saveNow()
    }

    private func pollPermissionIfNeeded() {
        guard permission != .granted, permissionPoll == nil else { return }
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.refreshPermission()
                if self.permission == .granted { timer.invalidate(); self.permissionPoll = nil }
            }
        }
    }

    func refreshPermission() {
        let now = CapturePermission.state
        guard now != permission else { return }
        permission = now
        Log.line("Capture permission: \(now)")
        pollPermissionIfNeeded()
        reconcile()
    }

    func requestPermission() {
        CapturePermission.request { [weak self] granted in
            Log.line("Capture permission request answered: \(granted)")
            self?.refreshPermission()
            if !granted { CapturePermission.openSettings() }
        }
    }

    func retryCapture() {
        silenceVerdicts = 0
        retryCaptureNow("asked from the panel")
    }

    private func retryCaptureNow(_ why: String) {
        captureRetry?.cancel()
        captureRetry = nil
        guard captureFailing else { return }
        Log.line("Trying capture again (\(why))")
        captureFailing = false
        silentPlaySeconds = 0
        silentApps = []
        permission = CapturePermission.state
        reconcile()
    }

    func appChanged(_ key: String) {
        if let unit = units[key], settings.needsProcessing(key) {
            unit.set(gain: settings.prefs(key).gain, eq: settings.curve(for: key))
            dropTimers.removeValue(forKey: key)?.cancel()
            return
        }
        reconcileSoon()
    }

    func presetChanged(_ id: UUID) {
        var needsLoop = false
        for (key, prefs) in settings.data.apps where prefs.presetID == id && processes.apps[key] != nil {
            if let unit = units[key], settings.needsProcessing(key) {
                unit.set(gain: prefs.gain, eq: settings.curve(for: key))
            } else {
                needsLoop = true
            }
        }
        if needsLoop { reconcileSoon() }
    }

    func setDragging(_ key: String, _ on: Bool) {
        if on { dragging.insert(key) } else if dragging.remove(key) != nil { reconcileSoon() }
    }

    func reconcileSoon() {
        guard !reconcileQueued else { return }
        reconcileQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconcileQueued = false
            self.reconcile()
        }
    }

    func reconcile() {
        if building { reconcileAgain = true; return }
        building = true
        defer {
            building = false
            if reconcileAgain {
                reconcileAgain = false
                reconcileSoon()
            }
        }

        guard active else {
            for key in Array(units.keys) { dropUnit(key, "capture unavailable") }
            stopProbe()
            updateHealthTimer()
            onChange?()
            return
        }
        let apps = processes.apps
        for key in Array(units.keys) where apps[key] == nil { dropUnit(key, "app gone") }
        dragging = dragging.filter { apps[$0] != nil }

        for (key, app) in apps {
            settings.remember(key, name: app.name)
            if app.inCall {
                if units[key] != nil { dropUnit(key, "in a call") }
                continue
            }
            guard settings.needsProcessing(key) else {
                units[key]?.set(gain: 1, eq: nil)
                scheduleDrop(key)
                continue
            }
            dropTimers.removeValue(forKey: key)?.cancel()
            if let f = failures[key], f.retryAt > Date() { continue }
            guard let unit = units[key] ?? makeUnit(key, app) else { continue }
            if unit.processIDs != app.processIDs, !pendingRecreate.contains(key), !unit.updateProcesses(app.processIDs) {
                pendingRecreate.insert(key)
                scheduleRebuild(key, "process list", .format)
            }
            unit.set(gain: settings.prefs(key).gain, eq: settings.curve(for: key))
            if app.playing {
                quietTimers.removeValue(forKey: key)?.cancel()
                guard let target = targetDevice(for: key) else { continue }
                if !unit.isAttached || unit.deviceID != target.id {
                    guard unit.attach(to: target) else { noteFailure(key, "attach to \(target.name)"); continue }
                }
                if !unit.running {
                    guard unit.start() else { noteFailure(key, "start"); continue }
                    failures[key] = nil
                }
            } else if unit.running, quietTimers[key] == nil {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.quietTimers[key] = nil
                        if self.processes.apps[key]?.playing != true { self.units[key]?.stop(); self.updateHealthTimer() }
                    }
                }
                quietTimers[key] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
            }
        }
        updateHealthTimer()
        checkMeters()
        scheduleProbe()
        onChange?()
    }

    private func makeUnit(_ key: String, _ app: AppInfo) -> TapUnit? {
        let unit = TapUnit(key: key, processIDs: app.processIDs)
        unit.set(gain: settings.prefs(key).gain, eq: settings.curve(for: key))
        guard unit.createTap() else { noteFailure(key, "tap"); return nil }
        unit.onBroken = { [weak self, weak unit] reason in
            guard let self, let unit, self.units[key] === unit else { return }
            self.scheduleRebuild(key, reason, reason == "device gone" ? .device : .format)
        }
        units[key] = unit
        if let target = targetDevice(for: key), !unit.attach(to: target) {
            Log.line("\(key): could not prepare on \(target.name) yet")
        }
        Log.line("\(key): tapped (\(app.processIDs.count) process(es))")
        return unit
    }

    private func scheduleDrop(_ key: String) {
        guard units[key] != nil, dropTimers[key] == nil, !dragging.contains(key) else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dropTimers[key] = nil
                guard !self.dragging.contains(key), !self.settings.needsProcessing(key) else { return }
                self.dropUnit(key, "no longer needed")
                self.updateHealthTimer()
            }
        }
        dropTimers[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func dropUnit(_ key: String, _ reason: String) {
        quietTimers.removeValue(forKey: key)?.cancel()
        dropTimers.removeValue(forKey: key)?.cancel()
        rebuildWork.removeValue(forKey: key)?.cancel()
        rebuildDue[key] = nil
        pendingCause[key] = nil
        pendingReason[key] = nil
        pendingRecreate.remove(key)
        overloadsLogged[key] = nil
        guard let unit = units.removeValue(forKey: key) else { return }
        unit.onBroken = nil
        unit.destroy()
        Log.line("\(key): released (\(reason))")
        if !building { scheduleProbe() }
    }

    private func targetDevice(for key: String) -> AudioDevice? {
        let ids = processes.outputDevices(of: key)
        if ids.isEmpty || ids.contains(devices.defaultOutput), let d = devices.anyDevice(devices.defaultOutput) { return d }
        for id in ids {
            if let device = devices.anyDevice(id) { return device }
        }
        return devices.anyDevice(devices.defaultOutput)
    }

    private func noteFailure(_ key: String, _ what: String) {
        let count = (failures[key]?.count ?? 0) + 1
        release(key, for: min(60.0, pow(2.0, Double(count))), count: count, what)
    }

    private func release(_ key: String, for pause: Double, count: Int, _ what: String) {
        failures[key] = (count, Date().addingTimeInterval(pause))
        Log.line("\(key): \(what) — the app keeps its own sound; retry in \(Int(pause)) s")
        dropUnit(key, what)
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryWork?.cancel()
        guard let next = failures.values.map(\.retryAt).filter({ $0 > Date() }).min() else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reconcile() } }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, next.timeIntervalSinceNow + 0.05), execute: work)
    }

    private func appDevicesChanged() {
        guard !building else { reconcileAgain = true; return }
        for (key, unit) in units where unit.isAttached {
            if let target = targetDevice(for: key), target.id != unit.deviceID {
                if unit.running { unit.dsp.silence() }
                scheduleRebuild(key, "device changed", .device, after: unit.running ? 0.05 : 0.6)
            }
        }
        onChange?()
    }

    private func processesChanged() {
        if captureFailing, silenceVerdicts < 3, !processes.justStarted.isEmpty {
            retryCaptureNow("an app started playing")
        }
        noteHearingChanges()
        reconcile()
    }

    private func rebuildOn(device: AudioObjectID, _ reason: String) {
        for (key, unit) in units where unit.deviceID == device { scheduleRebuild(key, reason, .format) }
    }

    private func rebuildAll(_ cause: Cause, after delay: Double = 0.25) {
        for key in units.keys { scheduleRebuild(key, "\(cause)", cause, after: delay) }
    }

    private func scheduleRebuild(_ key: String, _ reason: String, _ cause: Cause, after delay: Double = 0.25) {
        guard let unit = units[key] else { return }
        if cause == .format || cause == .stall { unit.dsp.silence() }
        if let old = pendingCause[key], old.rawValue > cause.rawValue {} else {
            pendingCause[key] = cause
            pendingReason[key] = reason
        }
        let due = Date().addingTimeInterval(delay)
        if rebuildWork[key] != nil, let current = rebuildDue[key], current <= due { return }
        rebuildWork[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rebuild(key) }
        }
        rebuildWork[key] = work
        rebuildDue[key] = due
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func rebuild(_ key: String) {
        rebuildWork[key] = nil
        rebuildDue[key] = nil
        let cause = pendingCause.removeValue(forKey: key) ?? .format
        let reason = pendingReason.removeValue(forKey: key) ?? "\(cause)"
        guard let unit = units[key] else { return }
        if building { scheduleRebuild(key, reason, cause, after: 0.05); return }
        if pendingRecreate.contains(key) {
            Log.line("\(key): new tap (\(reason))")
            dropUnit(key, "recreate")
            reconcile()
            return
        }
        guard let target = targetDevice(for: key) else { noteFailure(key, "no output for rebuild"); return }
        if cause == .device, unit.isAttached, unit.deviceID == target.id {
            unit.dsp.resume()
            return
        }
        if cause == .format || cause == .stall {
            let recent = (rebuildLog[key] ?? []).filter { Date().timeIntervalSince($0) < 60 } + [Date()]
            rebuildLog[key] = recent
            if recent.count > 6 {
                rebuildLog[key] = nil
                release(key, for: 300, count: failures[key]?.count ?? 0, "rebuilt \(recent.count) times in a minute")
                return
            }
        }
        building = true
        defer {
            building = false
            if reconcileAgain {
                reconcileAgain = false
                reconcileSoon()
            }
        }
        Log.line("\(key): rebuilding (\(reason))")
        unit.set(gain: settings.prefs(key).gain, eq: settings.curve(for: key))
        guard unit.attach(to: target) else { noteFailure(key, "reattach to \(target.name)"); return }
        if processes.apps[key]?.playing == true, !unit.running, !unit.start() { noteFailure(key, "start after rebuild"); return }
        updateHealthTimer()
    }

    private func serviceRestarted() {
        Log.line("Core Audio restarted: rebuilding everything")
        for unit in units.values { unit.onBroken = nil; unit.forget(); graveyard.append(unit) }
        units = [:]
        probe?.forget()
        probe = nil
        probeWork?.cancel()
        probeWork = nil
        rebuildWork.values.forEach { $0.cancel() }
        rebuildWork = [:]
        rebuildDue = [:]
        pendingCause = [:]
        pendingReason = [:]
        pendingRecreate = []
        processes.stop()
        devices.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                TuneSession.apply()
                self.devices.start()
                self.processes.start()
                self.reconcile()
            }
        }
    }

    private func updateHealthTimer() {
        let any = units.values.contains { $0.running }
        if any, health == nil {
            health = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkHealth() }
            }
            health?.tolerance = 0.3
        } else if !any, let timer = health {
            timer.invalidate()
            health = nil
        }
    }

    private func checkHealth() {
        healthTicks += 1
        let now = Date()
        if healthTicks % 15 == 0 { refreshPermission() }
        for (key, unit) in units where unit.running {
            let calls = unit.dsp.callbacks
            let playingSince = processes.apps[key]?.playingSince
            let steady = playingSince.map { now.timeIntervalSince($0) > 4 } ?? false
            if calls == unit.lastCallbacks, steady, now.timeIntervalSince(unit.startedAt) > 4 {
                unit.stalls += 1
                if unit.stalls == 2 {
                    let recent = (stallLog[key] ?? []).filter { now.timeIntervalSince($0) < 120 } + [now]
                    stallLog[key] = recent
                    if recent.count > 3 { noteFailure(key, "keeps stalling"); continue }
                    scheduleRebuild(key, "callbacks stopped", .stall, after: 0)
                }
            } else {
                unit.stalls = 0
            }
            unit.lastCallbacks = calls
            if unit.dsp.heard > 0 { everHeard = true }
            let logged = overloadsLogged[key] ?? (0, .distantPast)
            if unit.overloads > logged.count, now.timeIntervalSince(logged.at) > 30 {
                Log.line("\(key): \(unit.overloads - logged.count) overload(s) on the device since last noted")
                overloadsLogged[key] = (unit.overloads, now)
            }
        }
        checkMeters()
        let silentNow = units.filter { $0.value.running && processes.apps[$0.key]?.playing == true }.map(\.key)
        if everHeard || silentNow.isEmpty {
            silentPlaySeconds = 0
            silentApps = []
        } else {
            silentPlaySeconds += 2
            silentApps.formUnion(silentNow)
            if silentPlaySeconds >= 90, silentApps.count >= 2 {
                silenceVerdicts += 1
                Log.line("Taps of \(silentApps.sorted()) heard only silence for 90 s: capture may not be working; releasing all apps")
                captureFailing = true
                let pause = silenceVerdicts < 3 ? 300.0 : 1800.0
                let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.retryCaptureNow("timer") } }
                captureRetry = work
                DispatchQueue.main.asyncAfter(deadline: .now() + pause, execute: work)
                reconcile()
            }
        }
        updateHealthTimer()
    }

    struct Hearing {
        var confirmed: Date?
        var lastAudible: Date?
        var nextProbe = Date.distantPast
        var backoff: TimeInterval = 15
        var meterStretch: Date?
        var meterDSP: UInt64 = 0
        var meterStart: UInt64 = 0
        var blips = 0
    }
    private(set) var hearing: [String: Hearing] = [:]
    private var probe: AudibilityProbe?
    private var probeWork: DispatchWorkItem?
    private static let probeSeconds = 2.5
    private static let audibleSeconds = 1.0
    private var meterWork: DispatchWorkItem?

    private func checkMeters() {
        let now = Date()
        var changed = false, fresh = false
        for (key, unit) in units where unit.running {
            guard let app = processes.apps[key], app.playing, let since = app.playingSince else { continue }
            var h = hearing[key] ?? Hearing()
            let dsp = unit.dsp
            if h.meterStretch != since || h.meterDSP != dsp.generation || dsp.loudFrames < h.meterStart {
                h.meterStretch = since
                h.meterDSP = dsp.generation
                h.meterStart = dsp.loudFrames
            }
            if h.confirmed != since {
                if dsp.loudFrames - h.meterStart >= UInt64(dsp.sampleRate * Self.audibleSeconds) {
                    h.confirmed = since
                    h.lastAudible = now
                    h.blips = 0
                    changed = true
                } else if now.timeIntervalSince(max(since, unit.startedAt)) < 5 {
                    fresh = true
                }
            }
            hearing[key] = h
        }
        if changed { onChange?() }
        meterWork?.cancel()
        meterWork = nil
        if fresh {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.checkMeters() } }
            meterWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    func isAudible(_ app: AppInfo, within recent: TimeInterval) -> Bool {
        guard let h = hearing[app.key] else { return false }
        if app.playing, let since = app.playingSince, h.confirmed == since { return true }
        return h.lastAudible.map { Date().timeIntervalSince($0) < recent } ?? false
    }

    func audibleUntil(_ app: AppInfo, within recent: TimeInterval) -> Date? {
        guard let h = hearing[app.key], let last = h.lastAudible else { return nil }
        if app.playing, let since = app.playingSince, h.confirmed == since { return nil }
        return last.addingTimeInterval(recent)
    }

    private func noteHearingChanges() {
        let now = Date()
        for (key, var h) in hearing {
            guard let app = processes.apps[key] else { hearing[key] = nil; continue }
            if !app.playing, h.confirmed != nil {
                h.confirmed = nil
                h.lastAudible = now
            }
            if processes.justStarted.contains(key), h.blips == 0 {
                h.nextProbe = .distantPast
                h.backoff = 15
            }
            hearing[key] = h
        }
    }

    private func scheduleProbe() {
        probeWork?.cancel()
        probeWork = nil
        guard active, !stopped, probe == nil else { return }
        let now = Date()
        var best: (key: String, at: Date)?
        for (key, app) in processes.apps where app.playing && !app.recording && units[key]?.running != true
            && !ProcessMonitor.hiddenApps.contains(key) {
            guard let since = app.playingSince else { continue }
            let h = hearing[key] ?? Hearing()
            if h.confirmed == since { continue }
            let recorderUntil = (app.lastRecorded ?? .distantPast).addingTimeInterval(AppInfo.recorderGrace)
            let at = max(since.addingTimeInterval(0.4), h.nextProbe, recorderUntil)
            if best == nil || at < best!.at { best = (key, at) }
        }
        guard let best else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.probeWork = nil
                self.startProbe(best.key)
            }
        }
        probeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, best.at.timeIntervalSince(now)), execute: work)
    }

    private func startProbe(_ key: String) {
        guard active, probe == nil, let app = processes.apps[key], app.playing, !app.isRecorder(),
              units[key]?.running != true else {
            scheduleProbe()
            return
        }
        guard let device = targetDevice(for: key), let p = AudibilityProbe(key: key, processIDs: app.processIDs, device: device) else {
            var h = hearing[key] ?? Hearing()
            h.nextProbe = Date().addingTimeInterval(60)
            hearing[key] = h
            scheduleProbe()
            return
        }
        probe = p
        checkProbe(p, stretch: app.playingSince)
    }

    private func checkProbe(_ p: AudibilityProbe, stretch: Date?) {
        guard probe === p else { return }
        let app = processes.apps[p.key]
        let elapsed = Date().timeIntervalSince(p.started)
        let stillSame = app?.playing == true && app?.playingSince == stretch
        if p.loudSeconds < Self.audibleSeconds, stillSame, elapsed < Self.probeSeconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                MainActor.assumeIsolated { self?.checkProbe(p, stretch: stretch) }
            }
            return
        }
        let loud = p.loudSeconds
        p.stop()
        probe = nil
        var h = hearing[p.key] ?? Hearing()
        let now = Date()
        if loud >= Self.audibleSeconds {
            h.confirmed = stretch
            h.lastAudible = now
            h.backoff = 15
            h.blips = 0
            Log.line("\(p.key): heard (\(String(format: "%.1f", loud)) s of sound)")
        } else if stillSame {
            h.nextProbe = now.addingTimeInterval(h.backoff)
            h.backoff = min(h.backoff * 2, 120)
            h.blips = 0
            Log.line("\(p.key): plays silence (\(String(format: "%.1f", loud)) s of sound in \(String(format: "%.1f", p.heardSeconds)) s)")
        } else {
            h.nextProbe = now.addingTimeInterval(min(60, 3 * pow(2, Double(h.blips))))
            h.blips += 1
        }
        hearing[p.key] = h
        onChange?()
        scheduleProbe()
    }

    private func stopProbe() {
        probeWork?.cancel()
        probeWork = nil
        probe?.stop()
        probe = nil
    }
}
