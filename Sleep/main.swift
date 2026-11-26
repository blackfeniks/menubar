import SwiftUI
import AppKit
import Combine
import ServiceManagement
import IOKit
import IOKit.pwr_mgt

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Sleepness.log")
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func line(_ message: String) {
        lock.withLock {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
               size.uint64Value > 1_000_000 {
                let old = url.deletingLastPathComponent().appendingPathComponent("Sleepness.old.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            let data = Data("[\(formatter.string(from: Date()))] \(message)\n".utf8)
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

enum Shell {
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

enum Root {
    static let pmset = "/usr/bin/pmset"
    private static let rulePath = "/etc/sudoers.d/sleepness"
    private static let legacyRulePaths = ["/etc/sudoers.d/lidguard", "/etc/sudoers.d/vigil"]

    static func sleepDisabled() -> Bool? {
        let result = Shell.run(pmset, ["-g"])
        guard result.status == 0 else { return nil }
        guard let line = result.output.split(separator: "\n").first(where: { $0.contains("SleepDisabled") })
        else { return false }
        return line.split(whereSeparator: \.isWhitespace).last == "1"
    }

    static func setSleepDisabled(_ on: Bool) -> Bool {
        Shell.run("/usr/bin/sudo", ["-n", pmset, "-a", "disablesleep", on ? "1" : "0"]).status == 0
    }

    static func installRule() -> Bool {
        let user = NSUserName()
        guard !user.isEmpty, user.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { return false }
        let rule = "\(user) ALL=(root) NOPASSWD: \(pmset) -a disablesleep 1, \(pmset) -a disablesleep 0"
        let tmp = rulePath + ".tmp"
        let command = "/bin/mkdir -p /etc/sudoers.d && /bin/echo '\(rule)' > \(tmp) && /usr/sbin/chown root:wheel \(tmp) && /bin/chmod 0440 \(tmp) && /usr/sbin/visudo -c -f \(tmp) >/dev/null && /bin/mv -f \(tmp) \(rulePath) && /bin/rm -f \(legacyRulePaths.joined(separator: " ")) || { /bin/rm -f \(tmp); exit 1; }"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let prompt = "Sleepness needs administrator access once, so that it can switch sleep off and back on without asking again."
        return Shell.run("/usr/bin/osascript",
                         ["-e", "do shell script \"\(escaped)\" with administrator privileges with prompt \"\(prompt)\""]).status == 0
    }
}

enum Displays {
    static func externalActive() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }
}

enum SystemSleep {
    static func now() -> Bool {
        let port = IOPMFindPowerManagement(kIOMainPortDefault)
        if port != 0 {
            let result = IOPMSleepSystem(port)
            IOServiceClose(port)
            if result == kIOReturnSuccess { return true }
            Log.line("IOPMSleepSystem returned \(result), trying pmset sleepnow")
        }
        return Shell.run(Root.pmset, ["sleepnow"]).status == 0
    }
}

final class PowerAssertion {
    private var id = IOPMAssertionID(0)
    private let type: String
    private let name: String

    init(type: String, name: String) {
        self.type = type
        self.name = name
    }

    func set(_ on: Bool) {
        if on, id == 0 {
            let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     name as CFString, &id)
            if result != kIOReturnSuccess { id = 0; Log.line("Assertion \(type) FAILED (\(result))") }
        } else if !on, id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }
}

final class LidMonitor {
    static func isClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return read(service)
    }

    private static func read(_ service: io_object_t) -> Bool {
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }

    private(set) var closed = false
    private let onChange: (Bool) -> Void
    private var service: io_object_t = 0
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }

    func start() {
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        closed = Self.read(service)
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { context, _, _, _ in
            guard let context else { return }
            Unmanaged<LidMonitor>.fromOpaque(context).takeUnretainedValue().changed()
        }, Unmanaged.passUnretained(self).toOpaque(), &notifier)
    }

    private func changed() {
        let now = Self.read(service)
        guard now != closed else { return }
        closed = now
        onChange(now)
    }
}

