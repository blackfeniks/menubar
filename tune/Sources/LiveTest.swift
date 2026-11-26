import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct MonitorState {
    var buffer: UnsafeMutablePointer<Float>
    var capacity: Int
    var written: UInt64 = 0
}

let monitorIOProc: AudioDeviceIOProc = { _, _, inputData, _, outputData, _, clientData in
    let outs = UnsafeMutableAudioBufferListPointer(outputData)
    for i in 0..<outs.count { if let d = outs[i].mData { memset(d, 0, Int(outs[i].mDataByteSize)) } }
    guard let clientData else { return noErr }
    let st = clientData.assumingMemoryBound(to: MonitorState.self)
    let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    guard ins.count > 0, let raw = ins[ins.count - 1].mData else { return noErr }
    let ch = max(1, Int(ins[ins.count - 1].mNumberChannels))
    let frames = Int(ins[ins.count - 1].mDataByteSize) / (4 * ch)
    let x = raw.assumingMemoryBound(to: Float.self)
    for f in 0..<frames {
        var s: Float = 0
        for c in 0..<ch { s += x[f * ch + c] }
        st.pointee.buffer[Int(st.pointee.written % UInt64(st.pointee.capacity))] = s / Float(ch)
        st.pointee.written &+= 1
    }
    return noErr
}

@MainActor
final class Monitor {
    let name: String
    private var tap = noObject, aggregate = noObject
    private var proc: IOProc?
    let state: UnsafeMutablePointer<MonitorState>
    private(set) var sampleRate: Double = 48000

    init?(name: String, description: CATapDescription, device: AudioDevice, seconds: Int = 4, drift: Bool? = nil) {
        self.name = name
        state = .allocate(capacity: 1)
        state.initialize(to: MonitorState(buffer: .allocate(capacity: 48000 * seconds), capacity: 48000 * seconds))
        state.pointee.buffer.initialize(repeating: 0, count: 48000 * seconds)
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { print("  \(name): tap failed"); return nil }
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tune-monitor", kAudioAggregateDeviceUIDKey: "Tune-mon-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: device.uid, kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: drift ?? !device.isBluetooth]],
        ]
        guard AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggregate) == noErr else { print("  \(name): aggregate failed"); return nil }
        let deadline = Date().addingTimeInterval(1.5)
        while (CA.get(aggregate, address(kAudioDevicePropertyDeviceIsAlive), as: UInt32(0)) ?? 0) == 0, Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.01, false)
        }
        sampleRate = CA.get(aggregate, address(kAudioDevicePropertyNominalSampleRate), as: Float64(0)) ?? 48000
        guard let p = IOProc.create(on: aggregate, monitorIOProc, UnsafeMutableRawPointer(state)).0, p.start(aggregate) == noErr else {
            print("  \(name): start failed"); return nil
        }
        proc = p
    }

    func stop() {
        if let proc { proc.stop(aggregate); proc.destroy(aggregate) }
        proc = nil
        if aggregate != noObject { AudioHardwareDestroyAggregateDevice(aggregate) }
        if tap != noObject { AudioHardwareDestroyProcessTap(tap) }
        aggregate = noObject
        tap = noObject
    }

    func level(_ hz: Double, seconds: Double = 0.5) -> Double {
        let n = Int(sampleRate * seconds)
        let end = state.pointee.written
        guard end > UInt64(n) else { return -200 }
        let w = 2 * Double.pi * hz / sampleRate
        let coeff = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for i in 0..<n {
            let x = Double(state.pointee.buffer[Int((end - UInt64(n) + UInt64(i)) % UInt64(state.pointee.capacity))])
            let s = x + coeff * s1 - s2
            s2 = s1
            s1 = s
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        let amplitude = 2 * sqrt(max(power, 0)) / Double(n)
        return 20 * log10(max(amplitude, 1e-10))
    }
}

