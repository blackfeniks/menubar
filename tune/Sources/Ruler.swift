import AppKit
import SwiftUI

enum RulerStyle {
    static let height: CGFloat = 34
    static let tickWidth: CGFloat = 2.2
    static let mid: CGFloat = 8
    static let major: CGFloat = 12.5
    static let wall: CGFloat = 17
    static let lit = 0.96
    static let litMinor = 0.8
    static let dim = 0.15
    static let wallDim = 0.42
    static let liftHeight: CGFloat = 16
    static let liftRadius: CGFloat = 42
    static let dip: CGFloat = 0.58
    static let amber = Color(red: 1, green: 0.71, blue: 0.28)
    static let amberNeedle = Color(red: 1, green: 0.78, blue: 0.45)

    static func wave(_ distance: CGFloat) -> CGFloat {
        let u = distance / liftRadius
        guard u < 1.5 else { return 0 }
        let v = cos(.pi * u) * (1 - u / 1.5)
        return v < 0 ? v * dip : v
    }
}

struct TickRuler: View {
    enum Kind { case level, plain }

    let kind: Kind
    let value: Double
    var enabled = true
    var onEditing: (Bool) -> Void = { _ in }
    let onChange: (Double) -> Void

    @State private var pointer = BarPointer()
    @State private var dragging = false
    @State private var width: CGFloat = 0
    @State private var inDetent = false

    private static let pad: CGFloat = 1.5

    var body: some View {
        let p = position(of: value)
        let boosted = kind == .level && value > 1.0005
        ZStack(alignment: .topLeading) {
            RulerMarks(kind: kind, position: p, pointer: pointer)
            Needle(boosted: boosted, enabled: enabled)
                .offset(x: Self.pad + CGFloat(p) * inner - Needle.width / 2, y: RulerStyle.height - 6 + 4 - Needle.height)
        }
        .animation(dragging ? nil : .smooth(duration: 0.25), value: p)
        .frame(height: RulerStyle.height)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .onChange(of: enabled, initial: true) { pointer.enabled = enabled }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard enabled else { return }
                    if !dragging {
                        dragging = true
                        pointer.held = true
                        onEditing(true)
                    }
                    var still = Transaction()
                    still.disablesAnimations = true
                    withTransaction(still) { onChange(valueAt(x: g.location.x)) }
                }
                .onEnded { g in
                    guard dragging else { return }
                    dragging = false
                    pointer.held = false
                    inDetent = false
                    onEditing(false)
                }
        )
        .opacity(enabled ? 1 : 0.45)
        .onDisappear { if dragging { dragging = false; pointer.held = false; onEditing(false) } }
    }

    private func position(of v: Double) -> Double {
        kind == .level ? Level.position(ofGain: Float(v)) : min(max(v, 0), 1)
    }

    private func value(atPosition p: Double) -> Double {
        kind == .level ? Double(Level.gain(atPosition: p)) : p
    }

    private var inner: CGFloat { max(1, width - 2 * Self.pad) }

    private func valueAt(x: CGFloat) -> Double {
        var p = Double(min(max((x - Self.pad) / inner, 0), 1))
        if kind == .level {
            let wallX = Level.mainFraction * Double(inner)
            if abs(p * Double(inner) - wallX) < 7 {
                p = Level.mainFraction
                if !inDetent {
                    inDetent = true
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            } else {
                inDetent = false
            }
        }
        if p * Double(inner) < 3 { p = 0 }
        return value(atPosition: p)
    }

}

struct RulerMarks: View, Animatable {
    let kind: TickRuler.Kind
    var position: Double
    let pointer: BarPointer

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    var body: some View {
        let (kind, position) = (kind, position)
        if PanelView.offscreen {
            GeometryReader { geo in
                BarTicksPicture(ticks: RulerScale.ticks(kind: kind, position: position, size: geo.size, hoverX: 0, lift: 0))
            }
        } else {
            BarTicks(pointer: pointer) { size, hoverX, lift in
                RulerScale.ticks(kind: kind, position: position, size: size, hoverX: hoverX, lift: lift)
            }
        }
    }
}

