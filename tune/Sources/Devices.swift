import AudioToolbox
import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32
    let outputChannels: Int
    let inputChannels: Int

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

    var shortName: String {
        if isBuiltIn, name.hasPrefix("MacBook") { return "MacBook" }
        if isBuiltIn, name.hasPrefix("Mac") { return name.components(separatedBy: " ").first ?? name }
        for suffix in [" Speakers", " Speaker", " Microphone", " Audio"] where name.hasSuffix(suffix) && name.count > suffix.count + 2 {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    var sortRank: Int {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return 0
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire: return 1
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return 2
        default: return 3
        }
    }
}

enum DeviceFilter {
    static func isShown(transport: UInt32, hidden: Bool, uid: String) -> Bool {
        if hidden || uid.hasPrefix("Tune-") { return false }
        return transport != kAudioDeviceTransportTypeVirtual
            && transport != kAudioDeviceTransportTypeAggregate
            && transport != kAudioDeviceTransportTypeAutoAggregate
    }
}

@MainActor
final class DeviceMonitor {
    private(set) var outputs: [AudioDevice] = []
    private(set) var inputs: [AudioDevice] = []
    private(set) var defaultOutput: AudioObjectID = noObject
    private(set) var defaultInput: AudioObjectID = noObject

    var onChange: (() -> Void)?
    var onVolume: (() -> Void)?
    var onOutputFormat: (() -> Void)?

    private var listeners: [Listener] = []
    private var watched: [Listener] = []

