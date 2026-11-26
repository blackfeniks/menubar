import AppKit
import SwiftUI

enum AlertVolume {
    @MainActor private static var cached: Int?
    @MainActor static var value: Int { cached ?? 50 }

    @MainActor static func refresh() {
        DispatchQueue.global(qos: .utility).async {
            guard let v = read() else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { cached = v } }
        }
    }

    private nonisolated static func read() -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "alert volume of (get volume settings)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.flatMap(Int.init)
    }

    @MainActor static func set(_ value: Int) {
        let v = min(max(value, 0), 100)
        cached = v
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "set volume alert volume \(v)"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }
}

private final class AlertVolumeView: NSView {
    private let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private var pending: DispatchWorkItem?

    init(value: Int) {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 52))
        let label = NSTextField(labelWithString: "Alert volume")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 14, y: 30, width: 200, height: 16)
        let low = NSImageView(image: NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: nil)!)
        low.contentTintColor = .secondaryLabelColor
        low.frame = NSRect(x: 14, y: 7, width: 14, height: 16)
        let high = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)!)
        high.contentTintColor = .secondaryLabelColor
        high.frame = NSRect(x: 206, y: 7, width: 22, height: 16)
        slider.frame = NSRect(x: 34, y: 5, width: 166, height: 20)
        slider.doubleValue = Double(value)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        [label, low, high, slider].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        let value = Int(slider.doubleValue.rounded())
        pending?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { AlertVolume.set(value) } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private lazy var engine = Engine(settings: settings)
    private lazy var model = Model(engine: engine)
    private var statusItem: NSStatusItem?
    private var panel: BarPanel?
    private var sigterm: DispatchSourceSignal?
    private var left = false
    private var noNap: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                Log.line("SIGTERM")
                self?.leave()
            }
        }
        source.resume()
        sigterm = source

        let item = NSStatusBar.system.statusItem(withLength: 26)
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Tune")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        image?.isTemplate = true
        item.button?.image = image
        item.button?.target = self
        item.button?.action = #selector(iconClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = "Tune"
        statusItem = item
        panel = BarPanel(statusItem: item)

        noNap = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Tune follows app audio")
        Log.line("Tune \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "") started")
        model.start()
        AlertVolume.refresh()
        if CapturePermission.state == .unknown { engine.requestPermission() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !left {
            left = true
            engine.shutdown()
        }
        return .terminateNow
    }

    @objc private func iconClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            panel?.toggle { [model] in
                model.panelOpened()
                let state = PanelState()
                var content = BarContent(width: PanelMetrics.width, spare: PanelMetrics.spare) {
                    PanelPages(model: model, state: state)
                }
                content.onCancel = {
                    guard state.page != .main else { return false }
                    state.page = .main
                    return true
                }
                return content
            }
        }
    }

    private func showMenu() {
        panel?.close(animated: false)
        let menu = NSMenu()
        let volume = NSMenuItem()
        volume.view = AlertVolumeView(value: AlertVolume.value)
        menu.addItem(volume)
        menu.addItem(.separator())
        if MicDriver.installed {
            let remove = NSMenuItem(title: "Remove Tune Mic…", action: #selector(removeMic), keyEquivalent: "")
            remove.target = self
            menu.addItem(remove)
        }
        let log = NSMenuItem(title: "Open log", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)
        let quit = NSMenuItem(title: "Quit Tune", action: #selector(quitTune), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
        AlertVolume.refresh()
    }

    @objc private func openLog() { NSWorkspace.shared.open(Log.url) }
    @objc private func removeMic() { model.removeMicDriver() }
    @objc private func quitTune() { leave() }

    private func leave() {
        guard !left else { return }
        left = true
        panel?.close(animated: false)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        engine.shutdown()
        Log.line("Tune quit")
        NSApp.terminate(nil)
    }
}
