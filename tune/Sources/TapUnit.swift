import AudioToolbox
import CoreAudio
import Foundation

@MainActor
final class TapUnit {
    let key: String
    private(set) var processIDs: [AudioObjectID]
    private(set) var dsp = DSPUnit()
    private var gain: Float = 1
    private var eq: [Float]? = nil

    private struct Tap {
        let id: AudioObjectID
        let description: CATapDescription
        var listeners: [Listener]
    }
    private var tap: Tap?

    private struct Path {
        let aggregate: AudioObjectID
        let proc: IOProc
        let dsp: DSPUnit
        let device: AudioObjectID
        var listeners: [Listener]
    }
    private var path: Path?
    private(set) var running = false
    private var retired: [DSPUnit] = []

    var onBroken: ((String) -> Void)?
    private(set) var overloads = 0
    var lastCallbacks: UInt64 = 0
    var stalls = 0

    var muteBehavior: CATapMuteBehavior = .mutedWhenTapped
    nonisolated(unsafe) static var driftOverride: Bool?
    private(set) var startedAt = Date.distantPast

    var hasTap: Bool { tap != nil }
    var isAttached: Bool { path != nil }
    var deviceID: AudioObjectID { path?.device ?? noObject }

    init(key: String, processIDs: [AudioObjectID]) {
        self.key = key
        self.processIDs = processIDs
    }

    func createTap() -> Bool {
        guard let t = makeTap() else { return false }
        tap = t
        return true
    }

    private func makeTap() -> Tap? {
        let description = CATapDescription(stereoMixdownOfProcesses: processIDs)
        description.uuid = UUID()
        description.name = "Tune \(key)"
        description.isPrivate = true
        description.muteBehavior = muteBehavior
        var id = noObject
        let err = AudioHardwareCreateProcessTap(description, &id)
        guard err == noErr, id != noObject else {
            Log.line("\(key): tap failed (\(err))")
            return nil
        }
        let listeners = [
            Listener(id, address(kAudioTapPropertyFormat)) { [weak self] in
                guard let self, self.tap?.id == id else { return }
                self.onBroken?("tap format")
            },
        ].compactMap { $0 }
        return Tap(id: id, description: description, listeners: listeners)
    }

    private func destroyTap(_ t: Tap) {
        t.listeners.forEach { $0.cancel() }
        AudioHardwareDestroyProcessTap(t.id)
    }

    func updateProcesses(_ ids: [AudioObjectID]) -> Bool {
        guard ids != processIDs else { return true }
        guard let tap else { return false }
        let description = tap.description
        description.processes = ids
        var a = address(kAudioTapPropertyDescription)
        var ref = description
        let err = withUnsafeMutablePointer(to: &ref) {
            AudioObjectSetPropertyData(tap.id, &a, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        if err != noErr {
            description.processes = processIDs
            Log.line("\(key): could not update the tap's processes (\(err))")
            return false
        }
        processIDs = ids
        return true
    }

    func attach(to device: AudioDevice) -> Bool {
        guard let current = tap else { return false }
        if running, let old = path {
            if handOver(from: old, oldTap: current, to: device) { return true }
            teardown(old, stop: true)
            path = nil
            running = false
            Log.line("\(key): handed over with a gap")
            guard let restarted = build(on: device, tap: current) else { return false }
            guard restarted.proc.start(restarted.aggregate) == noErr else {
                teardown(restarted, stop: false)
                Log.line("\(key): start on \(device.name) failed")
                return false
            }
            path = restarted
            running = true
            startedAt = Date()
            stalls = 0
            lastCallbacks = dsp.callbacks
            return true
        }
        if let old = path { teardown(old, stop: false) }
        path = nil
        guard let new = build(on: device, tap: current) else { return false }
        path = new
        return true
    }

    private func build(on device: AudioDevice, tap t: Tap) -> Path? {
        dsp.set(gain: gain, eq: eq)
        return makePath(on: device, tap: t.description.uuid, dsp: dsp)
    }

    private func handOver(from old: Path, oldTap: Tap, to device: AudioDevice) -> Bool {
        guard let newTap = makeTap() else { return false }
        let fresh = DSPUnit()
        fresh.set(gain: gain, eq: eq)
        guard let new = makePath(on: device, tap: newTap.description.uuid, dsp: fresh) else {
            destroyTap(newTap)
            return false
        }
        fresh.fadeIn()
        guard new.proc.start(new.aggregate) == noErr else {
            teardown(new, stop: false)
            destroyTap(newTap)
            return false
        }
        old.dsp.silence()
        usleep(20_000)
        teardown(old, stop: true)
        destroyTap(oldTap)
        tap = newTap
        path = new
        dsp = fresh
        startedAt = Date()
        stalls = 0
        lastCallbacks = 0
        return true
    }

    private func makePath(on device: AudioDevice, tap uuid: UUID, dsp: DSPUnit) -> Path? {
        let drift = Self.driftOverride ?? false
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tune \(key)",
            kAudioAggregateDeviceUIDKey: "Tune-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceClockDeviceKey: device.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid, kAudioSubDeviceDriftCompensationKey: false]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uuid.uuidString, kAudioSubTapDriftCompensationKey: drift]],
        ]
        var aggregate = noObject
        let err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard err == noErr, aggregate != noObject else {
            Log.line("\(key): aggregate on \(device.name) failed (\(err))")
            return nil
        }
        var waited = 0
        while (CA.get(aggregate, address(kAudioDevicePropertyDeviceIsAlive), as: UInt32(0)) ?? 0) == 0, waited < 300 {
            usleep(5_000)
            waited += 5
        }
        let rate = CA.get(aggregate, address(kAudioDevicePropertyNominalSampleRate), as: Float64(0)) ?? 0
        let streams = CA.streamChannels(aggregate, scope: kAudioObjectPropertyScopeOutput)
        guard rate > 0, !streams.isEmpty else {
            Log.line("\(key): aggregate on \(device.name) has no usable output (rate \(rate), streams \(streams))")
            AudioHardwareDestroyAggregateDevice(aggregate)
            return nil
        }
        let pair = Self.stereoPair(device: device.id, streams: streams)
        dsp.configure(sampleRate: rate, outStream: pair.leftStream, left: pair.left, right: pair.right, rightStream: pair.rightStream)
        let (created, procErr) = IOProc.create(on: aggregate, tuneIOProc, UnsafeMutableRawPointer(dsp.state))
        guard let proc = created else {
            Log.line("\(key): IOProc failed (\(procErr))")
            AudioHardwareDestroyAggregateDevice(aggregate)
            return nil
        }
        Self.disableHardwareInputs(aggregate, proc, key: key)
        let listeners = [
            Listener(aggregate, address(kAudioDevicePropertyNominalSampleRate)) { [weak self] in self?.broken(aggregate, "sample rate") },
            Listener(aggregate, address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)) { [weak self] in self?.broken(aggregate, "streams") },
            Listener(aggregate, address(kAudioDevicePropertyDeviceIsAlive)) { [weak self] in self?.broken(aggregate, "device gone") },
            Listener(aggregate, address(kAudioDeviceProcessorOverload)) { [weak self] in self?.overloads += 1 },
        ].compactMap { $0 }
        Log.line("\(key): on \(device.name) at \(Int(rate)) Hz, streams \(streams), stereo \(pair), drift \(drift)")
        return Path(aggregate: aggregate, proc: proc, dsp: dsp, device: device.id, listeners: listeners)
    }