@MainActor
enum LiveTest {
    private static var failures = 0
    private static func check(_ ok: Bool, _ name: String, _ detail: String) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)  — \(detail)")
    }
    private static func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    private static func f(_ v: Double) -> String { String(format: "%.1f dB", v) }

    static func run(_ args: [String]) -> Int32 {
        Log.toStdout = true
        if CapturePermission.state != .granted {
            print("Capture permission: \(CapturePermission.state). Asking…")
            var answered = false
            CapturePermission.request { _ in answered = true }
            let patience: TimeInterval = args.contains("--wait-permission") ? 8 * 3600 : 180
            let deadline = Date().addingTimeInterval(patience)
            while !answered, CapturePermission.state != .granted, Date() < deadline { wait(0.5) }
            guard CapturePermission.state == .granted else { print("No permission — the live test needs it."); return 2 }
        }
        let devices = DeviceMonitor()
        devices.refresh()
        guard let output = devices.outputs.first(where: { $0.id == devices.defaultOutput }) else { print("No output device"); return 2 }
        print("Output: \(output.name)\(output.isBluetooth ? " (Bluetooth)" : "")\n")

        let hz = 1234.5
        let toneFile = FileManager.default.temporaryDirectory.appendingPathComponent("tune-tone.wav")
        guard writeTone(toneFile, hz: hz, dBFS: -18, seconds: 45) else { print("Could not write the tone"); return 2 }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [toneFile.path]
        try? player.run()
        defer { if player.isRunning { player.terminate() }; try? FileManager.default.removeItem(at: toneFile) }

        var toneProcess = noObject
        for _ in 0..<60 {
            for id in CA.ids(systemObject, address(kAudioHardwarePropertyProcessObjectList))
            where CA.get(id, address(kAudioProcessPropertyPID), as: pid_t(0)) == player.processIdentifier
                && (CA.get(id, address(kAudioProcessPropertyIsRunningOutput), as: UInt32(0)) ?? 0) != 0 {
                toneProcess = id
            }
            if toneProcess != noObject { break }
            wait(0.1)
        }
        guard toneProcess != noObject else { print("afplay never started playing"); return 2 }

        guard let mix = Monitor(name: "system mix", description: CATapDescription(stereoGlobalTapButExcludeProcesses: []), device: output) else { return 2 }
        defer { mix.stop() }
        wait(0.8)
        let base = mix.level(hz)
        print("      tone alone, system mix: \(f(base))")
        check(base > -24 && base < -12, "the tone is heard", f(base))

        let unit = TapUnit(key: "afplay-test", processIDs: [toneProcess])
        guard unit.createTap(), unit.attach(to: output) else { print("Could not build the sound path"); return 1 }
        defer { unit.destroy() }
        unit.set(gain: 0.25, eq: nil)
        unit.start()
        wait(0.8)
        var selfProcess = noObject
        for id in CA.ids(systemObject, address(kAudioHardwarePropertyProcessObjectList))
        where CA.get(id, address(kAudioProcessPropertyPID), as: pid_t(0)) == getpid() { selfProcess = id }
        check(unit.dsp.heard > 0, "the tap hears the app", "\(unit.dsp.heard) non-silent buffers, \(unit.dsp.callbacks) callbacks")
        let own = selfProcess == noObject ? nil : Monitor(name: "Tune output", description: CATapDescription(stereoMixdownOfProcesses: [selfProcess]), device: output)
        defer { own?.stop() }
        wait(0.8)

        let input = 20 * log10(Double(max(unit.dsp.state.pointee.peak, 1e-9)))
        print("      the tap hears the tone at \(f(input)) (file: −18.0 dB)")
        check(abs(input + 18) < 0.5, "the tap hears the app at its real level", f(input))
        func measure(_ label: String, expected: Double) {
            let o = own?.level(hz) ?? -200
            print("      \(label): Tune output \(f(o)), expected \(f(expected))")
            check(abs(o - expected) < 0.6, "\(label) — Tune plays it at the right level", "\(f(o)) vs \(f(expected))")
        }

        measure("50 % (−12 dB)", expected: input - 12.04)

        unit.set(gain: 2, eq: nil)
        wait(0.8)
        measure("boost 200 % (+6 dB)", expected: input + 6.02)

        var bandAt1k = [Float](repeating: 0, count: 10)
        bandAt1k[5] = 9
        unit.set(gain: 1, eq: bandAt1k)
        wait(0.8)
        measure("EQ +9 dB at 1 kHz", expected: input + EQMath.responseDB(hz, gains: bandAt1k, sampleRate: unit.dsp.sampleRate))

        var bandAt64 = [Float](repeating: 0, count: 10)
        bandAt64[1] = 12
        unit.set(gain: 1, eq: bandAt64)
        wait(0.8)
        measure("EQ +12 dB at 64 Hz (far from the tone)", expected: input + EQMath.responseDB(hz, gains: bandAt64, sampleRate: unit.dsp.sampleRate))

        let callbacksBefore = unit.dsp.callbacks
        for i in 0..<100 {
            unit.set(gain: Float(0.1 + 1.8 * abs(sin(Double(i) * 0.37))), eq: i % 3 == 0 ? bandAt1k : nil)
            wait(0.02)
        }
        check(unit.dsp.callbacks > callbacksBefore + 100, "keeps running while the slider is dragged", "\(unit.dsp.callbacks - callbacksBefore) callbacks in 2 s")

        var rebuilt = 0
        for _ in 0..<6 {
            unit.detach()
            if unit.attach(to: output), unit.start() { rebuilt += 1 }
            wait(0.25)
        }
        unit.set(gain: 0.25, eq: nil)
        wait(0.8)
        check(rebuilt == 6, "rebuilds cleanly", "\(rebuilt)/6")
        measure("after 6 rebuilds, 50 %", expected: input - 12.04)

        var handed = 0
        for _ in 0..<6 {
            if unit.attach(to: output), unit.running { handed += 1 }
            wait(0.25)
        }
        unit.set(gain: 0.25, eq: nil)
        let heard0 = unit.dsp.heard, calls0 = unit.dsp.callbacks
        wait(0.8)
        print("      after hand-overs: \(unit.dsp.heard - heard0) loud of \(unit.dsp.callbacks - calls0) callbacks in 0.8 s")
        check(handed == 6, "hands over while playing (new path first)", "\(handed)/6")
        measure("after 6 hand-overs, 50 %", expected: input - 12.04)

        unit.set(gain: 2, eq: [-2.7, 6.3, 2.2, -1.9, -3.4, -3.1, -2.7, -0.8, 1.4, 5.6])
        let cpu0 = cpuSeconds(), t0 = Date()
        wait(8)
        let cpu = (cpuSeconds() - cpu0) / Date().timeIntervalSince(t0) * 100
        print(String(format: "      Tune's CPU while playing (EQ + boost, two listening taps running too): %.2f %%", cpu))
        check(cpu < 3, "light while playing", String(format: "%.2f %%", cpu))
        check(unit.overloads == 0, "no overloads", "\(unit.overloads)")

        unit.destroy()
        wait(1.0)
        let back = mix.level(hz)
        print("      released: system mix \(f(back))")
        check(abs(back - base) < 1.5, "the app gets its own sound back", "\(f(back)) vs \(f(base))")

        print(failures == 0 ? "\nAll live checks passed." : "\n\(failures) live check(s) failed.")
        return failures == 0 ? 0 : 1
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    static func writeTone(_ url: URL, hz: Double, dBFS: Double, seconds: Double) -> Bool {
        writeTones(url, hz: [hz], dBFS: dBFS, seconds: seconds)
    }

    static func writeTones(_ url: URL, hz: [Double], dBFS: Double, seconds: Double) -> Bool {
        let rate = 48000.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let file = try? AVAudioFile(forWriting: url, settings: format.settings),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * seconds)) else { return false }
        let n = Int(rate * seconds)
        buffer.frameLength = AVAudioFrameCount(n)
        let amplitude = pow(10, dBFS / 20)
        for c in 0..<2 {
            let p = buffer.floatChannelData![c]
            for i in 0..<n {
                let t = Double(i) / rate
                p[i] = Float(hz.reduce(0) { $0 + amplitude * sin(2 * Double.pi * $1 * t) })
            }
        }
        return (try? file.write(from: buffer)) != nil
    }

    nonisolated static func level(_ st: UnsafeMutablePointer<MonitorState>, _ hz: Double, rate: Double, seconds: Double) -> Double {
        let n = Int(rate * seconds), end = st.pointee.written
        guard end > UInt64(n) else { return -200 }
        let coeff = 2 * cos(2 * Double.pi * hz / rate)
        var s1 = 0.0, s2 = 0.0
        for i in 0..<n {
            let x = Double(st.pointee.buffer[Int((end - UInt64(n) + UInt64(i)) % UInt64(st.pointee.capacity))])
            let s = x + coeff * s1 - s2
            s2 = s1; s1 = s
        }
        return 20 * log10(max(2 * sqrt(max(s1 * s1 + s2 * s2 - coeff * s1 * s2, 0)) / Double(n), 1e-10))
    }
}