    func start() {
        listeners = [
            Listener(systemObject, address(kAudioHardwarePropertyDevices)) { [weak self] in self?.refresh() },
            Listener(systemObject, address(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in self?.refresh() },
            Listener(systemObject, address(kAudioHardwarePropertyDefaultInputDevice)) { [weak self] in self?.refresh() },
        ].compactMap { $0 }
        refresh()
    }

    func stop() {
        listeners.forEach { $0.cancel() }
        watched.forEach { $0.cancel() }
        listeners = []
        watched = []
    }

    func refresh() {
        var outs: [AudioDevice] = [], ins: [AudioDevice] = []
        for id in CA.ids(systemObject, address(kAudioHardwarePropertyDevices)) {
            guard let uid = CA.string(id, address(kAudioDevicePropertyDeviceUID)) else { continue }
            let transport = CA.get(id, address(kAudioDevicePropertyTransportType), as: UInt32(0)) ?? 0
            let hidden = (CA.get(id, address(kAudioDevicePropertyIsHidden), as: UInt32(0)) ?? 0) != 0
            guard DeviceFilter.isShown(transport: transport, hidden: hidden, uid: uid) else { continue }
            let device = AudioDevice(
                id: id, uid: uid,
                name: CA.string(id, address(kAudioObjectPropertyName)) ?? uid,
                transport: transport,
                outputChannels: CA.streamChannels(id, scope: kAudioObjectPropertyScopeOutput).reduce(0, +),
                inputChannels: CA.streamChannels(id, scope: kAudioObjectPropertyScopeInput).reduce(0, +))
            if device.outputChannels > 0 { outs.append(device) }
            if device.inputChannels > 0 { ins.append(device) }
        }
        let order: (AudioDevice, AudioDevice) -> Bool = {
            $0.sortRank != $1.sortRank ? $0.sortRank < $1.sortRank : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let newOutputs = outs.sorted(by: order), newInputs = ins.sorted(by: order)
        let newOut = CA.get(systemObject, address(kAudioHardwarePropertyDefaultOutputDevice), as: noObject) ?? noObject
        let newIn = CA.get(systemObject, address(kAudioHardwarePropertyDefaultInputDevice), as: noObject) ?? noObject
        guard newOutputs != outputs || newInputs != inputs || newOut != defaultOutput || newIn != defaultInput || watched.isEmpty else { return }
        let defaultsMoved = newOut != defaultOutput || newIn != defaultInput || watched.isEmpty
        outputs = newOutputs
        inputs = newInputs
        if newOut != defaultOutput { Log.line("Default output: \(name(of: newOut))") }
        defaultOutput = newOut
        defaultInput = newIn
        if defaultsMoved { rewatch() }
        onChange?()
    }

    private func rewatch() {
        watched.forEach { $0.cancel() }
        var list: [Listener?] = []
        let out = defaultOutput, inp = defaultInput
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            list.append(Listener(out, address(selector, kAudioObjectPropertyScopeOutput)) { [weak self] in self?.onVolume?() })
        }
        list.append(Listener(inp, address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeInput)) { [weak self] in self?.onVolume?() })
        list.append(Listener(out, address(kAudioDevicePropertyNominalSampleRate)) { [weak self] in self?.onOutputFormat?() })
        list.append(Listener(out, address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)) { [weak self] in self?.onOutputFormat?() })
        watched = list.compactMap { $0 }
    }

    func device(_ id: AudioObjectID) -> AudioDevice? { outputs.first { $0.id == id } ?? inputs.first { $0.id == id } }

    func anyDevice(_ id: AudioObjectID) -> AudioDevice? {
        if let known = device(id) { return known }
        guard id != noObject, let uid = CA.string(id, address(kAudioDevicePropertyDeviceUID)) else { return nil }
        let out = CA.streamChannels(id, scope: kAudioObjectPropertyScopeOutput).reduce(0, +)
        guard out > 0, !uid.hasPrefix("Tune-") else { return nil }
        return AudioDevice(id: id, uid: uid, name: CA.string(id, address(kAudioObjectPropertyName)) ?? uid,
                           transport: CA.get(id, address(kAudioDevicePropertyTransportType), as: UInt32(0)) ?? 0,
                           outputChannels: out, inputChannels: CA.streamChannels(id, scope: kAudioObjectPropertyScopeInput).reduce(0, +))
    }
    func name(of id: AudioObjectID) -> String { device(id)?.name ?? CA.string(id, address(kAudioObjectPropertyName)) ?? "none" }

    func setDefaultOutput(_ id: AudioObjectID) {
        CA.set(systemObject, address(kAudioHardwarePropertyDefaultOutputDevice), id)
        CA.set(systemObject, address(kAudioHardwarePropertyDefaultSystemOutputDevice), id)
    }

    func setDefaultInput(_ id: AudioObjectID) {
        CA.set(systemObject, address(kAudioHardwarePropertyDefaultInputDevice), id)
    }

    func volume(_ id: AudioObjectID, input: Bool = false) -> Float? {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        if let v = CA.get(id, address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope), as: Float32(0)) { return v }
        return CA.get(id, address(kAudioDevicePropertyVolumeScalar, scope), as: Float32(0))
            ?? CA.get(id, address(kAudioDevicePropertyVolumeScalar, scope, 1), as: Float32(0))
    }

    func canSetVolume(_ id: AudioObjectID, input: Bool = false) -> Bool {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        return CA.settable(id, address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope))
            || CA.settable(id, address(kAudioDevicePropertyVolumeScalar, scope))
            || CA.settable(id, address(kAudioDevicePropertyVolumeScalar, scope, 1))
    }

    func setVolume(_ id: AudioObjectID, _ value: Float, input: Bool = false) {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        let v = Float32(min(max(value, 0), 1))
        let main = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope)
        if CA.settable(id, main) {
            CA.set(id, main, v)
        } else if CA.settable(id, address(kAudioDevicePropertyVolumeScalar, scope)) {
            CA.set(id, address(kAudioDevicePropertyVolumeScalar, scope), v)
        } else {
            for channel: UInt32 in [1, 2] where CA.settable(id, address(kAudioDevicePropertyVolumeScalar, scope, channel)) {
                CA.set(id, address(kAudioDevicePropertyVolumeScalar, scope, channel), v)
            }
        }
        let mute = address(kAudioDevicePropertyMute, scope)
        if v > 0, (CA.get(id, mute, as: UInt32(0)) ?? 0) != 0, CA.settable(id, mute) { CA.set(id, mute, UInt32(0)) }
    }

    func isMuted(_ id: AudioObjectID) -> Bool {
        (CA.get(id, address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput), as: UInt32(0)) ?? 0) != 0
    }
}
