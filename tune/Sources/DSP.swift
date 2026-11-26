import AudioToolbox
import Foundation
import os

enum EQMath {
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    static let bands = 10
    static let q = 1.4
    static let maxGain: Float = 12
    static let identity: [Float] = [1, 0, 0, 0, 0]

    static func peaking(f0: Double, gainDB: Double, sampleRate: Double, q: Double = q) -> [Float] {
        guard abs(gainDB) >= 0.01, f0 < sampleRate * 0.45 else { return identity }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * f0 / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cw = cos(w0)
        let a0 = 1 + alpha / a
        return [Float((1 + alpha * a) / a0), Float(-2 * cw / a0), Float((1 - alpha * a) / a0),
                Float(-2 * cw / a0), Float((1 - alpha / a) / a0)]
    }

    static func coefficients(gains: [Float], sampleRate: Double) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(bands * 5)
        for i in 0..<bands {
            out += peaking(f0: frequencies[i], gainDB: Double(i < gains.count ? gains[i] : 0), sampleRate: sampleRate)
        }
        return out
    }

    static func isFlat(_ gains: [Float]) -> Bool { gains.allSatisfy { abs($0) < 0.01 } }

    static func responseDB(_ f: Double, gains: [Float], sampleRate: Double = 48000) -> Double {
        responseDB(f, coefficients: coefficients(gains: gains, sampleRate: sampleRate), sampleRate: sampleRate)
    }

    static func responseDB(_ f: Double, coefficients c: [Float], sampleRate: Double = 48000) -> Double {
        let w = 2 * Double.pi * f / sampleRate
        var total = 0.0
        for s in 0..<bands {
            let b0 = Double(c[s * 5]), b1 = Double(c[s * 5 + 1]), b2 = Double(c[s * 5 + 2])
            let a1 = Double(c[s * 5 + 3]), a2 = Double(c[s * 5 + 4])
            let nr = b0 + b1 * cos(w) + b2 * cos(2 * w), ni = -(b1 * sin(w) + b2 * sin(2 * w))
            let dr = 1 + a1 * cos(w) + a2 * cos(2 * w), di = -(a1 * sin(w) + a2 * sin(2 * w))
            total += 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
        }
        return total
    }
}

enum Level {
    static let mainFraction = 0.76
    static let maxBoostDB = 20 * log10(4.0)
    static let maxGain = Float(pow(10, maxBoostDB / 20))

    static func gain(atPosition p: Double) -> Float {
        let p = min(max(p, 0), 1)
        if p <= mainFraction {
            let t = p / mainFraction
            return Float(t * t)
        }
        let db = (p - mainFraction) / (1 - mainFraction) * maxBoostDB
        return Float(pow(10, db / 20))
    }

    static func position(ofGain g: Float) -> Double {
        if g <= 1 { return Double(max(g, 0)).squareRoot() * mainFraction }
        let db = min(20 * log10(Double(g)), maxBoostDB)
        return mainFraction + db / maxBoostDB * (1 - mainFraction)
    }

    static func percent(ofGain g: Float) -> Int {
        g <= 1 ? Int((Double(max(g, 0)).squareRoot() * 100).rounded()) : Int((Double(g) * 100).rounded())
    }
}

struct RTState {
    var sampleRate: Float = 48000
    var outStream: Int32 = 0
    var outStreamRight: Int32 = 0
    var outLeft: Int32 = 0
    var outRight: Int32 = 1
    var capacity: Int32 = 0
    var lookahead: Int32 = 64
    var rampFrames: Int32 = 480

    var lock: UnsafeMutablePointer<os_unfair_lock>
    var dirty: UInt32 = 0
    var pendingGain: Float = 1
    var pendingEQ: UInt32 = 0
    var pendingCoeffs: UnsafeMutablePointer<Float>

    var gain: Float = 1
    var gainTarget: Float = 1
    var gainStep: Float = 0
    var gainLeft: Int32 = 0
    var eqMix: Float = 0
    var eqTarget: Float = 0
    var coeffs: UnsafeMutablePointer<Float>
    var zLeft: UnsafeMutablePointer<Float>
    var zRight: UnsafeMutablePointer<Float>
    var left: UnsafeMutablePointer<Float>
    var right: UnsafeMutablePointer<Float>
    var dryLeft: UnsafeMutablePointer<Float>
    var dryRight: UnsafeMutablePointer<Float>
    var delayLeft: UnsafeMutablePointer<Float>
    var delayRight: UnsafeMutablePointer<Float>
    var delayPos: Int32 = 0
    var limEnv: Float = 0
    var limGain: Float = 1
    var limRelease: Float = 0.9998
    var limAttack: Float = 0.05

