import AppKit
import CoreAudio
import SwiftUI

enum PanelMetrics {
    static let width: CGFloat = 320
    static let padding: CGFloat = Bar.padding
    static let margin: CGFloat = Bar.margin
    static let spare: CGFloat = 300
}

enum UI {
    static let tab: CGFloat = 13.5
    static let tabOn: CGFloat = 15
    static let tabsHeight: CGFloat = 27
    static let name: CGFloat = 14.5
    static let label: CGFloat = 12.5
    static let title: CGFloat = 16.5
    static let percent: CGFloat = 16
    static let note: CGFloat = 12
    static let empty: CGFloat = 13.5
    static let icon: CGFloat = 23
    static let rowGap: CGFloat = 13
    static let sectionGap: CGFloat = 12
    static let idle = 0.5
}

enum Page: Equatable {
    case main
    case app(String)

    var id: String {
        switch self {
        case .main: "main"
        case .app(let key): "app:" + key
        }
    }
    var edge: Double { self == .main ? -1 : 1 }
}

struct PageShift: ViewModifier, Animatable {
    var progress: Double
    let edge: Double
    let leaving: Bool
    static let distance: CGFloat = 28

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let opacity = leaving ? max(0, 1 - progress / 0.4) : min(1, max(0, (0.7 - progress) / 0.7))
        content
            .opacity(opacity)
            .offset(x: CGFloat(edge * progress) * Self.distance)
    }
}

struct RowReveal: ViewModifier, Animatable {
    var progress: Double
    let leaving: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let opacity = leaving ? max(0, 1 - progress / 0.5) : min(1, max(0, (0.8 - progress) / 0.8))
        content
            .opacity(opacity)
            .mask(alignment: .top) {
                Rectangle().scaleEffect(x: 1, y: max(0.001, 1 - progress), anchor: .top)
            }
    }
}

extension View {
    func pageItem(_ page: Page) -> some View {
        layoutValue(key: PageStack.Key.self, value: page.id).transition(.page(page))
    }
}

extension AnyTransition {
    static var fadeThrough: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: PageShift(progress: 1, edge: 0, leaving: false),
                                 identity: PageShift(progress: 0, edge: 0, leaving: false)),
            removal: .modifier(active: PageShift(progress: 1, edge: 0, leaving: true),
                               identity: PageShift(progress: 0, edge: 0, leaving: true)))
    }

    static var row: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: RowReveal(progress: 1, leaving: false), identity: RowReveal(progress: 0, leaving: false)),
            removal: .modifier(active: RowReveal(progress: 1, leaving: true), identity: RowReveal(progress: 0, leaving: true)))
    }

    static func page(_ page: Page) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: PageShift(progress: 1, edge: page.edge, leaving: false),
                                 identity: PageShift(progress: 0, edge: page.edge, leaving: false)),
            removal: .modifier(active: PageShift(progress: 1, edge: page.edge, leaving: true),
                               identity: PageShift(progress: 0, edge: page.edge, leaving: true)))
    }
}

struct PageStack: Layout {
    let current: String

    struct Key: LayoutValueKey { static let defaultValue = "" }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let shown = subviews.first(where: { $0[Key.self] == current }) ?? subviews.last else { return .zero }
        let size = shown.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for s in subviews {
            s.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

@MainActor
@Observable
final class PanelState {
    var page: Page = .main
}

struct PanelPages: View {
    let model: Model
    let state: PanelState

    var body: some View {
        PageStack(current: state.page.id) { page(state.page) }
        .padding(PanelMetrics.padding)
        .animation(.smooth(duration: 0.34), value: state.page)
        .animation(.smooth(duration: 0.3), value: model.appKeys)
        .animation(.smooth(duration: 0.3), value: model.micActive)
    }

    @ViewBuilder
    func page(_ page: Page) -> some View {
        switch page {
        case .main: MainPage(model: model, state: state).pageItem(page)
        case .app(let key): AppPage(model: model, key: key) { state.page = .main }.pageItem(page)
        }
    }
}

struct PanelView: View {
    static var offscreen: Bool {
        get { Bar.offscreen }
        set { Bar.offscreen = newValue }
    }
    let model: Model
    let state: PanelState

    var body: some View {
        PanelPages(model: model, state: state)
            .modifier(PanelPlate())
            .padding(.top, Bar.gap)
            .padding([.horizontal, .bottom], PanelMetrics.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    func page(_ page: Page) -> some View { PanelPages(model: model, state: state).page(page) }
}

struct PanelPlate: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(width: PanelMetrics.width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .barGlass()
    }
}

struct PanelChrome: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(PanelMetrics.padding).modifier(PanelPlate())
    }
}

struct MainPage: View {
    let model: Model
    let state: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Notes(model: model)
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                DeviceTabs(devices: model.outputs, selected: model.defaultOutput) { model.selectOutput($0) }
                Spacer(minLength: 0)
                PercentText(percent: Int((model.outputVolume * 100).rounded()))
            }
            TickRuler(kind: .plain, value: model.outputVolume, enabled: model.outputSettable,
                      onEditing: { model.draggingOutput($0) }) { model.setOutputVolume($0) }
            .padding(.top, 3)

