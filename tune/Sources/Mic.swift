import CoreAudio
import Foundation

enum MicDriver {
    static let installedPath = "/Library/Audio/Plug-Ins/HAL/TuneMic.driver"
    static let micUID = "TuneMic_UID"

    static var installed: Bool { FileManager.default.fileExists(atPath: installedPath) }

    static func uninstall(_ done: @escaping (Bool) -> Void) {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \"rm -rf '\(installedPath)' && killall coreaudiod\" with administrator privileges"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            let ok = (try? p.run()) != nil && { p.waitUntilExit(); return p.terminationStatus == 0 }()
            DispatchQueue.main.async { done(ok) }
        }
    }

    @MainActor
    static func restoreDefaultInput(preferredUID: String?) {
        let current = CA.get(systemObject, address(kAudioHardwarePropertyDefaultInputDevice), as: noObject) ?? noObject
        guard current != noObject, CA.string(current, address(kAudioDevicePropertyDeviceUID)) == micUID else { return }
        let inputs = CA.ids(systemObject, address(kAudioHardwarePropertyDevices)).filter {
            !CA.streamChannels($0, scope: kAudioObjectPropertyScopeInput).isEmpty
                && CA.get($0, address(kAudioDevicePropertyTransportType), as: UInt32(0)) != kAudioDeviceTransportTypeVirtual
                && CA.get($0, address(kAudioDevicePropertyTransportType), as: UInt32(0)) != kAudioDeviceTransportTypeAggregate
        }
        let builtIn = inputs.first { CA.get($0, address(kAudioDevicePropertyTransportType), as: UInt32(0)) == kAudioDeviceTransportTypeBuiltIn }
        let preferred = preferredUID.flatMap { CA.translate(uid: $0) }.flatMap { inputs.contains($0) ? $0 : nil }
        guard let real = preferred ?? builtIn ?? inputs.first else { return }
        CA.set(systemObject, address(kAudioHardwarePropertyDefaultInputDevice), real)
        Log.line("Input: Tune Mic → \(CA.string(real, address(kAudioObjectPropertyName)) ?? "real mic") (the mic EQ is gone)")
    }
}
