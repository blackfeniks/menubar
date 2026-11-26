import AudioToolbox
import Foundation

enum Selftest {
    private static var failures = 0
    private static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)\(ok ? "" : "  — " + detail())")
    }

    static func run(fineTuneSample: String?) -> Int32 {
        Log.toStdout = true
        levels()
        eqMaths()
        render()
        settings(fineTuneSample: fineTuneSample)
        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
        return failures == 0 ? 0 : 1
    }

    static func levels() {
        for g: Float in [0, 0.01, 0.25, 0.5932, 1, 1.6, 2, 3.98] {
            let back = Level.gain(atPosition: Level.position(ofGain: g))
            check(abs(back - g) < 0.001 * max(1, g), "level round-trip \(g)", "got \(back)")
        }
        check(abs(Level.position(ofGain: 1) - Level.mainFraction) < 1e-9, "100 % sits at the wall")
        check(Level.percent(ofGain: 1) == 100 && Level.percent(ofGain: 0.25) == 50 && Level.percent(ofGain: 1.6) == 160,
              "percent labels", "\(Level.percent(ofGain: 1)) \(Level.percent(ofGain: 0.25)) \(Level.percent(ofGain: 1.6))")
        check(abs(Level.gain(atPosition: 1) - 4) < 0.001 && Level.percent(ofGain: Level.gain(atPosition: 1)) == 400, "right end is exactly 400 %", "\(Level.gain(atPosition: 1))")
    }

    static func eqMaths() {
        for (i, f) in EQMath.frequencies.enumerated() {
            var gains = [Float](repeating: 0, count: 10)
            gains[i] = 6
            let r = EQMath.responseDB(f, gains: gains)
            check(abs(r - 6) < 0.05, "band \(EQMath.labels[i]) peaks at +6 dB", "\(r)")
        }
        check(abs(EQMath.responseDB(1000, gains: [Float](repeating: 0, count: 10))) < 1e-6, "flat is flat")
        let atNyquist = EQMath.peaking(f0: 16000, gainDB: 6, sampleRate: 32000)
        check(atNyquist == EQMath.identity, "16 kHz band is skipped on a 32 kHz call link")
    }

    private final class Lists {
        let inList: UnsafeMutablePointer<AudioBufferList>
        let outList: UnsafeMutablePointer<AudioBufferList>
        var inputs: [UnsafeMutablePointer<Float>] = []
        var outputs: [UnsafeMutablePointer<Float>] = []
        let frames: Int
        let inChannels: [Int], outChannels: [Int]

        init(frames: Int, inChannels: [Int], outChannels: [Int]) {
            self.frames = frames
            self.inChannels = inChannels
            self.outChannels = outChannels
            inList = AudioBufferList.allocate(maximumBuffers: inChannels.count).unsafeMutablePointer
            outList = AudioBufferList.allocate(maximumBuffers: outChannels.count).unsafeMutablePointer
            let ins = UnsafeMutableAudioBufferListPointer(inList), outs = UnsafeMutableAudioBufferListPointer(outList)
            for (i, ch) in inChannels.enumerated() {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: frames * ch)
                p.initialize(repeating: 0, count: frames * ch)
                inputs.append(p)
                ins[i] = AudioBuffer(mNumberChannels: UInt32(ch), mDataByteSize: UInt32(frames * ch * 4), mData: UnsafeMutableRawPointer(p))
            }
            for (i, ch) in outChannels.enumerated() {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: frames * ch)
                p.initialize(repeating: 0.123, count: frames * ch)
                outputs.append(p)
                outs[i] = AudioBuffer(mNumberChannels: UInt32(ch), mDataByteSize: UInt32(frames * ch * 4), mData: UnsafeMutableRawPointer(p))
            }
        }

        func sine(_ hz: Double, amplitude: Float, phase: inout Double, sampleRate: Double = 48000) {
            let tap = inputs.last!, ch = inChannels.last!
            for f in 0..<frames {
                let v = amplitude * Float(sin(phase))
                phase += 2 * .pi * hz / sampleRate
                for c in 0..<ch { tap[f * ch + c] = v }
            }
        }

        func peak(out index: Int, channel: Int) -> Float {
            let p = outputs[index], ch = outChannels[index]
            var m: Float = 0
            for f in 0..<frames { m = max(m, abs(p[f * ch + channel])) }
            return m
        }

        func maxStep(out index: Int, channel: Int) -> Float {
            let p = outputs[index], ch = outChannels[index]
            var m: Float = 0
            for f in 1..<frames { m = max(m, abs(p[f * ch + channel] - p[(f - 1) * ch + channel])) }
            return m
        }
    }

    private static func pump(_ unit: DSPUnit, _ lists: Lists, hz: Double, amplitude: Float, buffers: Int, phase: inout Double) {
        for _ in 0..<buffers {
            lists.sine(hz, amplitude: amplitude, phase: &phase)
            DSP.render(unit.state, lists.inList, lists.outList)
        }
    }

    static func render() {
        var phase = 0.0
        let unit = DSPUnit()
        unit.set(gain: 1, eq: nil)
        unit.configure(sampleRate: 48000, outStream: 0, left: 0, right: 1)
        let lists = Lists(frames: 512, inChannels: [2], outChannels: [2])

        pump(unit, lists, hz: 1000, amplitude: 0.5, buffers: 20, phase: &phase)
        check(abs(lists.peak(out: 0, channel: 0) - 0.5) < 0.01, "unity passes through", "\(lists.peak(out: 0, channel: 0))")

        unit.set(gain: 0.25, eq: nil)
        pump(unit, lists, hz: 1000, amplitude: 0.5, buffers: 1, phase: &phase)
        check(lists.maxStep(out: 0, channel: 0) < 0.2, "gain change is ramped, no click", "\(lists.maxStep(out: 0, channel: 0))")
        pump(unit, lists, hz: 1000, amplitude: 0.5, buffers: 10, phase: &phase)
        check(abs(lists.peak(out: 0, channel: 0) - 0.125) < 0.005, "50 % on the ruler is −12 dB", "\(lists.peak(out: 0, channel: 0))")

        unit.set(gain: 3.98, eq: nil)
        pump(unit, lists, hz: 1000, amplitude: 0.5, buffers: 60, phase: &phase)
        let boosted = lists.peak(out: 0, channel: 0)
        check(boosted <= 1.0 && boosted > 0.85, "boost is limited below full scale", "\(boosted)")

        unit.set(gain: 3.98, eq: nil)
        pump(unit, lists, hz: 1000, amplitude: 0.05, buffers: 400, phase: &phase)
        let quiet = lists.peak(out: 0, channel: 0)
        check(abs(quiet - 0.199) < 0.01, "quiet sound is boosted 4×", "\(quiet)")

        var gains = [Float](repeating: 0, count: 10)
        gains[5] = 12
        unit.set(gain: 1, eq: gains)
        pump(unit, lists, hz: 1000, amplitude: 0.05, buffers: 1, phase: &phase)
        check(lists.maxStep(out: 0, channel: 0) < 0.08, "EQ fades in without a click", "\(lists.maxStep(out: 0, channel: 0))")
        pump(unit, lists, hz: 1000, amplitude: 0.05, buffers: 400, phase: &phase)
        let eqPeak = lists.peak(out: 0, channel: 0)
        check(abs(eqPeak - 0.199) < 0.012, "+12 dB band lifts its tone 4×", "\(eqPeak)")
        pump(unit, lists, hz: 125, amplitude: 0.05, buffers: 100, phase: &phase)
        let off = lists.peak(out: 0, channel: 0)
        check(abs(off - 0.05) < 0.006, "a tone far from the band is untouched", "\(off)")

        unit.set(gain: 1, eq: nil)
        pump(unit, lists, hz: 1000, amplitude: 0.05, buffers: 1, phase: &phase)
        check(lists.maxStep(out: 0, channel: 0) < 0.08, "EQ fades out without a click", "\(lists.maxStep(out: 0, channel: 0))")

        let small = Lists(frames: 64, inChannels: [2], outChannels: [2])
        unit.set(gain: 1, eq: nil)
        pump(unit, small, hz: 1000, amplitude: 0.5, buffers: 40, phase: &phase)
        unit.set(gain: 0.05, eq: nil)
        pump(unit, small, hz: 1000, amplitude: 0.5, buffers: 1, phase: &phase)
        let firstSmall = small.peak(out: 0, channel: 0)
        pump(unit, small, hz: 1000, amplitude: 0.5, buffers: 9, phase: &phase)
        check(firstSmall > 0.4 && abs(small.peak(out: 0, channel: 0) - 0.025) < 0.003,
              "a level change glides over 10 ms even with 64-frame buffers", "first buffer \(firstSmall), after 10: \(small.peak(out: 0, channel: 0))")

        var lift = [Float](repeating: 0, count: 10), cut = lift
        lift[2] = 12; cut[2] = -12
        unit.set(gain: 1, eq: lift)
        pump(unit, lists, hz: 125, amplitude: 0.05, buffers: 300, phase: &phase)
        let lifted = lists.peak(out: 0, channel: 0)
        unit.set(gain: 1, eq: cut)
        var worst: Float = 0, biggestStep: Float = 0
        for _ in 0..<6 {
            pump(unit, lists, hz: 125, amplitude: 0.05, buffers: 1, phase: &phase)
            worst = max(worst, lists.peak(out: 0, channel: 0))
            biggestStep = max(biggestStep, lists.maxStep(out: 0, channel: 0))
        }
        pump(unit, lists, hz: 125, amplitude: 0.05, buffers: 300, phase: &phase)
        let cutPeak = lists.peak(out: 0, channel: 0)
        print("      preset switch: before \(lifted), worst \(worst), after \(cutPeak), biggest step \(biggestStep)")
        check(worst <= lifted * 1.02 && abs(cutPeak - 0.0126) < 0.002,
              "switching presets mid-sound: no overshoot, lands on the new curve", "before \(lifted), worst \(worst), after \(cutPeak), biggest step \(biggestStep)")

        unit.set(gain: 1, eq: nil)
        pump(unit, lists, hz: 1000, amplitude: 0.5, buffers: 10, phase: &phase)
        unit.silence()
        unit.set(gain: 0.8, eq: nil)
        pump(unit, lists, hz: 1000, amplitude: 0.5, buffers: 4, phase: &phase)
        let held = lists.peak(out: 0, channel: 0)
        unit.resume()
        pump(unit, lists, hz: 1000, amplitude: 0.5, buffers: 10, phase: &phase)
        check(held < 0.001 && abs(lists.peak(out: 0, channel: 0) - 0.4) < 0.01,
              "silence holds through settings changes until resumed", "held \(held), resumed \(lists.peak(out: 0, channel: 0))")

        let abl = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers) ?? -1
        let ch = MemoryLayout<AudioBuffer>.offset(of: \AudioBuffer.mNumberChannels) ?? -1
        let size = MemoryLayout<AudioBuffer>.offset(of: \AudioBuffer.mDataByteSize) ?? -1
        let data = MemoryLayout<AudioBuffer>.offset(of: \AudioBuffer.mData) ?? -1
        check(abl == RawBuffers.firstOffset && ch == 0 && size == 4 && data == 8, "buffer list layout as the callbacks read it",
              "mBuffers at \(abl) (read at \(RawBuffers.firstOffset)), fields at \(ch)/\(size)/\(data)")

        let duplex = Lists(frames: 256, inChannels: [1, 2], outChannels: [2])
        duplex.inputs[0].update(repeating: 0.9, count: 256)
        unit.set(gain: 1, eq: nil)
        unit.configure(sampleRate: 48000, outStream: 0, left: 0, right: 1)
        pump(unit, duplex, hz: 440, amplitude: 0.3, buffers: 4, phase: &phase)
        check(abs(duplex.peak(out: 0, channel: 0) - 0.3) < 0.01, "tap is the last input; the mic is ignored", "\(duplex.peak(out: 0, channel: 0))")

        let multi = Lists(frames: 256, inChannels: [2], outChannels: [2, 2])
        unit.configure(sampleRate: 48000, outStream: 1, left: 0, right: 1)
        pump(unit, multi, hz: 440, amplitude: 0.3, buffers: 4, phase: &phase)
        check(multi.peak(out: 0, channel: 0) == 0 && abs(multi.peak(out: 1, channel: 1) - 0.3) < 0.01,
              "plays on the preferred stream, other streams silent", "\(multi.peak(out: 0, channel: 0)) \(multi.peak(out: 1, channel: 1))")

        let wide = Lists(frames: 256, inChannels: [2], outChannels: [8])
        unit.configure(sampleRate: 48000, outStream: 0, left: 2, right: 3)
        pump(unit, wide, hz: 440, amplitude: 0.3, buffers: 4, phase: &phase)
        check(wide.peak(out: 0, channel: 0) == 0 && abs(wide.peak(out: 0, channel: 2) - 0.3) < 0.01,
              "preferred stereo channels on a wide device", "\(wide.peak(out: 0, channel: 2))")

        let mono = Lists(frames: 256, inChannels: [2], outChannels: [1])
        unit.configure(sampleRate: 48000, outStream: 0, left: 0, right: 0)
        pump(unit, mono, hz: 440, amplitude: 0.3, buffers: 4, phase: &phase)
        check(abs(mono.peak(out: 0, channel: 0) - 0.3) < 0.01, "mono device gets L+R", "\(mono.peak(out: 0, channel: 0))")

        let big = Lists(frames: 9000, inChannels: [2], outChannels: [2])
        unit.configure(sampleRate: 48000, outStream: 0, left: 0, right: 1)
        pump(unit, big, hz: 440, amplitude: 0.3, buffers: 2, phase: &phase)
        check(abs(big.peak(out: 0, channel: 1) - 0.3) < 0.01 && big.outputs[0][8999 * 2] != 0.123,
              "9000-frame buffer fully processed")

        unit.set(gain: 2, eq: [3, 6, 2, -2, -3, -3, -2, -1, 1, 6])
        let perf = Lists(frames: 512, inChannels: [2], outChannels: [2])
        let t0 = Date()
        pump(unit, perf, hz: 220, amplitude: 0.2, buffers: 48000 * 60 / 512, phase: &phase)
        let seconds = Date().timeIntervalSince(t0)
        check(seconds < 0.6, "one minute of audio costs under 1 % of a core", String(format: "%.3f s", seconds))
        print(String(format: "      (%.1f ms per minute of audio ≈ %.3f %% of one core)", seconds * 1000, seconds / 60 * 100))
    }

    static func settings(fineTuneSample: String?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tune-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SettingsStore(url: dir.appendingPathComponent("a.json"), fineTune: nil)
        let video = store.addPreset(named: "video", gains: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        store.select("com.apple.Safari", preset: video.id)
        store.select("ru.keepcoder.Telegram", preset: video.id)
        store.setBand(video.id, band: 9, gain: 3)
        check(store.curve(for: "com.apple.Safari")?[9] == 3 && store.curve(for: "ru.keepcoder.Telegram")?[9] == 3,
              "editing a preset changes it for every app on it")
        check(store.addPreset(named: "video", gains: []).name == "video 2", "new preset names never collide")
        check(!store.needsProcessing("com.spotify.client"), "untouched app is left alone")
        store.setGain("com.spotify.client", 0.6)
        check(store.needsProcessing("com.spotify.client"), "lowered app is processed")
        store.setGain("com.spotify.client", 1)
        let flat = store.addPreset(named: "Flat", gains: [Float](repeating: 0, count: 10))
        store.select("com.spotify.client", preset: flat.id)
        check(!store.needsProcessing("com.spotify.client"), "a flat preset at 100 % costs nothing")
        store.delete(video.id)
        check(store.prefs("com.apple.Safari").presetID == nil, "deleting a preset turns EQ off for its apps")
        store.saveNow()
        let again = SettingsStore(url: dir.appendingPathComponent("a.json"), fineTune: nil)
        check(again.data == store.data, "settings survive a restart")

        let odd = dir.appendingPathComponent("odd.json")
        let id = UUID()
        try? Data("""
        {"version": 2, "futureThing": true,
         "presets": [{"id": "\(id.uuidString)", "name": "short", "gains": [3, 4]}, {"name": "no id"}],
         "apps": {"com.apple.Safari": {"presetID": "\(id.uuidString)"}}}
        """.utf8).write(to: odd)
        let tolerant = SettingsStore(url: odd, fineTune: nil)
        check(tolerant.data.presets.count == 1 && tolerant.data.presets[0].gains.count == 10 && tolerant.data.presets[0].gains[1] == 4,
              "another version's settings load: short preset padded, broken one skipped", "\(tolerant.data.presets)")
        check(tolerant.prefs("com.apple.Safari").gain == 1 && tolerant.curve(for: "com.apple.Safari")?[0] == 3,
              "a missing field takes its default")
        tolerant.setBand(id, band: 9, gain: 2)
        check(tolerant.curve(for: "com.apple.Safari")?[9] == 2, "editing a padded preset works")
        let garbage = dir.appendingPathComponent("garbage.json")
        try? Data("not json".utf8).write(to: garbage)
        _ = SettingsStore(url: garbage, fineTune: nil)
        check(FileManager.default.fileExists(atPath: garbage.path + ".unreadable"), "an unreadable file is kept aside, not lost")

        guard let sample = fineTuneSample else { print("SKIP  FineTune import (no sample given)"); return }
        let imported = SettingsStore(url: dir.appendingPathComponent("b.json"), fineTune: URL(fileURLWithPath: sample))
        let names = imported.data.presets.map(\.name)
        print("      imported presets: \(names)")
        check(names.contains("video") && names.contains("my3"), "FineTune presets imported")
        check(imported.preset(imported.prefs("com.spotify.client").presetID)?.name == "my3", "Spotify keeps my3")
        check(imported.preset(imported.prefs("ru.keepcoder.Telegram").presetID)?.name == "video", "Telegram keeps video")
        check(imported.preset(imported.prefs("com.hnc.Discord").presetID)?.name == "video", "Discord (helper key) keeps video")
        check(imported.preset(imported.prefs("com.apple.Safari").presetID)?.name == "video", "Safari's near-copy links to video")
        check(abs(imported.prefs("com.spotify.client").gain - 0.7711) < 0.001, "Spotify keeps its level")
        check(imported.prefs("us.zoom.xos").presetID == nil, "Zoom's disabled EQ stays off")
    }
}
