import AppKit
import CoreAudio

@MainActor
enum Probe {
    static func run() -> Int32 {
        Log.toStdout = true
        let devices = DeviceMonitor()
        devices.refresh()
        print("Capture permission: \(CapturePermission.state)\n")
        print("Outputs:")
        for d in devices.outputs {
            let mark = d.id == devices.defaultOutput ? "▸" : " "
            let vol = devices.volume(d.id).map { String(format: "%.0f%%", $0 * 100) } ?? "—"
            print("  \(mark) \(d.shortName)  [\(d.name)]  uid=\(d.uid)  ch=\(d.outputChannels)  vol=\(vol)\(devices.canSetVolume(d.id) ? "" : " (fixed)")\(d.isBluetooth ? "  bluetooth" : "")")
        }
        print("Inputs:")
        for d in devices.inputs {
            let mark = d.id == devices.defaultInput ? "▸" : " "
            let vol = devices.volume(d.id, input: true).map { String(format: "%.0f%%", $0 * 100) } ?? "—"
            print("  \(mark) \(d.shortName)  [\(d.name)]  ch=\(d.inputChannels)  vol=\(vol)")
        }
        print("Hidden from the panel:")
        for id in CA.ids(systemObject, address(kAudioHardwarePropertyDevices)) where devices.device(id) == nil {
            print("    \(CA.string(id, address(kAudioObjectPropertyName)) ?? "?")")
        }

        let processes = ProcessMonitor()
        processes.refresh()
        print("\nApps with sound:")
        let real = FileManager.default.fileExists(atPath: SettingsStore.defaultURL.path)
        let settings = real ? SettingsStore() : SettingsStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("tune-probe-\(getpid()).json"))
        defer { if !real { try? FileManager.default.removeItem(at: settings.url) } }
        for app in processes.apps.values.sorted(by: { $0.name < $1.name }) {
            let outs = processes.outputDevices(of: app.key).map { devices.name(of: $0) }
            let p = settings.prefs(app.key)
            print("  \(app.playing ? "♪" : " ") \(app.name)  (\(app.key))  processes=\(app.processIDs)  out=\(outs)  level=\(Level.percent(ofGain: p.gain))%  preset=\(settings.preset(p.presetID)?.name ?? "Off")  \(settings.needsProcessing(app.key) ? "→ would be tapped" : "")")
        }
        print("\nPresets: \(settings.data.presets.map(\.name))")
        return 0
    }
}
