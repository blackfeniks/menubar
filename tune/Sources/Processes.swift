import AppKit
import CoreAudio
import Darwin

struct AppInfo: Identifiable, Equatable {
    let key: String
    var name: String
    var processIDs: [AudioObjectID]
    var playing: Bool
    var recording: Bool = false
    var inCall: Bool = false
    var lastPlayed: Date?
    var playingSince: Date?
    var lastRecorded: Date?

    func isRecorder(at now: Date = Date()) -> Bool {
        recording || (lastRecorded.map { now.timeIntervalSince($0) < Self.recorderGrace } ?? false)
    }
    static let recorderGrace: TimeInterval = 10
    let firstSeen: Date
    var id: String { key }
}

@MainActor
final class ProcessMonitor {
    static let hiddenApps: Set<String> = ["com.finetuneapp.FineTune", "com.apple.controlcenter", "com.apple.loginwindow",
                                          "com.apple.systemuiserver", "com.apple.notificationcenterui", "com.apple.PowerChime"]
    private(set) var apps: [String: AppInfo] = [:]
    private(set) var justStarted: Set<String> = []
    var onChange: (() -> Void)?
    var onDevicesChange: (() -> Void)?

    private var listListener: Listener?
    private var perProcess: [AudioObjectID: [Listener]] = [:]
    private var keyCache: [pid_t: String] = [:]
    private var notApps: Set<pid_t> = []
    private let ownPID = getpid()
    private let ownBundle = Bundle.main.bundleIdentifier ?? "com.ilya.tune"

    private var launchObserver: NSObjectProtocol?
    private var refreshQueued = false
    private var running: [AudioObjectID: Directions] = [:]
    private var directionsCheck: Timer?
    private var duplexSince: [String: Date] = [:]
    private var callCheck: DispatchWorkItem?
    static let callEnter: TimeInterval = 1.5
    static let callLeave: TimeInterval = 6

    private struct Directions: Equatable {
        var output: Bool
        var input: Bool
        init(_ id: AudioObjectID) {
            output = (CA.get(id, address(kAudioProcessPropertyIsRunningOutput), as: UInt32(0)) ?? 0) != 0
            input = (CA.get(id, address(kAudioProcessPropertyIsRunningInput), as: UInt32(0)) ?? 0) != 0
        }
    }