    var callbacks: UInt64 = 0
    var heard: UInt64 = 0
    var loudFrames: UInt64 = 0
    var peak: Float = 0
    var testStall: UInt32 = 0
}

struct RawBuffers {
    let base: UnsafeMutableRawPointer
    @inline(__always) init(_ list: UnsafePointer<AudioBufferList>) { base = UnsafeMutableRawPointer(mutating: list) }
    @inline(__always) init(_ list: UnsafeMutablePointer<AudioBufferList>) { base = UnsafeMutableRawPointer(list) }
    @inline(__always) static var firstOffset: Int {
        let align = MemoryLayout<AudioBuffer>.alignment
        return (MemoryLayout<UInt32>.size + align - 1) & ~(align - 1)
    }
    @inline(__always) var count: Int { Int(base.load(as: UInt32.self)) }
    @inline(__always) private func at(_ i: Int) -> UnsafeMutableRawPointer {
        base + (Self.firstOffset + i * MemoryLayout<AudioBuffer>.stride)
    }
    @inline(__always) func channels(_ i: Int) -> Int { Int(at(i).load(as: UInt32.self)) }
    @inline(__always) func bytes(_ i: Int) -> Int { Int(at(i).load(fromByteOffset: 4, as: UInt32.self)) }
    @inline(__always) func data(_ i: Int) -> UnsafeMutableRawPointer? { at(i).load(fromByteOffset: 8, as: UnsafeMutableRawPointer?.self) }
}

let tuneIOProc: AudioDeviceIOProc = { _, _, inputData, _, outputData, _, clientData in
    guard let clientData else { return noErr }
    DSP.render(clientData.assumingMemoryBound(to: RTState.self), inputData, outputData)
    return noErr
}

enum DSP {
    static let ceiling: Float = 0.95
    static let maxLookahead = 512
    static let audible: Float = 0.0018

    @inline(__always)
    static func render(_ st: UnsafeMutablePointer<RTState>, _ inList: UnsafePointer<AudioBufferList>,
                       _ outList: UnsafeMutablePointer<AudioBufferList>) {
        if st.pointee.testStall != 0 { usleep(st.pointee.testStall); st.pointee.testStall = 0 }
        if st.pointee.dirty != 0, os_unfair_lock_trylock(st.pointee.lock) {
            let target = st.pointee.pendingGain
            if target != st.pointee.gainTarget {
                st.pointee.gainTarget = target
                st.pointee.gainStep = (target - st.pointee.gain) / Float(st.pointee.rampFrames)
                st.pointee.gainLeft = st.pointee.rampFrames
            }
            st.pointee.eqTarget = st.pointee.pendingEQ != 0 ? 1 : 0
            if st.pointee.pendingEQ != 0 {
                st.pointee.coeffs.update(from: st.pointee.pendingCoeffs, count: 50)
            }
            st.pointee.dirty = 0
            os_unfair_lock_unlock(st.pointee.lock)
        }

        let outs = RawBuffers(outList)
        let outCount = outs.count
        for i in 0..<outCount {
            if let data = outs.data(i) { memset(data, 0, outs.bytes(i)) }
        }
        let ins = RawBuffers(inList)
        let inCount = ins.count
        guard inCount > 0 else { return }
        let tap = inCount - 1
        guard let inRaw = ins.data(tap) else { return }
        let inCh = max(1, ins.channels(tap))
        let outIndex = Int(st.pointee.outStream)
        guard outIndex < outCount, let outRaw = outs.data(outIndex) else { return }
        let outCh = max(1, outs.channels(outIndex))
        var rIndex = Int(st.pointee.outStreamRight)
        if rIndex >= outCount || outs.data(rIndex) == nil { rIndex = outIndex }
        guard let rRaw = outs.data(rIndex) else { return }
        let rCh = max(1, outs.channels(rIndex))
        let frames = min(ins.bytes(tap) / (4 * inCh), outs.bytes(outIndex) / (4 * outCh), outs.bytes(rIndex) / (4 * rCh))
        guard frames > 0 else { return }

        let input = inRaw.assumingMemoryBound(to: Float.self)
        let output = outRaw.assumingMemoryBound(to: Float.self)
        let outputR = rRaw.assumingMemoryBound(to: Float.self)
        let leftCh = max(0, min(Int(st.pointee.outLeft), outCh - 1))
        let rightCh = max(0, min(Int(st.pointee.outRight), rCh - 1))
        let cap = Int(st.pointee.capacity)
        var done = 0
        var peak: Float = 0
        while done < frames {
            let n = min(cap, frames - done)
            peak = max(peak, process(st, input + done * inCh, inCh, output + done * outCh, outCh, leftCh,
                                     outputR + done * rCh, rCh, rightCh, rIndex == outIndex, n))
            done += n
        }
        if peak > 0 { st.pointee.heard &+= 1 }
        if peak > audible { st.pointee.loudFrames &+= UInt64(frames) }
        st.pointee.peak = peak
        st.pointee.callbacks &+= 1
    }