enum DisplayBrightness {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    private typealias WatchFn = @convention(c) (UInt32, UInt64, UnsafeMutableRawPointer) -> Int32
    private typealias Ping = @convention(c) (UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?,
                                             UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

    nonisolated(unsafe) private static let handle =
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getFn: GetFn? = symbol("DisplayServicesGetBrightness")
    private static let setFn: SetFn? = symbol("DisplayServicesSetBrightness")
    private static let watchFn: WatchFn? = symbol("DisplayServicesRegisterForBrightnessChangeNotifications")

    private static func symbol<T>(_ name: String) -> T? {
        handle.flatMap { dlsym($0, name) }.map { unsafeBitCast($0, to: T.self) }
    }

    private static let lock = NSLock()
    private static let idKey = "builtinDisplayID"
    nonisolated(unsafe) private static var cachedID = CGDirectDisplayID(UserDefaults.standard.integer(forKey: idKey))
    nonisolated(unsafe) private static var lit: Float?

    static var available: Bool { getFn != nil && setFn != nil }

    private static func builtinID() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        let online: CGDirectDisplayID? = CGGetOnlineDisplayList(16, &ids, &count) == .success
            ? ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) : nil
        return lock.withLock {
            if let online, online != cachedID {
                cachedID = online
                UserDefaults.standard.set(Int(online), forKey: idKey)
            }
            return cachedID != 0 ? cachedID : nil
        }
    }

    static func get() -> Float? {
        guard let getFn, let id = builtinID() else { return nil }
        var value: Float = 0
        return getFn(id, &value) == 0 ? value : nil
    }

    @discardableResult
    static func set(_ value: Float) -> Bool {
        guard let setFn, let id = builtinID() else { return false }
        return setFn(id, value) == 0
    }

    static var lastLit: Float? { lock.withLock { lit } }

    static func watch() {
        note()
        guard let watchFn, let id = builtinID() else { return Log.line("Brightness notifications unavailable") }
        let ping: Ping = { _, _, _, _, _ in DisplayBrightness.note() }
        let result = watchFn(id, 0, unsafeBitCast(ping, to: UnsafeMutableRawPointer.self))
        Log.line("Brightness notifications \(result == 0 ? "on" : "FAILED (\(result))")")
    }

    static func note() {
        guard !LidMonitor.isClosed(), let value = get(), value >= 0.01 else { return }
        lock.withLock { lit = value }
    }
}

enum KeyboardBacklight {
    private typealias GetFn = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetFn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Void
    private static let keyboardID: UInt64 = 1

    nonisolated(unsafe) private static let client: NSObject? = {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        return (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init()
    }()
    nonisolated(unsafe) private static let msgSend = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")
    private static let getSelector = NSSelectorFromString("brightnessForKeyboard:")
    private static let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

    static var available: Bool { msgSend != nil && client?.responds(to: setSelector) == true }

    static func get() -> Float? {
        guard let client, let msgSend, client.responds(to: getSelector) else { return nil }
        return unsafeBitCast(msgSend, to: GetFn.self)(client, getSelector, keyboardID)
    }

    @discardableResult
    static func set(_ value: Float) -> Bool {
        guard let client, let msgSend, client.responds(to: setSelector) else { return false }
        unsafeBitCast(msgSend, to: SetFn.self)(client, setSelector, value, keyboardID)
        return true
    }
}

final class Watchdog {
    private var writer: FileHandle?
    private var lastLine = ""