@MainActor
enum AcousticTest {
    static func run(_ args: [String]) -> Int32 {
        Log.toStdout = true
        guard CapturePermission.state == .granted else { print("No capture permission"); return 2 }
        var micAnswered = false, micOK = false
        AVCaptureDevice.requestAccess(for: .audio) { ok in micOK = ok; micAnswered = true }
        let deadline = Date().addingTimeInterval(600)
        while !micAnswered, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        guard micOK else { print("No microphone permission"); return 2 }

        let devices = DeviceMonitor()
        devices.refresh()
        guard let output = devices.outputs.first(where: { $0.id == devices.defaultOutput }),
              let mic = devices.inputs.first(where: { $0.isBuiltIn }) else { print("Need the built-in mic and an output"); return 2 }
        print("Speakers: \(output.name); listening with: \(mic.name)")

        let state = UnsafeMutablePointer<MonitorState>.allocate(capacity: 1)
        state.initialize(to: MonitorState(buffer: .allocate(capacity: 48000 * 4), capacity: 48000 * 4))
        state.pointee.buffer.initialize(repeating: 0, count: 48000 * 4)
        guard let proc = IOProc.create(on: mic.id, monitorIOProc, UnsafeMutableRawPointer(state)).0, proc.start(mic.id) == noErr else {
            print("Mic capture failed"); return 2
        }
        defer { proc.stop(mic.id); proc.destroy(mic.id) }
        let micRate = CA.get(mic.id, address(kAudioDevicePropertyNominalSampleRate), as: Float64(0)) ?? 48000

        let hz = 1234.5
        func level(_ seconds: Double = 0.4) -> Double {
            let n = Int(micRate * seconds), end = state.pointee.written
            guard end > UInt64(n) else { return -200 }
            let coeff = 2 * cos(2 * Double.pi * hz / micRate)
            var s1 = 0.0, s2 = 0.0
            for i in 0..<n {
                let x = Double(state.pointee.buffer[Int((end - UInt64(n) + UInt64(i)) % UInt64(state.pointee.capacity))])
                let s = x + coeff * s1 - s2
                s2 = s1; s1 = s
            }
            return 20 * log10(max(2 * sqrt(max(s1 * s1 + s2 * s2 - coeff * s1 * s2, 0)) / Double(n), 1e-10))
        }
        func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

        let tone = FileManager.default.temporaryDirectory.appendingPathComponent("tune-acoustic.wav")
        guard LiveTest.writeTone(tone, hz: hz, dBFS: -14, seconds: 120) else { return 2 }
        defer { try? FileManager.default.removeItem(at: tone) }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [tone.path]
        try? player.run()
        defer { if player.isRunning { player.terminate() } }
        var toneProc = noObject
        for _ in 0..<60 where toneProc == noObject {
            for id in CA.ids(systemObject, address(kAudioHardwarePropertyProcessObjectList))
            where CA.get(id, address(kAudioProcessPropertyPID), as: pid_t(0)) == player.processIdentifier
                && (CA.get(id, address(kAudioProcessPropertyIsRunningOutput), as: UInt32(0)) ?? 0) != 0 { toneProc = id }
            wait(0.1)
        }
        guard toneProc != noObject else { print("afplay never played"); return 2 }
        wait(1.5)
        let base = level(1.0)
        print(String(format: "tone alone, heard by the mic: %.1f dB", base))

        for (mute, name) in [(CATapMuteBehavior.mutedWhenTapped, "mutedWhenTapped"), (.muted, "muted")] {
            let unit = TapUnit(key: "acoustic", processIDs: [toneProc])
            unit.muteBehavior = mute
            unit.set(gain: 0.25, eq: nil)
            guard unit.createTap(), unit.attach(to: output), unit.start() else { print("[\(name)] could not build"); continue }
            var line = "[\(name)] at 50 % (expect about −12 dB):"
            for t in 0..<16 {
                wait(t == 0 ? 0.5 : 2.0)
                line += String(format: " %@%.1f", t == 0 ? "" : "| ", level() - base)
            }
            print(line)
            unit.destroy()
            wait(2)
            print(String(format: "  released: %+.1f dB", level(1.0) - base))
        }
        return 0
    }
}