    @inline(__always)
    static func process(_ st: UnsafeMutablePointer<RTState>, _ input: UnsafePointer<Float>, _ inCh: Int,
                        _ output: UnsafeMutablePointer<Float>, _ outCh: Int, _ leftCh: Int,
                        _ outputR: UnsafeMutablePointer<Float>, _ rCh: Int, _ rightCh: Int, _ sameStream: Bool, _ n: Int) -> Float {
        let l = st.pointee.left, r = st.pointee.right
        var peak: Float = 0
        if inCh >= 2 {
            for i in 0..<n {
                let a = input[i * inCh], b = input[i * inCh + 1]
                let x = a.isFinite ? a : 0, y = b.isFinite ? b : 0
                l[i] = x
                r[i] = y
                peak = max(peak, abs(x), abs(y))
            }
        } else {
            for i in 0..<n {
                let a = input[i]
                let x = a.isFinite ? a : 0
                l[i] = x
                r[i] = x
                peak = max(peak, abs(x))
            }
        }

        var g = st.pointee.gain
        var rampLeft = Int(st.pointee.gainLeft)
        if rampLeft > 0 {
            let k = min(n, rampLeft)
            let step = st.pointee.gainStep
            for i in 0..<k {
                l[i] *= g
                r[i] *= g
                g += step
            }
            rampLeft -= k
            if rampLeft == 0 { g = st.pointee.gainTarget }
            if k < n, g != 1 {
                for i in k..<n { l[i] *= g; r[i] *= g }
            }
            st.pointee.gain = g
            st.pointee.gainLeft = Int32(rampLeft)
        } else if g != 1 {
            for i in 0..<n { l[i] *= g; r[i] *= g }
        }

        let m0 = st.pointee.eqMix, m1 = st.pointee.eqTarget
        if m0 > 0 || m1 > 0 {
            let mixing = m0 != m1
            if mixing {
                st.pointee.dryLeft.update(from: l, count: n)
                st.pointee.dryRight.update(from: r, count: n)
            }
            cascade(l, r, n, st.pointee.coeffs, st.pointee.zLeft, st.pointee.zRight)
            if mixing {
                let dl = st.pointee.dryLeft, dr = st.pointee.dryRight
                let step = (m1 > m0 ? 1 : -1) / Float(st.pointee.rampFrames)
                var m = m0
                for i in 0..<n {
                    m = step > 0 ? min(m1, m + step) : max(m1, m + step)
                    l[i] = dl[i] + (l[i] - dl[i]) * m
                    r[i] = dr[i] + (r[i] - dr[i]) * m
                }
                st.pointee.eqMix = m
                if m == 0 {
                    st.pointee.zLeft.update(repeating: 0, count: 20)
                    st.pointee.zRight.update(repeating: 0, count: 20)
                }
            }
        }

        limit(st, l, r, n)

        if sameStream && leftCh == rightCh {
            for i in 0..<n { output[i * outCh + leftCh] = 0.5 * (l[i] + r[i]) }
        } else {
            for i in 0..<n {
                output[i * outCh + leftCh] = l[i]
                outputR[i * rCh + rightCh] = r[i]
            }
        }
        return peak
    }