            Hairline().padding(.top, 11)

            PageStack(current: model.apps.isEmpty ? "empty" : "apps") {
                if model.apps.isEmpty {
                    Text("Nothing is playing")
                        .font(.system(size: UI.empty))
                        .foregroundStyle(.white.opacity(0.38))
                        .padding(.top, 22)
                        .padding(.bottom, 22 - (model.micActive ? UI.rowGap : PanelMetrics.padding))
                        .frame(maxWidth: .infinity)
                        .layoutValue(key: PageStack.Key.self, value: "empty")
                        .transition(.fadeThrough)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.apps) { row in
                            AppRowView(model: model, row: row) { state.page = .app(row.key) }
                                .equatable()
                                .padding(.top, UI.rowGap)
                                .transition(.row)
                        }
                    }
                    .layoutValue(key: PageStack.Key.self, value: "apps")
                    .transition(.fadeThrough)
                }
            }

            if model.micActive {
                Hairline().padding(.top, UI.rowGap).transition(.opacity)
                MicSection(model: model).padding(.top, UI.sectionGap).transition(.row)
            }
        }
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5)
            .padding(.horizontal, -PanelMetrics.padding)
    }
}

struct DeviceTabs: View {
    let devices: [AudioDevice]
    let selected: AudioObjectID
    var bounded = false
    let pick: (AudioObjectID) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            if bounded {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) { row.padding(.horizontal, 12) }
                        .onChange(of: selected, initial: true) { withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo(selected, anchor: .center) } }
                }
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.07),
                                             .init(color: .black, location: 0.93), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
            } else {
                ScrollView(.horizontal, showsIndicators: false) { row }.scrollClipDisabled()
            }
        }
        .frame(height: UI.tabsHeight)
    }

    private var row: some View {
        HStack(alignment: .lastTextBaseline, spacing: 14) {
            ForEach(devices) { d in
                Tab(title: d.shortName, on: d.id == selected, size: UI.tab, onSize: UI.tabOn)
                    .help(d.name)
                    .onTapGesture { pick(d.id) }
                    .id(d.id)
            }
        }
        .fixedSize()
    }
}

struct Tab: View {
    let title: String
    let on: Bool
    var size: CGFloat = UI.tab
    var onSize: CGFloat = UI.tab
    @State private var hover = false

    var body: some View {
        Text(title)
            .font(.system(size: on ? onSize : size, weight: on ? .semibold : .regular))
            .tracking(on ? -0.2 : 0)
            .foregroundStyle(.white.opacity(on ? 1 : (hover ? 0.7 : 0.42)))
            .lineLimit(1)
            .padding(.bottom, 7)
            .overlay(alignment: .bottom) {
                if on {
                    Capsule().fill(.white).frame(width: 14, height: 2.6)
                        .shadow(color: .white.opacity(0.6), radius: 3)
                        .transition(.opacity.combined(with: .scale))
                }
            }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .animation(.smooth(duration: 0.22), value: on)
    }
}

struct AppRowView: View, Equatable {
    let model: Model
    let row: AppRow
    let open: () -> Void
    @State private var hover = false

    nonisolated static func == (a: AppRowView, b: AppRowView) -> Bool { a.row == b.row }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(nsImage: model.icon(row.key)).resizable().interpolation(.high).frame(width: UI.icon, height: UI.icon)
                Text(row.name)
                    .font(.system(size: UI.name, weight: .semibold))
                    .tracking(-0.2)
                    .lineLimit(1)
                if row.inCall {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .help("In a call — Tune leaves it alone until the call ends")
                }
                if let preset = row.presetName {
                    Text(preset)
                        .font(.system(size: UI.label, weight: .regular))
                        .foregroundStyle(.white.opacity(hover ? 0.72 : 0.42))
                        .lineLimit(1)
                        .padding(.leading, -3)
                } else if hover {
                    Image(systemName: "slider.vertical.3")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .transition(.opacity)
                }
                Spacer(minLength: 6)
                PercentText(percent: Level.percent(ofGain: row.gain), boosted: row.gain > 1.0005)
            }
            .opacity(row.playing || hover ? 1 : UI.idle)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(perform: open)
            .animation(.smooth(duration: 0.18), value: hover)
            .animation(.smooth(duration: 0.4), value: row.playing)

            TickRuler(kind: .level, value: Double(row.gain), onEditing: { model.setDragging(row.key, $0) }) { model.setGain(row.key, $0) }
        }
    }
}

