import AudioToolbox
import CoreAudio
import Foundation

struct ProbeState {
    var callbacks: UInt64 = 0
    var frames: UInt64 = 0
    var loudFrames: UInt64 = 0
}

let probeIOProc: AudioDeviceIOProc = { _, _, inputData, _, outputData, _, clientData in
    let outs = RawBuffers(outputData)
    for i in 0..<outs.count { if let d = outs.data(i) { memset(d, 0, outs.bytes(i)) } }
    guard let clientData else { return noErr }
    let st = clientData.assumingMemoryBound(to: ProbeState.self)
    let ins = RawBuffers(inputData)
    let last = ins.count - 1
    guard last >= 0, let raw = ins.data(last) else { return noErr }
    let ch = max(1, ins.channels(last))
    let count = ins.bytes(last) / 4
    let x = raw.assumingMemoryBound(to: Float.self)
    var peak: Float = 0
    for i in 0..<count {
        let v = x[i]
        if v.isFinite { peak = max(peak, abs(v)) }
    }
    st.pointee.callbacks &+= 1
    st.pointee.frames &+= UInt64(count / ch)
    if peak > DSP.audible { st.pointee.loudFrames &+= UInt64(count / ch) }
    return noErr
}

@MainActor
final class AudibilityProbe {
    let key: String
    let started = Date()
    private var tap = noObject
    private var aggregate = noObject
    private var proc: IOProc?
    private let state: UnsafeMutablePointer<ProbeState>
    private(set) var sampleRate: Double = 48000
    private var leak = false

    init?(key: String, processIDs: [AudioObjectID], device: AudioDevice) {
        self.key = key
        state = .allocate(capacity: 1)
        state.initialize(to: ProbeState())
        let description = CATapDescription(stereoMixdownOfProcesses: processIDs)
        description.uuid = UUID()
        description.name = "Tune probe \(key)"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr, tap != noObject else {
            tap = noObject
            release()
            return nil
        }
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tune probe",
            kAudioAggregateDeviceUIDKey: "Tune-probe-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceClockDeviceKey: device.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid, kAudioSubDeviceDriftCompensationKey: false]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: false]],
        ]
        guard AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggregate) == noErr, aggregate != noObject else {
            aggregate = noObject
            release()
            return nil
        }
        var waited = 0
        while (CA.get(aggregate, address(kAudioDevicePropertyDeviceIsAlive), as: UInt32(0)) ?? 0) == 0, waited < 300 {
            usleep(5_000)
            waited += 5
        }
        sampleRate = CA.get(aggregate, address(kAudioDevicePropertyNominalSampleRate), as: Float64(0)) ?? 48000
        guard sampleRate > 0, let p = IOProc.create(on: aggregate, probeIOProc, UnsafeMutableRawPointer(state)).0 else {
            release()
            return nil
        }
        proc = p
        TapUnit.disableHardwareInputs(aggregate, p, key: key)
        guard p.start(aggregate) == noErr else {
            release()
            return nil
        }
    }

    var loudSeconds: Double { Double(state.pointee.loudFrames) / sampleRate }
    var heardSeconds: Double { Double(state.pointee.frames) / sampleRate }

    func stop() { release() }

    func forget() {
        leak = true
        proc = nil
        aggregate = noObject
        tap = noObject
    }

    private func release() {
        if let proc, aggregate != noObject {
            proc.stop(aggregate)
            proc.destroy(aggregate)
        }
        proc = nil
        if aggregate != noObject { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = noObject
        if tap != noObject { AudioHardwareDestroyProcessTap(tap) }
        tap = noObject
    }

    deinit {
        if !leak { state.deallocate() }
    }
}