    func start() {
        guard writer == nil else { return }
        let script = """
        trap '' HUP INT TERM
        LOG="$HOME/Library/Logs/Sleepness.log"; state=""
        stamp() { date '+%Y-%m-%d %H:%M:%S'; }
        while IFS= read -r line; do state="$line"; done
        set -- $state
        case "$1" in
          armed)
            echo "[$(stamp)] watchdog: Sleepness exited unexpectedly, restoring normal sleep" >> "$LOG"
            /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1
            "$SLEEPNESS_APP" --restore "${2:--}" "${3:--}" >/dev/null 2>&1 &
            if [ "${4:-0}" != "1" ] && /usr/sbin/ioreg -r -k AppleClamshellState -d 1 | /usr/bin/grep -q '"AppleClamshellState" = Yes'; then
              echo "[$(stamp)] watchdog: lid closed, putting the Mac to sleep" >> "$LOG"
              sleep 2
              /usr/bin/pmset sleepnow >/dev/null 2>&1
            fi
            ;;
          restore)
            "$SLEEPNESS_APP" --restore "${2:--}" "${3:--}" >/dev/null 2>&1 &
            ;;
        esac
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sleepness-watchdog"]
        process.environment = [
            "SLEEPNESS_APP": Bundle.main.executablePath ?? "",
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        let pipe = Pipe()
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            return Log.line("Watchdog failed to start: \(error.localizedDescription)")
        }
        writer = pipe.fileHandleForWriting
        Log.line("Watchdog running (pid \(process.processIdentifier))")
    }

    func report(_ line: String) {
        guard line != lastLine else { return }
        let data = Data((line + "\n").utf8)
        for attempt in 0..<2 {
            if writer == nil { start() }
            guard let writer else { return }
            do {
                try writer.write(contentsOf: data)
                lastLine = line
                return
            } catch {
                if attempt == 0 { Log.line("Watchdog write failed, restarting it") }
                try? writer.close()
                self.writer = nil
            }
        }
    }
}

@MainActor
final class Backlights {
    private let defaults = UserDefaults.standard
    private(set) var savedScreen: Float?
    private(set) var savedKeyboard: Float?
    private var lastLitKeyboard: Float?
    private var screenGen = 0
    private var keyboardGen = 0
    var onChange: (() -> Void)?

    init() {
        savedScreen = (defaults.object(forKey: Pref.savedScreen) as? Double).map(Float.init)
        savedKeyboard = (defaults.object(forKey: Pref.savedKeyboard) as? Double).map(Float.init)
    }

    var hasPending: Bool { savedScreen != nil || savedKeyboard != nil }

    func cancelRestore() {
        screenGen += 1
        keyboardGen += 1
    }

    func sampleKeyboard() {
        guard savedKeyboard == nil, let value = KeyboardBacklight.get(), value > 0 else { return }
        lastLitKeyboard = value
    }

    func dim() {
        screenGen += 1
        if savedScreen == nil {
            guard let level = [DisplayBrightness.get(), DisplayBrightness.lastLit].compactMap({ $0 })
                .filter({ $0 >= 0.01 }).max() else {
                Log.line("Screen dim skipped: no believable brightness to restore to")
                return dimKeyboard()
            }
            savedScreen = level
            defaults.set(Double(level), forKey: Pref.savedScreen)
        }
        let ok = DisplayBrightness.set(0)
        Log.line("Screen → 0 (\(ok ? "ok" : "FAILED"), back to \(savedScreen ?? -1) later)")
        dimKeyboard()
    }

    private func dimKeyboard() {
        defer { onChange?() }
        guard KeyboardBacklight.available else { return }
        keyboardGen += 1
        if savedKeyboard == nil {
            let current = KeyboardBacklight.get() ?? 0
            if let level = current > 0 ? current : lastLitKeyboard {
                savedKeyboard = level
                defaults.set(Double(level), forKey: Pref.savedKeyboard)
            }
        }
        KeyboardBacklight.set(0)
        Log.line("Keyboard light → 0 (back to \(savedKeyboard ?? -1) later)")
    }

    func restore(context: String) {
        guard hasPending else { return }
        Task { await restoreNow(quick: false, context: context) }
    }

    func restoreNow(quick: Bool, context: String) async {
        let delays: [Double] = quick ? [0, 0.3, 0.8] : [0, 0.3, 0.8, 1.5, 3, 5, 8]
        async let screen: Void = restoreScreen(delays, context)
        async let keyboard: Void = restoreKeyboard(delays, context)
        _ = await (screen, keyboard)
        onChange?()
    }

    private func restoreScreen(_ delays: [Double], _ context: String) async {
        guard let level = savedScreen else { return }
        screenGen += 1
        let gen = screenGen
        switch await settle(level, delays: delays, tolerance: 0.02, current: { gen == self.screenGen },
                            set: { DisplayBrightness.set($0) }, get: DisplayBrightness.get) {
        case .some(let attempt):
            savedScreen = nil
            defaults.removeObject(forKey: Pref.savedScreen)
            Log.line("Screen restored to \(level) (attempt \(attempt), \(context))")
        case .none where gen == screenGen:
            Log.line("Screen restore failed (\(context)), kept for the next try")
            if !LidMonitor.isClosed(), let now = DisplayBrightness.get(), now < 0.01 {
                DisplayBrightness.set(0.5)
                Log.line("Screen rescued to 0.5")
            }
        case .none:
            break
        }
    }

    private func restoreKeyboard(_ delays: [Double], _ context: String) async {
        guard let level = savedKeyboard else { return }
        keyboardGen += 1
        let gen = keyboardGen
        switch await settle(level, delays: delays, tolerance: 0.05, current: { gen == self.keyboardGen },
                            set: { KeyboardBacklight.set($0) }, get: KeyboardBacklight.get) {
        case .some(let attempt):
            savedKeyboard = nil
            defaults.removeObject(forKey: Pref.savedKeyboard)
            lastLitKeyboard = level
            Log.line("Keyboard light restored to \(level) (attempt \(attempt), \(context))")
        case .none where gen == keyboardGen:
            Log.line("Keyboard light restore failed (\(context)), kept for the next try")
        case .none:
            break
        }
    }

    private func settle(_ level: Float, delays: [Double], tolerance: Float, current: () -> Bool,
                        set: (Float) -> Void, get: () -> Float?) async -> Int? {
        for (index, delay) in delays.enumerated() {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard current() else { return nil }
            set(level)
            if let now = get(), abs(now - level) <= tolerance { return index + 1 }
        }
        return nil
    }
}

enum Pref {
    static let stayAwake = "stayAwake"
    static let timerMinutes = "timerMinutes"
    static let ownsSleepDisabled = "ownsSleepDisabled"
    static let savedScreen = "savedScreen"
    static let savedKeyboard = "savedKeyboard"
    static let maxTimerMinutes = 720

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [stayAwake: true, timerMinutes: 0])
    }
}

@MainActor
final class Sleepness: ObservableObject {
    @Published private(set) var isOn = false
    @Published private(set) var switching = false
    @Published private(set) var note: String?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var timerMinutes = 0
    @Published private(set) var deadline: Date?

    private let defaults = UserDefaults.standard
    private let displayAssertion = PowerAssertion(
        type: kIOPMAssertionTypePreventUserIdleDisplaySleep,
        name: "Sleepness: display stays on, so no screen saver and no lock")
    private let backlights = Backlights()
    private let watchdog = Watchdog()
    private var lid: LidMonitor?
    private var lidClosed = false
    private var sleepDisabled = false
    private var napToken: NSObjectProtocol?
    private var deadlineTimer: Timer?
    private var retryTask: Task<Void, Never>?
    private var retries = 0
    private var needsAnotherPass = false
    private var mayPrompt = false
    private var sleepWhenSettled = false
    private var sleepGen = 0
    private var quitting = false
    private var cleanedUp = false

    private static let outsideNote = "Sleep is disabled outside Sleepness (pmset)."

    private var owns: Bool {
        get { defaults.bool(forKey: Pref.ownsSleepDisabled) }
        set { defaults.set(newValue, forKey: Pref.ownsSleepDisabled) }
    }

    init() {
        Pref.registerDefaults()
        timerMinutes = Self.clampMinutes(defaults.integer(forKey: Pref.timerMinutes))
    }

    func start() {
        Log.line("=== Sleepness started (pid \(getpid())) ===")
        backlights.onChange = { [weak self] in self?.reportWatchdog() }
        watchdog.start()
        DisplayBrightness.watch()

        let lid = LidMonitor { [weak self] closed in
            MainActor.assumeIsolated { self?.lidChanged(closed) }
        }
        lid.start()
        self.lid = lid
        lidClosed = lid.closed

        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemDidWake() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportWatchdog() }
        }

        refreshLoginItem()
        backlights.sampleKeyboard()
        Log.line("Lid \(lidClosed ? "closed" : "open"); DisplayServices=\(DisplayBrightness.available); keyboard API=\(KeyboardBacklight.available)")
        isOn = defaults.bool(forKey: Pref.stayAwake)
        startCountdown()
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        sleepDisabled = await Task.detached { Root.sleepDisabled() }.value ?? (owns && !isOn)
        if sleepDisabled, !owns {
            Log.line("Launch: SleepDisabled=1 set outside Sleepness")
            if !isOn { note = Self.outsideNote }
        }
        Log.line("Launch: stay awake \(isOn ? "on" : "off"), as it was left")
        apply()
    }

    func setOn(_ on: Bool, byTimer: Bool = false) {
        guard on != isOn, !quitting else { return }
        Log.line(byTimer ? "Timer ran out: stay awake OFF" : "Stay awake \(on ? "ON" : "OFF")")
        if !byTimer { note = nil }
        flip(on)
        sleepWhenSettled = !on
        apply(interactive: !byTimer)
    }

    private func flip(_ on: Bool) {
        isOn = on
        defaults.set(on, forKey: Pref.stayAwake)
        sleepGen &+= 1
        startCountdown()
    }

    private func apply(interactive: Bool = false) {
        displayAssertion.set(isOn)
        setNapOptOut(isOn)
        scheduleDeadline()
        updateBacklights()
        reconcileSleep(interactive: interactive)
        reportWatchdog()
    }

    private func updateBacklights() {
        if !lidClosed {
            backlights.restore(context: isOn ? "lid open" : "switched off")
        } else if isOn {
            backlights.dim()
        } else {
            backlights.cancelRestore()
        }
    }

    private func setNapOptOut(_ on: Bool) {
        if on, napToken == nil {
            napToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Sleepness watches the lid and the timer while the Mac stays awake")
        } else if !on, let token = napToken {
            ProcessInfo.processInfo.endActivity(token)
            napToken = nil
        }
    }

    static func clampMinutes(_ minutes: Int) -> Int { min(max(minutes, 0), Pref.maxTimerMinutes) }

    func setTimer(_ minutes: Int) {
        let value = Self.clampMinutes(minutes)
        guard value != timerMinutes else { return }
        timerMinutes = value
        defaults.set(value, forKey: Pref.timerMinutes)
        Log.line("Timer → \(value == 0 ? "off" : "\(value) min")")
        startCountdown()
        scheduleDeadline()
    }

    private func startCountdown() {
        deadline = isOn && timerMinutes > 0 ? Date().addingTimeInterval(Double(timerMinutes) * 60) : nil
    }

    private func scheduleDeadline() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard isOn, let deadline else { return }
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.deadlineFired() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
        Log.line("Timer: \(timerMinutes) min, ends at \(Self.clock(deadline))")
    }

    private func deadlineFired() {
        guard isOn, let deadline else { return }
        if deadline.timeIntervalSinceNow > 1 { return scheduleDeadline() }
        setOn(false, byTimer: true)
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

    private func reconcileSleep(interactive: Bool = false) {
        if interactive { mayPrompt = true }
        guard !quitting else { return }
        guard !switching else { needsAnotherPass = true; return }
        let want: Bool? = isOn ? true : (owns ? false : nil)
        guard let want, want != sleepDisabled else {
            if let want { owns = want }
            mayPrompt = false
            settled()
            return
        }
        let prompt = mayPrompt
        mayPrompt = false
        switching = true
        retryTask?.cancel()
        retryTask = nil
        Task {
            var ok = await Task.detached { Root.setSleepDisabled(want) }.value
            if !ok, prompt {
                Log.line("Silent switch failed, asking for administrator access once")
                if await Task.detached(operation: { Root.installRule() }).value {
                    ok = await Task.detached { Root.setSleepDisabled(want) }.value
                }
            }
            let actual = await Task.detached { Root.sleepDisabled() }.value ?? (ok ? want : !want)
            self.switchFinished(want: want, actual: actual, prompted: prompt)
        }
    }

    private func switchFinished(want: Bool, actual: Bool, prompted: Bool) {
        switching = false
        sleepDisabled = actual
        if actual == want { owns = want }
        defer { reportWatchdog() }
        guard !quitting else { return }
        if actual == want {
            retries = 0
            note = nil
            Log.line("SleepDisabled → \(actual ? 1 : 0)")
            settled()
        } else if want {
            Log.line("Could not disable sleep (prompted=\(prompted))")
            flip(false)
            sleepWhenSettled = true
            note = prompted
                ? "Sleepness needs administrator access to keep the Mac awake."
                : "Needs administrator access: switch Stay awake on to allow it."
            needsAnotherPass = false
            return apply()
        } else {
            scheduleRetry()
        }
        if needsAnotherPass {
            needsAnotherPass = false
            reconcileSleep()
        }
    }

    private func settled() {
        guard !isOn, sleepWhenSettled, !(sleepDisabled && owns) else { return }
        sleepWhenSettled = false
        guard !sleepDisabled, LidMonitor.isClosed(), !Displays.externalActive() else { return }
        Log.line("Off with the lid shut: putting the Mac to sleep")
        let gen = sleepGen
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard gen == sleepGen, !isOn, !sleepDisabled, LidMonitor.isClosed(), !Displays.externalActive() else {
                return Log.line("Sleep called off")
            }
            let ok = await Task.detached { SystemSleep.now() }.value
            Log.line("Sleep request \(ok ? "sent" : "FAILED")")
        }
    }

    private func scheduleRetry() {
        let delays: [Double] = [5, 15, 30, 60, 120, 300]
        let delay = delays[min(retries, delays.count - 1)]
        retries += 1
        note = "Couldn't turn sleep back on. Retrying…"
        Log.line("Re-enabling sleep failed, retry #\(retries) in \(Int(delay))s")
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.reconcileSleep()
        }
    }

    private func refreshSystemState() {
        guard !switching, !quitting else { return }
        Task {
            guard let actual = await Task.detached(operation: { Root.sleepDisabled() }).value,
                  !switching, actual != sleepDisabled else { return }
            Log.line("SleepDisabled changed outside Sleepness → \(actual ? 1 : 0)")
            sleepDisabled = actual
            if !actual, note == Self.outsideNote { note = nil }
            reconcileSleep()
        }
    }

    private func lidChanged(_ closed: Bool) {
        lidClosed = closed
        Log.line("Lid \(closed ? "closed" : "opened")")
        if !closed { backlights.sampleKeyboard() }
        updateBacklights()
        reportWatchdog()
    }

    private func systemDidWake() {
        if !lidClosed { backlights.restore(context: "wake") }
        refreshSystemState()
        if isOn, let deadline, deadline <= Date() { deadlineFired() }
    }

    func panelOpened() {
        refreshSystemState()
        refreshLoginItem()
        if !lidClosed {
            DisplayBrightness.note()
            backlights.sampleKeyboard()
        }
    }

    func refreshLoginItem() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.line("Login item \(on ? "registered" : "removed")")
            if on, SMAppService.mainApp.status == .requiresApproval {
                note = "Allow Sleepness in System Settings → Login Items."
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            Log.line("Login item change FAILED: \(error.localizedDescription)")
            note = "Couldn't change Login Items: \(error.localizedDescription)"
        }
        refreshLoginItem()
    }

    private func reportWatchdog() {
        let screen = backlights.savedScreen.map { String($0) } ?? "-"
        let keyboard = backlights.savedKeyboard.map { String($0) } ?? "-"
        if isOn || switching || (sleepDisabled && owns) {
            watchdog.report("armed \(screen) \(keyboard) \(Displays.externalActive() ? 1 : 0)")
        } else if backlights.hasPending {
            watchdog.report("restore \(screen) \(keyboard)")
        } else {
            watchdog.report("idle")
        }
    }

    func quit() {
        guard !quitting else { return }
        quitting = true
        Log.line("Quit")
        isOn = false
        deadline = nil
        deadlineTimer?.invalidate()
        sleepGen &+= 1
        retryTask?.cancel()
        displayAssertion.set(false)
        setNapOptOut(false)
        Task {
            if !lidClosed { await backlights.restoreNow(quick: true, context: "quit") }
            let giveUp = Date().addingTimeInterval(5)
            while switching, Date() < giveUp { try? await Task.sleep(for: .milliseconds(100)) }
            let current = await Task.detached { Root.sleepDisabled() }.value ?? sleepDisabled
            if current, owns {
                var ok = await Task.detached { Root.setSleepDisabled(false) }.value
                if !ok, await Task.detached(operation: { Root.installRule() }).value {
                    ok = await Task.detached { Root.setSleepDisabled(false) }.value
                }
                let actual = await Task.detached { Root.sleepDisabled() }.value ?? true
                sleepDisabled = actual
                if !actual { owns = false }
                Log.line("Quit: SleepDisabled → \(actual ? "1 (FAILED to clear)" : "0")")
            } else {
                sleepDisabled = current
            }
            reportWatchdog()
            cleanedUp = true
            Log.line("Quit: done")
            NSApp.terminate(nil)
        }
    }

    func syncCleanup() {
        guard !cleanedUp else { return }
        cleanedUp = true
        quitting = true
        Log.line("Terminate: synchronous cleanup")
        isOn = false
        displayAssertion.set(false)
        if let level = backlights.savedScreen, !lidClosed { DisplayBrightness.set(level) }
        if let level = backlights.savedKeyboard, !lidClosed { KeyboardBacklight.set(level) }
        if sleepDisabled, owns, Root.setSleepDisabled(false) {
            owns = false
            sleepDisabled = false
        }
        reportWatchdog()
    }
}

private enum Icon {
    static let width: CGFloat = 26

    static func image(_ name: String, label: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        image?.isTemplate = true
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = Sleepness()
    private var statusItem: NSStatusItem?
    private var panel: BarPanel?
    private var iconWatch: AnyCancellable?
    private var sigterm: DispatchSourceSignal?
    private let onImage = Icon.image("sparkle", label: "Sleepness: staying awake")
    private let offImage = Icon.image("circle.dotted", label: "Sleepness: off")

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                Log.line("SIGTERM received")
                self?.leave()
            }
        }
        source.resume()
        sigterm = source

        let item = NSStatusBar.system.statusItem(withLength: Icon.width)
        item.button?.target = self
        item.button?.action = #selector(iconClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = "Sleepness"
        statusItem = item
        panel = BarPanel(statusItem: item)

        model.start()
        iconWatch = model.$isOn.removeDuplicates().sink { [weak self] on in
            guard let self else { return }
            statusItem?.button?.image = on ? onImage : offImage
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        iconWatch = nil
        model.syncCleanup()
        return .terminateNow
    }

    @objc private func iconClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            panel?.toggle { [model] in
                model.panelOpened()
                let relay = ScrollRelay()
                var content = BarContent(width: PanelMetrics.width, spare: PanelMetrics.spare) {
                    PanelView(model: model, relay: relay)
                }
                content.onScroll = { relay.handler?($0) ?? false }
                return content
            }
        }
    }

    private func showMenu() {
        panel?.close(animated: false)
        let menu = NSMenu()
        let log = NSMenuItem(title: "Open log", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Sleepness", action: #selector(quitSleepness), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openLog() { NSWorkspace.shared.open(Log.url) }

    @objc private func quitSleepness() { leave() }

    private func leave() {
        iconWatch = nil
        panel?.close(animated: false)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        model.quit()
    }
}

enum PanelMetrics {
    static let width: CGFloat = 272
    static let spare: CGFloat = 120
}

@MainActor
final class ScrollRelay {
    var handler: ((NSEvent) -> Bool)?
}

private struct TimerRuler: View {
    @Binding var minutes: Int
    let relay: ScrollRelay
    let commit: (Int) -> Void

    static let step = 5
    static let spacing: CGFloat = 7

    @State private var scrub: Double
    @State private var pointer = BarPointer()
    @State private var anchor: Double?
    @State private var width: CGFloat = 0
    @State private var settle: Task<Void, Never>?

    init(minutes: Binding<Int>, relay: ScrollRelay, commit: @escaping (Int) -> Void) {
        _minutes = minutes
        self.relay = relay
        self.commit = commit
        _scrub = State(initialValue: Double(minutes.wrappedValue))
    }

    var body: some View {
        RulerMarks(scrub: scrub, pointer: pointer)
            .background { RulerLine(scrub: scrub) }
            .overlay { Needle() }
            .frame(height: 58)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if anchor == nil {
                            anchor = scrub
                            pointer.held = true
                        }
                        scrub = clamp((anchor ?? scrub) - Double(value.translation.width / Self.spacing) * Double(Self.step))
                        minutes = snapped(scrub)
                    }
                    .onEnded { value in
                        anchor = nil
                        pointer.held = false
                        let tapped = abs(value.translation.width) < 2
                        withAnimation(.snappy(duration: 0.3, extraBounce: 0.12)) {
                            if tapped {
                                scrub = clamp(scrub + Double((value.location.x - width / 2) / Self.spacing) * Double(Self.step))
                            }
                            scrub = Double(snapped(scrub))
                        }
                        minutes = snapped(scrub)
                        commit(minutes)
                    }
            )
            .onAppear { relay.handler = self.scrolled }
    }

    private func scrolled(_ event: NSEvent) -> Bool {
        guard pointer.inside else { return false }
        let horizontal = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
        let raw = horizontal ? -event.scrollingDeltaX : event.scrollingDeltaY
        scrub = clamp(scrub + Double(raw / Self.spacing) * Double(Self.step))
        minutes = snapped(scrub)
        settle?.cancel()
        settle = Task {
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.28)) { scrub = Double(snapped(scrub)) }
            commit(snapped(scrub))
        }
        return true
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), Double(Pref.maxTimerMinutes))
    }

    private func snapped(_ value: Double) -> Int {
        Int(clamp((value / Double(Self.step)).rounded() * Double(Self.step)))
    }
}

private struct Needle: View {
    var body: some View {
        Canvas(opaque: false) { context, size in
            let needle = CGRect(x: size.width / 2 - 1.25, y: 7, width: 2.5, height: size.height - 13 + 5 - 7)
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: .white.opacity(0.4), radius: 4.5))
                layer.fill(Path(roundedRect: needle, cornerRadius: 1.25), with: .color(.white))
            }
        }
        .allowsHitTesting(false)
    }
}

private struct RulerMarks: View, Animatable {
    var scrub: Double
    let pointer: BarPointer

    var animatableData: Double {
        get { scrub }
        set { scrub = newValue }
    }

    var body: some View {
        let scrub = scrub
        BarTicks(pointer: pointer) { size, hoverX, lift in
            RulerScale.ticks(scrub: scrub, size: size, hoverX: hoverX, lift: lift)
        }
    }
}

private struct RulerLine: View, Animatable {
    var scrub: Double

    var animatableData: Double {
        get { scrub }
        set { scrub = newValue }
    }

    var body: some View {
        Canvas(opaque: false) { context, size in
            let mid = size.width / 2, baseline = size.height - RulerScale.baseInset
            let xOf = { (value: Int) in mid + CGFloat((Double(value) - scrub) / Double(TimerRuler.step)) * TimerRuler.spacing }
            let lineStart = max(14, xOf(0))
            let lineEnd = min(size.width - 14, xOf(Pref.maxTimerMinutes))
            guard lineEnd > lineStart else { return }
            let line = Gradient(stops: [.init(color: .white.opacity(0), location: 0),
                                        .init(color: .white.opacity(0.12), location: RulerScale.endFade),
                                        .init(color: .white.opacity(0.12), location: 1 - RulerScale.endFade),
                                        .init(color: .white.opacity(0), location: 1)])
            context.fill(Path(CGRect(x: lineStart, y: baseline - 0.5, width: lineEnd - lineStart, height: 1)),
                         with: .linearGradient(line, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
        }
        .allowsHitTesting(false)
    }
}

private enum RulerScale {
    static let liftRadius: CGFloat = 46
    static let liftHeight: CGFloat = 18
    static let dip: CGFloat = 0.58
    static let edgeFade: CGFloat = 28
    static let endFade: CGFloat = 0.10
    static let baseInset: CGFloat = 13

    private static func wave(_ distance: CGFloat) -> CGFloat {
        let u = distance / liftRadius
        guard u < 1.5 else { return 0 }
        let value = cos(.pi * u) * (1 - u / 1.5)
        return value < 0 ? value * dip : value
    }

    static func ticks(scrub: Double, size: CGSize, hoverX: CGFloat, lift: Double) -> [BarTick] {
        let step = Double(TimerRuler.step)
        let spacing = TimerRuler.spacing
        let mid = size.width / 2
        let baseline = size.height - baseInset
        var out: [BarTick] = []
        let reach = Int(size.width / spacing / 2) + 3
        let centerTick = Int((scrub / step).rounded())
        out.reserveCapacity(2 * reach + 1)
        for index in (centerTick - reach)...(centerTick + reach) {
            let value = index * TimerRuler.step
            guard (0...Pref.maxTimerMinutes).contains(value) else { continue }
            let x = mid + CGFloat((Double(value) - scrub) / step) * spacing
            guard x > -spacing, x < size.width + spacing, abs(x - mid) > 3.6 else { continue }

            let isHour = value % 60 == 0
            let isHalf = value % 30 == 0
            var height: CGFloat = isHour ? 21 : (isHalf ? 15 : 9)
            var alpha: Double = isHour ? 0.92 : (isHalf ? 0.64 : 0.42)

            if lift > 0 {
                let swell = wave(abs(x - hoverX)) * CGFloat(lift)
                height = max(5, height + liftHeight * swell)
                alpha = min(1, max(0.06, alpha * (1 + (swell > 0 ? 1.15 : 0.6) * Double(swell))))
            }

            let fromEnd = min(x, size.width - x)
            if fromEnd < edgeFade {
                let t = max(0, fromEnd / edgeFade)
                alpha *= Double(t * t * (3 - 2 * t))
            }
            alpha *= Double(min(1, max(0, fromEnd / (size.width * endFade))))

            out.append(BarTick(rect: CGRect(x: x - 1, y: baseline - height, width: 2, height: height), opacity: alpha))
        }
        return out
    }
}

struct PanelView: View {
    @ObservedObject var model: Sleepness
    let relay: ScrollRelay
    @State private var picked: Int

    init(model: Sleepness, relay: ScrollRelay) {
        self.model = model
        self.relay = relay
        _picked = State(initialValue: model.timerMinutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center) {
                    Text("Stay awake")
                        .font(.system(size: Bar.title, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    BarSwitch(isOn: Binding(get: { model.isOn }, set: { model.setOn($0) }), disabled: model.switching)
                }
                if let note = model.note {
                    Text(note)
                        .font(.system(size: Bar.small))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            BarLine().padding(.horizontal, -Bar.padding)

            VStack(alignment: .leading, spacing: 0) {
                TimerRuler(minutes: $picked, relay: relay) { model.setTimer($0) }
                    .padding(.horizontal, -Bar.padding)
                Text(picked == 0 ? "Off" : String(format: "%d:%02d", picked / 60, picked % 60))
                    .font(.system(size: 25, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.18), value: picked)
                    .frame(maxWidth: .infinity, alignment: .center)
                if let deadline = model.deadline {
                    countdown(deadline)
                        .padding(.top, 10)
                        .transition(.opacity)
                }
            }

            BarLine().padding(.horizontal, -Bar.padding)

            HStack(alignment: .center) {
                Text("Launch at login")
                    .frame(maxWidth: .infinity, alignment: .leading)
                BarSwitch(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }
        }
        .font(.system(size: Bar.text))
        .foregroundStyle(Bar.t1)
        .padding(Bar.padding)
        .animation(.smooth(duration: 0.32), value: model.deadline == nil)
        .animation(.smooth(duration: 0.32), value: model.note)
    }

    private func countdown(_ deadline: Date) -> some View {
        let total = max(Double(model.timerMinutes) * 60, 1)
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, deadline.timeIntervalSince(context.date))
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(LinearGradient(colors: [Color.white.opacity(0.45), Color.white.opacity(0.9)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * min(1, left / total))
                            .animation(.linear(duration: 1), value: left)
                    }
                }
                .frame(height: 5)
                HStack(spacing: 5) {
                    Image(systemName: "moon.zzz.fill").imageScale(.small)
                    Text("\(Sleepness.clock(deadline)), in")
                    Text(remaining(left)).monospacedDigit().foregroundStyle(.primary)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func remaining(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

enum CLI {
    static func handle(_ args: [String]) -> Int32? {
        guard args.count >= 2, args[1] == "--restore" else { return nil }
        restore(screen: args.count >= 3 ? Float(args[2]) : nil,
                keyboard: args.count >= 4 ? Float(args[3]) : nil)
        return 0
    }

    private static func restore(screen: Float?, keyboard: Float?) {
        guard screen != nil || keyboard != nil else { return }
        let giveUp = Date().addingTimeInterval(12 * 3600)
        while LidMonitor.isClosed(), Date() < giveUp { Thread.sleep(forTimeInterval: 5) }
        Thread.sleep(forTimeInterval: 1)
        let defaults = UserDefaults.standard
        if let level = screen {
            for _ in 0..<8 {
                DisplayBrightness.set(level)
                if let now = DisplayBrightness.get(), abs(now - level) <= 0.02 {
                    defaults.removeObject(forKey: Pref.savedScreen)
                    break
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        if let level = keyboard {
            KeyboardBacklight.set(level)
            if let now = KeyboardBacklight.get(), abs(now - level) <= 0.05 {
                defaults.removeObject(forKey: Pref.savedKeyboard)
            }
        }
    }
}

if let code = CLI.handle(CommandLine.arguments) { exit(code) }
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