    @inline(__always)
    static func cascade(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int,
                        _ c: UnsafeMutablePointer<Float>, _ zl: UnsafeMutablePointer<Float>, _ zr: UnsafeMutablePointer<Float>) {
        for s in 0..<10 {
            let b0 = c[s * 5], b1 = c[s * 5 + 1], b2 = c[s * 5 + 2], a1 = c[s * 5 + 3], a2 = c[s * 5 + 4]
            if b0 == 1 && b1 == 0 && b2 == 0 && a1 == 0 && a2 == 0 {
                zl[s * 2] = 0; zl[s * 2 + 1] = 0; zr[s * 2] = 0; zr[s * 2 + 1] = 0
                continue
            }
            var l1 = zl[s * 2], l2 = zl[s * 2 + 1], r1 = zr[s * 2], r2 = zr[s * 2 + 1]
            for i in 0..<n {
                let vl = l[i], vr = r[i]
                let yl = b0 * vl + l1, yr = b0 * vr + r1
                l1 = b1 * vl - a1 * yl + l2
                r1 = b1 * vr - a1 * yr + r2
                l2 = b2 * vl - a2 * yl
                r2 = b2 * vr - a2 * yr
                l[i] = yl
                r[i] = yr
            }
            zl[s * 2] = l1; zl[s * 2 + 1] = l2
            zr[s * 2] = r1; zr[s * 2 + 1] = r2
        }
    }

    @inline(__always)
    static func limit(_ st: UnsafeMutablePointer<RTState>, _ l: UnsafeMutablePointer<Float>,
                      _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        let d = Int(st.pointee.lookahead)
        let dl = st.pointee.delayLeft, dr = st.pointee.delayRight
        var pos = Int(st.pointee.delayPos)
        var env = st.pointee.limEnv, g = st.pointee.limGain
        let release = st.pointee.limRelease, attack = st.pointee.limAttack
        let ceil = ceiling
        for i in 0..<n {
            let xl = l[i], xr = r[i]
            let p = max(abs(xl), abs(xr))
            env = p > env ? p : env * release
            let target: Float = env > ceil ? ceil / env : 1
            g += (target - g) * (target < g ? attack : (1 - release) * 8)
            let yl = dl[pos] * g, yr = dr[pos] * g
            dl[pos] = xl
            dr[pos] = xr
            pos += 1
            if pos >= d { pos = 0 }
            l[i] = min(max(yl, -1), 1)
            r[i] = min(max(yr, -1), 1)
        }
        st.pointee.delayPos = Int32(pos)
        st.pointee.limEnv = env
        st.pointee.limGain = g
    }
}

final class DSPUnit {
    let state: UnsafeMutablePointer<RTState>
    private(set) var sampleRate: Double = 48000
    private var gain: Float = 1
    private var eqGains: [Float]? = nil
    private var held = false
    static let capacity = 4096
    nonisolated(unsafe) private static var lockFailureNoted = false
    nonisolated(unsafe) private static var made: UInt64 = 0
    let generation: UInt64
    private let block: UnsafeMutableRawPointer
    private let blockSize: Int
    private let mapped: Bool