enum RulerScale {
    private struct Mark { let p: Double; let height: CGFloat; let boost: Bool; let wall: Bool; let minor: Bool }

    private static let levelMarks = makeMarks(.level)
    private static let plainMarks = makeMarks(.plain)

    private static func makeMarks(_ kind: TickRuler.Kind) -> [Mark] {
        var out: [Mark] = []
        let mainEnd = kind == .level ? Level.mainFraction : 1
        for i in 0...20 {
            let pct = i * 5
            let p = Double(pct) / 100 * mainEnd
            let wall = kind == .level && pct == 100
            let major = pct % 25 == 0
            out.append(Mark(p: p, height: wall ? RulerStyle.wall : major ? RulerStyle.major : RulerStyle.mid,
                            boost: false, wall: wall, minor: !major && !wall))
        }
        if kind == .level {
            for k in 1...6 {
                let db = Double(k) * 2
                let p = Level.mainFraction + db / Level.maxBoostDB * (1 - Level.mainFraction)
                let h = RulerStyle.mid - 1 + (RulerStyle.wall - RulerStyle.mid + 1) * CGFloat(db / Level.maxBoostDB)
                out.append(Mark(p: p, height: h, boost: true, wall: false, minor: false))
            }
        }
        return out
    }

    static func ticks(kind: TickRuler.Kind, position: Double, size: CGSize, hoverX: CGFloat, lift: Double) -> [BarTick] {
        let pad: CGFloat = 1.5
        let inner = size.width - 2 * pad
        let base = size.height - 6
        let needleX = pad + CGFloat(position) * inner
        let litLimit = position + 1e-6
        let marks = kind == .level ? levelMarks : plainMarks
        var out: [BarTick] = []
        out.reserveCapacity(marks.count)
        for t in marks {
            let x = pad + CGFloat(t.p) * inner
            if abs(x - needleX) < 3.4 { continue }
            var h = t.height
            let lit = t.p <= litLimit
            var alpha: Double
            if t.wall { alpha = lit ? 1 : RulerStyle.wallDim }
            else { alpha = lit ? (t.minor ? RulerStyle.litMinor : RulerStyle.lit) : RulerStyle.dim }
            if lift > 0 {
                let swell = RulerStyle.wave(abs(x - hoverX)) * CGFloat(lift)
                h = max(3, h + RulerStyle.liftHeight * swell)
                alpha = min(1, max(0.05, alpha * (1 + (swell > 0 ? 1.15 : 0.6) * Double(swell))))
            }
            out.append(BarTick(rect: CGRect(x: x - RulerStyle.tickWidth / 2, y: base - h, width: RulerStyle.tickWidth, height: h),
                               opacity: alpha, color: t.boost && lit ? .amber : .white))
        }
        return out
    }
}

struct Needle: View {
    let boosted: Bool
    let enabled: Bool
    static let width: CGFloat = 2.7
    static let height: CGFloat = 25

    var body: some View {
        let tint: Color = boosted ? RulerStyle.amberNeedle : .white
        Capsule()
            .fill(tint)
            .frame(width: Self.width, height: Self.height)
            .shadow(color: tint.opacity(enabled ? 0.55 : 0), radius: 4)
            .allowsHitTesting(false)
    }
}

struct PercentText: View {
    let percent: Int
    var boosted = false
    var size: CGFloat = UI.percent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("\(percent)")
                .font(.system(size: size, weight: .regular, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(percent)))
            Text("%")
                .font(.system(size: size * 0.66, weight: .regular, design: .rounded))
                .opacity(0.45)
        }
        .foregroundStyle(boosted ? RulerStyle.amber : Color.white.opacity(0.92))
        .animation(.snappy(duration: 0.18), value: percent)
        .frame(minWidth: size * 2.6, alignment: .trailing)
    }
}