    private func broken(_ aggregate: AudioObjectID, _ reason: String) {
        guard path?.aggregate == aggregate else { return }
        onBroken?(reason)
    }

    private func teardown(_ p: Path, stop: Bool) {
        p.listeners.forEach { $0.cancel() }
        if stop { p.proc.stop(p.aggregate) }
        p.proc.destroy(p.aggregate)
        AudioHardwareDestroyAggregateDevice(p.aggregate)
    }

    static func stereoPair(device: AudioObjectID, streams: [Int]) -> (leftStream: Int, left: Int, rightStream: Int, right: Int) {
        var pair: [UInt32] = [1, 2]
        var a = address(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput)
        var size = UInt32(8)
        _ = AudioObjectGetPropertyData(device, &a, 0, nil, &size, &pair)
        func locate(_ channel: Int) -> (Int, Int)? {
            var first = 1
            for (i, count) in streams.enumerated() {
                if channel >= first && channel < first + count { return (i, channel - first) }
                first += count
            }
            return nil
        }
        let firstStream = streams.firstIndex { $0 > 0 } ?? 0
        guard let l = locate(Int(pair[0])) else {
            let n = streams[firstStream]
            return (firstStream, 0, firstStream, max(0, min(1, n - 1)))
        }
        if let r = locate(Int(pair[1])) { return (l.0, l.1, r.0, r.1) }
        return (l.0, l.1, l.0, max(0, min(l.1 + 1, streams[l.0] - 1)))
    }

    static func disableHardwareInputs(_ aggregate: AudioObjectID, _ proc: IOProc, key: String) {
        let count = CA.streamChannels(aggregate, scope: kAudioObjectPropertyScopeInput).count
        guard count > 1 else { return }
        let header = MemoryLayout<UnsafeMutableRawPointer>.size + MemoryLayout<UInt32>.size
        let total = header + count * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: total, alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment)
        defer { raw.deallocate() }
        raw.storeBytes(of: proc.bits, as: UInt.self)
        raw.storeBytes(of: UInt32(count), toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
        for i in 0..<count {
            raw.storeBytes(of: UInt32(i == count - 1 ? 1 : 0), toByteOffset: header + i * 4, as: UInt32.self)
        }
        var a = address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        let err = AudioObjectSetPropertyData(aggregate, &a, 0, nil, UInt32(total), raw)
        if err != noErr { Log.line("\(key): could not switch off \(count - 1) hardware input(s) (\(err))") }
    }

    @discardableResult
    func start() -> Bool {
        guard !running, let path else { return running }
        let err = path.proc.start(path.aggregate)
        if err != noErr { Log.line("\(key): start failed (\(err))"); return false }
        Log.line("\(key): playing through Tune")
        running = true
        startedAt = Date()
        stalls = 0
        lastCallbacks = dsp.callbacks
        return true
    }

    func stop() {
        guard running, let path else { running = false; return }
        path.proc.stop(path.aggregate)
        Log.line("\(key): stopped (heard \(dsp.heard) loud buffers in \(dsp.callbacks) callbacks)")
        running = false
    }

    func set(gain: Float, eq: [Float]?) {
        self.gain = gain
        self.eq = eq
        dsp.set(gain: gain, eq: eq)
    }

    func detach() {
        if let path { teardown(path, stop: running) }
        path = nil
        running = false
    }

    func destroy() {
        detach()
        if let tap { destroyTap(tap) }
        tap = nil
    }

    func forget() {
        if let path { retired.append(path.dsp) }
        path = nil
        tap = nil
        running = false
    }
}