    init() {
        Self.made += 1
        generation = Self.made
        let floatCount = 50 + 50 + 20 + 20 + 4 * Self.capacity + 2 * DSP.maxLookahead
        let page = Int(getpagesize())
        let raw = MemoryLayout<RTState>.stride + MemoryLayout<os_unfair_lock>.stride + 16 + floatCount * MemoryLayout<Float>.stride
        blockSize = (raw + page - 1) / page * page
        let region = mmap(nil, blockSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        if let region, region != MAP_FAILED {
            block = region
            self.mapped = true
            if mlock(block, blockSize) != 0, !Self.lockFailureNoted {
                Self.lockFailureNoted = true
                Log.line("Could not keep a path's memory in RAM (errno \(errno)); it works, only less sure under memory pressure")
            }
        } else {
            block = UnsafeMutableRawPointer.allocate(byteCount: blockSize, alignment: page)
            block.initializeMemory(as: UInt8.self, repeating: 0, count: blockSize)
            self.mapped = false
        }
        var cursor = MemoryLayout<RTState>.stride + MemoryLayout<os_unfair_lock>.stride
        cursor = (cursor + 15) & ~15
        func floats(_ n: Int) -> UnsafeMutablePointer<Float> {
            let p = (block + cursor).bindMemory(to: Float.self, capacity: n)
            p.initialize(repeating: 0, count: n)
            cursor += n * MemoryLayout<Float>.stride
            return p
        }
        let lock = (block + MemoryLayout<RTState>.stride).bindMemory(to: os_unfair_lock.self, capacity: 1)
        lock.initialize(to: os_unfair_lock())
        state = block.bindMemory(to: RTState.self, capacity: 1)
        state.initialize(to: RTState(
            capacity: Int32(Self.capacity),
            lock: lock, pendingCoeffs: floats(50),
            coeffs: floats(50), zLeft: floats(20), zRight: floats(20),
            left: floats(Self.capacity), right: floats(Self.capacity),
            dryLeft: floats(Self.capacity), dryRight: floats(Self.capacity),
            delayLeft: floats(DSP.maxLookahead), delayRight: floats(DSP.maxLookahead)))
        setIdentity(state.pointee.coeffs)
        setIdentity(state.pointee.pendingCoeffs)
    }

    deinit {
        state.deinitialize(count: 1)
        if mapped { munmap(block, blockSize) } else { block.deallocate() }
    }

    private func setIdentity(_ c: UnsafeMutablePointer<Float>) {
        for s in 0..<10 { c[s * 5] = 1; c[s * 5 + 1] = 0; c[s * 5 + 2] = 0; c[s * 5 + 3] = 0; c[s * 5 + 4] = 0 }
    }

    func configure(sampleRate: Double, outStream: Int, left: Int, right: Int, rightStream: Int? = nil) {
        self.sampleRate = sampleRate
        let s = state
        s.pointee.sampleRate = Float(sampleRate)
        s.pointee.outStream = Int32(outStream)
        s.pointee.outStreamRight = Int32(rightStream ?? outStream)
        s.pointee.outLeft = Int32(left)
        s.pointee.outRight = Int32(right)
        s.pointee.lookahead = Int32(min(DSP.maxLookahead, max(16, Int(sampleRate * 0.0015))))
        s.pointee.rampFrames = Int32(max(16, Int(sampleRate * 0.01)))
        s.pointee.limRelease = Float(exp(-1 / (0.12 * sampleRate)))
        s.pointee.limAttack = Float(1 - exp(-1 / (Double(s.pointee.lookahead) / 4)))
        s.pointee.zLeft.update(repeating: 0, count: 20)
        s.pointee.zRight.update(repeating: 0, count: 20)
        s.pointee.delayLeft.update(repeating: 0, count: DSP.maxLookahead)
        s.pointee.delayRight.update(repeating: 0, count: DSP.maxLookahead)
        s.pointee.delayPos = 0
        s.pointee.limEnv = 0
        s.pointee.limGain = 1
        held = false
        s.pointee.gain = gain
        s.pointee.gainTarget = gain
        s.pointee.gainLeft = 0
        let eqOn = eqGains.map { !EQMath.isFlat($0) } ?? false
        s.pointee.eqMix = eqOn ? 1 : 0
        s.pointee.eqTarget = s.pointee.eqMix
        let c = EQMath.coefficients(gains: eqGains ?? [], sampleRate: sampleRate)
        c.withUnsafeBufferPointer { s.pointee.coeffs.update(from: $0.baseAddress!, count: 50) }
        s.pointee.dirty = 0
    }

    func set(gain: Float, eq: [Float]?) {
        self.gain = min(max(gain, 0), Level.maxGain)
        self.eqGains = eq
        if !held { publish() }
    }

    private func publish() {
        let on = eqGains.map { !EQMath.isFlat($0) } ?? false
        let c = on ? EQMath.coefficients(gains: eqGains!, sampleRate: sampleRate) : []
        os_unfair_lock_lock(state.pointee.lock)
        state.pointee.pendingGain = held ? 0 : gain
        state.pointee.pendingEQ = on && !held ? 1 : 0
        if on, !held { c.withUnsafeBufferPointer { state.pointee.pendingCoeffs.update(from: $0.baseAddress!, count: 50) } }
        state.pointee.dirty = 1
        os_unfair_lock_unlock(state.pointee.lock)
    }

    func silence() {
        held = true
        publish()
    }

    func fadeIn() {
        state.pointee.gain = 0
        state.pointee.gainTarget = 0
        state.pointee.gainLeft = 0
        publish()
    }

    func resume() {
        guard held else { return }
        held = false
        publish()
    }

    var callbacks: UInt64 { state.pointee.callbacks }
    var heard: UInt64 { state.pointee.heard }
    var loudFrames: UInt64 { state.pointee.loudFrames }
}