    func start() {
        listListener = Listener(systemObject, address(kAudioHardwarePropertyProcessObjectList)) { [weak self] in self?.refreshSoon() }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.notApps.removeAll()
                self?.refreshSoon()
            }
        }
        refresh()
    }

    func stop() {
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
        listListener?.cancel()
        listListener = nil
        directionsCheck?.invalidate()
        directionsCheck = nil
        callCheck?.cancel()
        callCheck = nil
        duplexSince = [:]
        running = [:]
        perProcess.values.flatMap { $0 }.forEach { $0.cancel() }
        perProcess = [:]
        apps = [:]
        justStarted = []
        keyCache = [:]
        notApps = []
    }

    func refreshSoon() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refresh()
        }
    }

    func outputDevices(of key: String) -> [AudioObjectID] { devices(of: key, kAudioObjectPropertyScopeOutput) }

    func inputDevices(of key: String) -> [AudioObjectID] { devices(of: key, kAudioObjectPropertyScopeInput) }

    private func devices(of key: String, _ scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        var result: [AudioObjectID] = []
        for id in apps[key]?.processIDs ?? [] {
            for d in CA.ids(id, address(kAudioProcessPropertyDevices, scope)) where !result.contains(d) {
                result.append(d)
            }
        }
        return result
    }

    var recordingApps: [AppInfo] { apps.values.filter(\.recording) }

    func refresh() {
        let ids = CA.ids(systemObject, address(kAudioHardwarePropertyProcessObjectList))
        var pids: [AudioObjectID: pid_t] = [:]
        for id in ids { if let pid = CA.get(id, address(kAudioProcessPropertyPID), as: pid_t(0)), pid > 0 { pids[id] = pid } }
        for gone in perProcess.keys where pids[gone] == nil {
            perProcess[gone]?.forEach { $0.cancel() }
            perProcess[gone] = nil
        }
        for (id, pid) in pids where perProcess[id] == nil && pid != ownPID {
            perProcess[id] = [
                Listener(id, address(kAudioProcessPropertyIsRunning)) { [weak self] in self?.refreshSoon() },
                Listener(id, address(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput)) { [weak self] in self?.onDevicesChange?() },
            ].compactMap { $0 }
        }

        var runningApps: [pid_t: NSRunningApplication]? = nil
        var nowRunning: [AudioObjectID: Directions] = [:]
        var grouped: [String: (name: String, ids: [AudioObjectID], playing: Bool, recording: Bool)] = [:]
        for id in ids {
            guard let pid = pids[id], pid != ownPID else { continue }
            let key: String
            if let cached = keyCache[pid] {
                key = cached
            } else if notApps.contains(pid) {
                continue
            } else {
                if runningApps == nil {
                    runningApps = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
                }
                guard let app = Self.owningApp(of: pid, in: runningApps!), let bundle = app.bundleIdentifier, bundle != ownBundle else {
                    notApps.insert(pid)
                    continue
                }
                key = bundle
                keyCache[pid] = key
            }
            let directions = Directions(id)
            if (CA.get(id, address(kAudioProcessPropertyIsRunning), as: UInt32(0)) ?? 0) != 0 { nowRunning[id] = directions }
            let playing = directions.output
            let recording = directions.input
            var entry = grouped[key] ?? (name: "", ids: [], playing: false, recording: false)
            entry.ids.append(id)
            entry.playing = entry.playing || playing
            entry.recording = entry.recording || recording
            grouped[key] = entry
        }

        var next: [String: AppInfo] = [:]
        let now = Date()
        var started: Set<String> = []
        var nextCheck: Date?
        for (key, entry) in grouped {
            let old = apps[key]
            let name = old?.name ?? Self.displayName(key: key, pids: keyCache.filter { $0.value == key }.map(\.key))
            let wasPlaying = old?.playing == true
            if entry.playing, !wasPlaying { started.insert(key) }
            let duplex = entry.playing && entry.recording
            if duplex { if duplexSince[key] == nil { duplexSince[key] = now } } else { duplexSince[key] = nil }
            let micChanged = entry.recording != (old?.recording ?? false) ? now : old?.lastRecorded
            var inCall = old?.inCall ?? false
            if !inCall {
                if let since = duplexSince[key] {
                    let at = since.addingTimeInterval(Self.callEnter)
                    if now >= at { inCall = true } else { nextCheck = min(nextCheck ?? at, at) }
                }
            } else if !entry.recording {
                let at = (micChanged ?? now).addingTimeInterval(Self.callLeave)
                if now >= at { inCall = false } else { nextCheck = min(nextCheck ?? at, at) }
            }
            next[key] = AppInfo(key: key, name: name, processIDs: entry.ids.sorted(), playing: entry.playing,
                                recording: entry.recording, inCall: inCall,
                                lastPlayed: wasPlaying && !entry.playing ? now : old?.lastPlayed,
                                playingSince: entry.playing ? (wasPlaying ? old?.playingSince ?? now : now) : nil,
                                lastRecorded: micChanged,
                                firstSeen: old?.firstSeen ?? now)
        }
        for key in duplexSince.keys where grouped[key] == nil { duplexSince[key] = nil }
        justStarted = started
        callCheck?.cancel()
        callCheck = nil
        if let at = nextCheck {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
            callCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, at.timeIntervalSince(now) + 0.05), execute: work)
        }
        let livePIDs = Set(pids.values)
        keyCache = keyCache.filter { livePIDs.contains($0.key) }
        notApps = notApps.intersection(livePIDs)
        running = nowRunning
        updateDirectionsCheck()

        if next != apps {
            for (key, app) in next where apps[key]?.playing != app.playing || apps[key]?.processIDs != app.processIDs
                || apps[key]?.inCall != app.inCall || apps[key]?.recording != app.recording {
                Log.line("\(key): \(app.playing ? "plays" : "quiet")\(app.recording ? " + mic" : "")\(app.inCall ? " (call)" : ""), processes \(app.processIDs)")
            }
            apps = next
            onChange?()
        }
    }

    private func updateDirectionsCheck() {
        if running.isEmpty {
            directionsCheck?.invalidate()
            directionsCheck = nil
        } else if directionsCheck == nil {
            directionsCheck = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.running.contains(where: { Directions($0.key) != $0.value }) { self.refreshSoon() }
                }
            }
            directionsCheck?.tolerance = 0.2
        }
    }

    private typealias ResponsibilityFunc = @convention(c) (pid_t) -> pid_t
    private static let responsibility: ResponsibilityFunc? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibilityFunc.self)
    }()

    private static func isApp(_ app: NSRunningApplication?) -> Bool {
        guard let app, app.bundleURL?.pathExtension == "app" else { return false }
        return app.activationPolicy != .prohibited
    }

    static func owningApp(of pid: pid_t, in running: [pid_t: NSRunningApplication]) -> NSRunningApplication? {
        if let responsibility {
            let owner = responsibility(pid)
            if owner > 0, isApp(running[owner]) { return running[owner] }
        }
        if isApp(running[pid]) { return running[pid] }
        var current = pid
        var seen = Set<pid_t>()
        while current > 1, seen.insert(current).inserted {
            if isApp(running[current]) { return running[current] }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { break }
            let parent = info.kp_eproc.e_ppid
            if parent == current { break }
            current = parent
        }
        return nil
    }

    static func displayName(key: String, pids: [pid_t]) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: key).first, let name = app.localizedName {
            return name
        }
        return FineTuneImport.appName(for: key) ?? key
    }

    static func icon(for key: String) -> NSImage? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: key).first, let icon = app.icon { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
