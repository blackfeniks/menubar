import AudioToolbox
import CoreAudio
import Foundation

private final class Burner: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    func stop() { lock.lock(); running = false; lock.unlock() }
}

@MainActor
enum LoadTest {
    struct Verdict { var clicks = 0; var dropouts = 0; var blocks = 0; var worstCents = 0.0 }

    static func run(_ args: [String]) -> Int32 {
        Log.toStdout = true
        guard CapturePermission.state == .granted else { print("No capture permission"); return 2 }
        let value = { (flag: String) in args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if let d = value("--drift") { TapUnit.driftOverride = d == "on" }
        let threads = value("--threads").flatMap(Int.init) ?? ProcessInfo.processInfo.activeProcessorCount * 2
        let stall = value("--stall").flatMap(UInt32.init) ?? 0
        let loadSeconds = value("--load").flatMap(Double.init) ?? 14
        if !args.contains("--no-session") { TuneSession.apply() }

        let devices = DeviceMonitor()
        devices.refresh()
        guard let output = devices.outputs.first(where: { $0.id == devices.defaultOutput }) else { print("No output"); return 2 }
        if stall > 0 { print("Stalls: \(stall) ms every 2 s during the load") }
        print("Output: \(output.name)  drift: \(TapUnit.driftOverride.map { $0 ? "on" : "off" } ?? "default")  load: \(threads) threads × \(Int(loadSeconds)) s")

        let hz = 997.0
        let tone = FileManager.default.temporaryDirectory.appendingPathComponent("tune-load-tone.wav")
        let total = 8 + loadSeconds + 6
        guard LiveTest.writeTone(tone, hz: hz, dBFS: -30, seconds: total + 6) else { return 2 }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [tone.path]
        try? player.run()
        defer { if player.isRunning { player.terminate() }; try? FileManager.default.removeItem(at: tone) }
        var toneProcess = noObject
        for _ in 0..<60 where toneProcess == noObject {
            for id in CA.ids(systemObject, address(kAudioHardwarePropertyProcessObjectList))
            where CA.get(id, address(kAudioProcessPropertyPID), as: pid_t(0)) == player.processIdentifier
                && (CA.get(id, address(kAudioProcessPropertyIsRunningOutput), as: UInt32(0)) ?? 0) != 0 { toneProcess = id }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        guard toneProcess != noObject else { print("afplay never played"); return 2 }

        let seconds = Int(total) + 4
        guard let original = Monitor(name: "original", description: CATapDescription(stereoMixdownOfProcesses: [toneProcess]), device: output, seconds: seconds) else { return 2 }
        defer { original.stop() }
        let unit = TapUnit(key: "load-test", processIDs: [toneProcess])
        guard unit.createTap(), unit.attach(to: output) else { print("No path"); return 1 }
        defer { unit.destroy() }
        unit.set(gain: 0.9, eq: [0, 0, 0, 0, 1.5, -1, 0, 0, 0, 0])
        unit.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        var selfProcess = noObject
        for id in CA.ids(systemObject, address(kAudioHardwarePropertyProcessObjectList))
        where CA.get(id, address(kAudioProcessPropertyPID), as: pid_t(0)) == getpid() { selfProcess = id }
        guard selfProcess != noObject, let tuneOut = Monitor(name: "Tune", description: CATapDescription(stereoMixdownOfProcesses: [selfProcess]), device: output, seconds: seconds) else { return 2 }
        defer { tuneOut.stop() }
        if let agg = CA.ids(systemObject, address(kAudioHardwarePropertyDevices)).first(where: { (CA.string($0, address(kAudioDevicePropertyDeviceUID)) ?? "").hasPrefix("Tune-") }),
           let frames = CA.get(agg, address(kAudioDevicePropertyBufferFrameSize), as: UInt32(0)) {
            print("IO buffer: \(frames) frames")
        }

        func mark() -> (UInt64, UInt64) { (original.state.pointee.written, tuneOut.state.pointee.written) }
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let m0 = mark()
        RunLoop.main.run(until: Date().addingTimeInterval(6))
        let m1 = mark()
        let burner = Burner()
        for _ in 0..<threads {
            let t = Thread {
                var x = 1.0001
                while burner.isRunning { for _ in 0..<20000 { x = x * 1.0000001 + sin(x) * 1e-9 } }
                if x == 42 { print(x) }
            }
            t.qualityOfService = .userInteractive
            t.start()
        }
        let callbacks0 = unit.dsp.callbacks
        let loadEnd = Date().addingTimeInterval(loadSeconds)
        while Date() < loadEnd {
            if stall > 0 { unit.dsp.state.pointee.testStall = stall * 1000 }
            RunLoop.main.run(until: min(loadEnd, Date().addingTimeInterval(2)))
        }
        burner.stop()
        let m2 = mark()
        let duringLoad = unit.dsp.callbacks - callbacks0
        RunLoop.main.run(until: Date().addingTimeInterval(5))
        let m3 = mark()

        print("Callbacks under load: \(duringLoad) in \(Int(loadSeconds)) s; overloads seen by the path: \(unit.overloads)")
        print("             clicks  dropouts(10ms)  worst pitch (cents)")
        for (name, mon, idx) in [("original", original, 0), ("Tune", tuneOut, 1)] {
            for (phase, a, b) in [("before", m0, m1), ("load", m1, m2), ("after", m2, m3)] {
                let from = idx == 0 ? a.0 : a.1, to = idx == 0 ? b.0 : b.1
                let v = analyse(mon, from: from, to: to, hz: hz)
                print(String(format: "%@ %@  %5d  %8d / %-6d  %6.1f", name.padding(toLength: 8, withPad: " ", startingAt: 0),
                             phase.padding(toLength: 6, withPad: " ", startingAt: 0), v.clicks, v.dropouts, v.blocks, v.worstCents))
            }
        }
        return 0
    }

    static func analyse(_ m: Monitor, from: UInt64, to: UInt64, hz: Double) -> Verdict {
        let st = m.state.pointee
        let rate = m.sampleRate
        guard to > from + 4800 else { return Verdict() }
        var x = [Float](repeating: 0, count: Int(to - from))
        for i in 0..<x.count { x[i] = st.buffer[Int((from + UInt64(i)) % UInt64(st.capacity))] }
        var v = Verdict()
        let block = Int(rate / 100)
        var rms: [Float] = []
        for s in stride(from: 0, to: x.count - block, by: block) {
            var sum: Float = 0
            for i in s..<s + block { sum += x[i] * x[i] }
            rms.append((sum / Float(block)).squareRoot())
        }
        let typical = rms.sorted()[rms.count / 2]
        v.blocks = rms.count
        v.dropouts = rms.filter { $0 < typical * 0.5 }.count
        let c = Float(2 * cos(2 * Double.pi * hz / rate))
        let limit = typical * 1.4142 * 0.03
        var lastClickBlock = -1
        for n in 2..<x.count where abs(x[n] - c * x[n - 1] + x[n - 2]) > limit {
            let b = n / block
            if b != lastClickBlock { v.clicks += 1; lastClickBlock = b }
        }
        let window = Int(rate / 2)
        for s in stride(from: 0, to: x.count - window, by: window) {
            var first = -1.0, last = -1.0, count = 0
            for i in s + 1..<s + window where x[i - 1] < 0 && x[i] >= 0 {
                let t = Double(i - 1) + Double(-x[i - 1] / (x[i] - x[i - 1]))
                if first < 0 { first = t }
                last = t
                count += 1
            }
            guard count > 10, last > first else { continue }
            let f = Double(count - 1) / ((last - first) / rate)
            v.worstCents = max(v.worstCents, abs(1200 * log2(f / hz)))
        }
        return v
    }
}
