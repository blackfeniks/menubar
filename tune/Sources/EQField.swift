import AppKit
import SwiftUI

struct EQField: View {
    let gains: [Float]
    var onEditing: (Bool) -> Void = { _ in }
    let onBand: (Int, Float) -> Void

    @State private var pointer = BarPointer()
    @State private var hoverBand: Int?
    @State private var active: Int?
    @State private var startGain: Float = 0
    @State private var startY: CGFloat = 0
    @State private var lastTap: (band: Int, time: Date)?
    @State private var size: CGSize = .zero
    @State private var curve = EQCurve(gains: [])

    static let height: CGFloat = 128
    static let margin: CGFloat = 20

    var body: some View {
        let shown = active ?? hoverBand
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.white.opacity(0.14)).frame(height: 1).offset(y: Self.height / 2 - 0.5)
            EQBars(curve: curve, pointer: pointer)
            if let band = shown {
                let tip = tipPoint(band)
                Circle()
                    .fill(.white)
                    .frame(width: 8, height: 8)
                    .shadow(color: .white.opacity(0.6), radius: 3.5)
                    .position(tip)
                    .animation(.spring(duration: 0.22, bounce: 0.12), value: band)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if let band = active {
                let tip = tipPoint(band)
                EQBubble(band: band, gain: gains[band])
                    .fixedSize()
                    .position(x: min(max(tip.x, 60), size.width - 60), y: max(tip.y - 26, 12))
                    .allowsHitTesting(false)
            }
        }
        .animation(.smooth(duration: 0.15), value: shown == nil)
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
        .onChange(of: gains, initial: true) { _, new in curve = EQCurve(gains: new) }
        .onDisappear { if active != nil { active = nil; onEditing(false) } }
        .onAppear {
            pointer.onFrame = {
                let band = pointer.inside ? nearestBand(pointer.x) : nil
                if band != hoverBand { hoverBand = band }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if active == nil {
                        let band = nearestBand(g.startLocation.x)
                        active = band
                        startGain = gains[band]
                        startY = g.startLocation.y
                        onEditing(true)
                    }
                    guard let band = active else { return }
                    var gain = startGain - Float((g.location.y - startY) / pointsPerDB)
                    gain = min(max(gain, -EQMath.maxGain), EQMath.maxGain)
                    if abs(gain) < 0.25 { gain = 0 }
                    gain = (gain * 10).rounded() / 10
                    if gain != gains[band] { onBand(band, gain) }
                }
                .onEnded { g in
                    defer {
                        if active != nil { onEditing(false) }
                        active = nil
                    }
                    guard let band = active, abs(g.translation.height) < 2, abs(g.translation.width) < 2 else { return }
                    if let last = lastTap, last.band == band, Date().timeIntervalSince(last.time) < 0.35 {
                        if gains[band] != 0 { onBand(band, 0) }
                        lastTap = nil
                    } else {
                        lastTap = (band, Date())
                    }
                }
        )
    }

    private var pointsPerDB: CGFloat { (Self.height / 2 - Self.margin) / CGFloat(EQMath.maxGain) }

    private func nearestBand(_ x: CGFloat) -> Int {
        guard size.width > 0 else { return 0 }
        var best = 0, bestD = CGFloat.infinity
        for (i, f) in EQMath.frequencies.enumerated() {
            let d = abs(EQCanvas.x(f, size.width) - x)
            if d < bestD { best = i; bestD = d }
        }
        return best
    }

    private func tipPoint(_ band: Int) -> CGPoint {
        let db = band < curve.bandDB.count ? curve.bandDB[band] : 0
        let mid = Self.height / 2
        return CGPoint(x: EQCanvas.x(EQMath.frequencies[band], size.width), y: mid - CGFloat(max(-14, min(14, db))) * pointsPerDB)
    }
}

struct EQBubble: View {
    let band: Int
    let gain: Float
    var body: some View {
        HStack(spacing: 4) {
            Text("\(EQMath.labels[band]) Hz").fontWeight(.semibold)
            Text(String(format: "%+.1f dB", gain)).foregroundStyle(Color(white: 0.33))
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Color(white: 0.07))
        .padding(.horizontal, 8).padding(.vertical, 3.5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.94)))
        .shadow(color: .black.opacity(0.35), radius: 7, y: 4)
    }
}

struct EQCurve: Equatable {
    struct Bar: Equatable { let f: Double; let db: Double; let isBand: Bool }
    let bars: [Bar]
    let bandDB: [Double]

    init(gains: [Float]) {
        let g = gains.count == EQMath.bands ? gains : [Float](repeating: 0, count: EQMath.bands)
        let kmin = Int(ceil(Double(EQCanvas.perOctave) * log2(22.0 / 32))), kmax = Int(floor(Double(EQCanvas.perOctave) * log2(20000.0 / 32)))
        let c = EQMath.coefficients(gains: g, sampleRate: 48000)
        bars = (kmin...kmax).map { i in
            let f = 32 * pow(2, Double(i) / Double(EQCanvas.perOctave))
            return Bar(f: f, db: EQMath.responseDB(f, coefficients: c), isBand: i % EQCanvas.perOctave == 0 && i >= 0 && i / EQCanvas.perOctave <= 9)
        }
        bandDB = EQMath.frequencies.map { EQMath.responseDB($0, coefficients: c) }
    }
}

struct EQBars: View {
    let curve: EQCurve
    let pointer: BarPointer

    var body: some View {
        let curve = curve
        if PanelView.offscreen {
            GeometryReader { geo in BarTicksPicture(ticks: EQCanvas.ticks(curve: curve, size: geo.size, hoverX: 0, lift: 0)) }
        } else {
            BarTicks(pointer: pointer) { size, hoverX, lift in
                EQCanvas.ticks(curve: curve, size: size, hoverX: hoverX, lift: lift)
            }
        }
    }
}

enum EQCanvas {
    static let perOctave = 4
    private static let logMin = log10(22.0), logMax = log10(20000.0)

    static func x(_ f: Double, _ width: CGFloat) -> CGFloat {
        CGFloat((log10(f) - logMin) / (logMax - logMin)) * width
    }

    static func ticks(curve: EQCurve, size: CGSize, hoverX: CGFloat, lift: Double) -> [BarTick] {
        let mid = size.height / 2
        let k = (size.height / 2 - EQField.margin) / CGFloat(EQMath.maxGain)
        let w = RulerStyle.tickWidth
        var out: [BarTick] = []
        out.reserveCapacity(curve.bars.count)
        for bar in curve.bars {
            let x = x(bar.f, size.width)
            let db = CGFloat(max(-14, min(14, bar.db)))
            let len = abs(db) * k
            var a = bar.isBand ? 1.0 : 0.78
            if lift > 0 {
                let s = RulerStyle.wave(abs(x - hoverX)) * CGFloat(lift)
                a = min(1, a * (1 + (s > 0 ? 1.2 : 0.5) * Double(s)))
            }
            if len < 1.2 {
                out.append(BarTick(rect: CGRect(x: x - 1, y: mid - 1, width: 2, height: 2), opacity: 0.35 * a))
                continue
            }
            out.append(BarTick(rect: CGRect(x: x - w / 2, y: db >= 0 ? mid - len : mid, width: w, height: len),
                               opacity: a, rootFade: 0.14, rootAtBottom: db >= 0))
        }
        return out
    }
}