struct MicSection: View {
    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 10) {
                Text(Image(systemName: "mic.fill"))
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: UI.icon)
                    .padding(.bottom, 7)
                DeviceTabs(devices: model.inputs, selected: model.defaultInput, bounded: true) { model.selectInput($0) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                PercentText(percent: Int((model.inputVolume * 100).rounded()))
                    .padding(.bottom, 7)
            }
            TickRuler(kind: .plain, value: model.inputVolume, enabled: model.inputSettable,
                      onEditing: { model.draggingInput($0) }) { model.setInputVolume($0) }
        }
    }
}

struct Notes: View {
    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.permission != .granted {
                note("Allow Tune to hear apps, so it can change their sound.", button: "Allow") {
                    model.engine.requestPermission()
                }
            } else if model.captureFailing {
                note("Tune hears only silence. Check Screen & System Audio Recording in Privacy settings.", button: "Retry") {
                    CapturePermission.openSettings()
                    model.engine.retryCapture()
                }
            }
            if model.fineTuneRunning {
                note("FineTune is running, so Tune leaves app sound alone.", button: "Quit FineTune") { model.quitFineTune() }
            }
        }
        .padding(.bottom, model.permission != .granted || model.captureFailing || model.fineTuneRunning ? 13 : 0)
    }

    private func note(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(text)
                .font(.system(size: UI.note))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(button, action: action)
                .buttonStyle(.plain)
                .font(.system(size: UI.note, weight: .semibold))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(0.12)))
        }
    }
}

struct AppPage: View {
    let model: Model
    let key: String
    let back: () -> Void

    var body: some View {
        let row = model.row(key)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 16, height: UI.icon)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Image(nsImage: model.icon(key)).resizable().interpolation(.high).frame(width: UI.icon, height: UI.icon)
                Text(row?.name ?? model.settings.prefs(key).name ?? key)
                    .font(.system(size: UI.title, weight: .semibold))
                    .tracking(-0.3)
                    .lineLimit(1)
                Spacer(minLength: 6)
                PercentText(percent: Level.percent(ofGain: row?.gain ?? 1), boosted: (row?.gain ?? 1) > 1.0005)
            }
            TickRuler(kind: .level, value: Double(row?.gain ?? 1), onEditing: { model.setDragging(key, $0) }) { model.setGain(key, $0) }
                .padding(.top, 3)
            PresetChips(model: model, key: key, selected: row?.presetID)
                .padding(.top, 13)
            EQField(gains: model.curve(key), onEditing: { model.setDragging(key, $0) }) { band, gain in model.setBand(key, band, gain) }
                .padding(.top, 13)
        }
        .onAppear { model.pinnedKey = key }
        .onDisappear { if model.pinnedKey == key { model.pinnedKey = nil } }
    }
}

struct PresetChips: View {
    let model: Model
    let key: String
    let selected: UUID?
    @State private var renaming: UUID?
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }.scrollClipDisabled()
        }
        .frame(height: UI.tabsHeight)
        .onChange(of: focused) { _, now in if !now, renaming != nil { finishRename() } }
    }

    private var row: some View {
        HStack(alignment: .lastTextBaseline, spacing: 15) {
            Tab(title: "Off", on: selected == nil).onTapGesture { model.selectPreset(key, nil) }
            ForEach(model.presets) { preset in
                if renaming == preset.id {
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: UI.tab, weight: .semibold))
                        .frame(width: 100)
                        .focused($focused)
                        .onSubmit { finishRename() }
                        .padding(.bottom, 7)
                        .onExitCommand { renaming = nil }
                } else {
                    Tab(title: preset.name, on: selected == preset.id)
                        .onTapGesture { model.selectPreset(key, preset.id) }
                        .contextMenu {
                            Button("Rename…") { startRename(preset) }
                            Button("Delete", role: .destructive) { model.delete(preset.id) }
                        }
                }
            }
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
                .padding(.bottom, 7)
                .contentShape(Rectangle())
                .onTapGesture {
                    let id = model.newPreset(for: key)
                    if let preset = model.presets.first(where: { $0.id == id }) { startRename(preset) }
                }
                .help("New preset from this curve")
        }
        .fixedSize()
    }

    private func startRename(_ preset: Preset) {
        draft = preset.name
        renaming = preset.id
        DispatchQueue.main.async { focused = true }
    }

    private func finishRename() {
        if let id = renaming { model.rename(id, draft) }
        renaming = nil
    }
}
