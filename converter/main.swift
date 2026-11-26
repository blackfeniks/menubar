import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

enum En {
    static func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    static func files(_ n: Int) -> String { count(n, "file", "files") }

    static func bytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(value)
        var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        let digits = i <= 1 || v >= 10 ? 0 : 1
        return "\(String(format: "%.\(digits)f", v)) \(units[i])"
    }
}

extension PhotoSize {
    init(stored: String?) {
        let parts = (stored ?? "").split(separator: ":")
        switch (parts.first, parts.count == 2 ? Int(parts[1]) : nil) {
        case ("mb", let n?): self = .megabytes(n)
        case ("px", let n?): self = .longSide(n)
        default: self = .keep
        }
    }

    var stored: String {
        switch self {
        case .keep, .percent: return "keep"
        case .megabytes(let n): return "mb:\(n)"
        case .longSide(let n): return "px:\(n)"
        }
    }

    static let megabyteChoices = [1, 2, 3, 5, 10]
    static let sideChoices = [3840, 2560, 1920, 1280]

    static let choices: [PhotoSize] = [.keep] + megabyteChoices.map { .megabytes($0) } + sideChoices.map { .longSide($0) }

    var title: String {
        switch self {
        case .keep: return "Keep"
        case .megabytes(let n): return "Up to \(n) MB"
        case .longSide(let n): return "Up to \(n) px"
        case .percent(let n): return "\(n) %"
        }
    }
}

@MainActor
final class Model: ObservableObject {
    enum Stage { case empty, scanning, ready, running, done }
    enum Badge { case none, done, errors }

    @Published private(set) var stage: Stage = .empty
    @Published private(set) var items: [Item] = []
    @Published private(set) var ignored = 0
    @Published private(set) var folderName: String?

    @Published var format: PhotoFormat { didSet { defaults.set(format.rawValue, forKey: "format") } }
    @Published var size: PhotoSize {
        didSet {
            defaults.set(size.stored, forKey: "size")
            if case .megabytes = size, !(oldValue.isMegabytes) { format = .jpeg }
        }
    }
    @Published var video: VideoMode { didSet { defaults.set(video.rawValue, forKey: "video") } }
    @Published var trash: Bool { didSet { defaults.set(trash, forKey: "trash") } }
    @Published var usePhotos = true
    @Published var useVideos = true

    @Published private(set) var finished = 0
    @Published private(set) var total = 0
    @Published private(set) var videoFraction = 0.0
    @Published private(set) var stopping = false
    @Published private(set) var outcomes: [Outcome] = []
    @Published private(set) var ranRecipe = Recipe()
    @Published private(set) var stopped = false
    @Published private(set) var badge: Badge = .none

    var onIconChange: (() -> Void)?
    var onFinished: (() -> Void)?

    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var scanID = 0
    private var scanTask: Task<Void, Never>?
    private(set) var panelVisible = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        format = PhotoFormat(rawValue: defaults.string(forKey: "format") ?? "") .flatMap { $0 == .keep ? nil : $0 } ?? .jpeg
        size = PhotoSize(stored: defaults.string(forKey: "size"))
        video = VideoMode(rawValue: defaults.string(forKey: "video") ?? "").flatMap { $0 == .keep ? nil : $0 } ?? .mp4
        trash = defaults.bool(forKey: "trash")
    }

    var photos: [Item] { items.filter { $0.kind == .photo } }
    var videos: [Item] { items.filter { $0.kind == .video } }
    var hasPhotos: Bool { items.contains { $0.kind == .photo } }
    var hasVideos: Bool { items.contains { $0.kind == .video } }
    var isMixed: Bool { hasPhotos && hasVideos }
    var isRunning: Bool { stage == .running }

    func load(_ urls: [URL]) {
        guard !isRunning, !urls.isEmpty else { return }
        scanID += 1
        let id = scanID
        let fm = FileManager.default
        var isDir: ObjCBool = false
        folderName = urls.count == 1 && fm.fileExists(atPath: urls[0].path, isDirectory: &isDir) && isDir.boolValue
            ? urls[0].lastPathComponent : nil
        items = []
        ignored = 0
        outcomes = []
        usePhotos = true
        useVideos = true
        stage = .scanning
        scanTask?.cancel()
        scanTask = Task.detached(priority: .userInitiated) {
            let (items, ignored) = Scan.items(from: urls)
            await MainActor.run { [weak self] in
                guard let self, self.scanID == id else { return }
                self.items = items
                self.ignored = ignored
                self.stage = .ready
            }
        }
    }

    func clear() {
        guard !isRunning else { return }
        scanID += 1
        scanTask?.cancel()
        scanTask = nil
        items = []
        ignored = 0
        folderName = nil
        outcomes = []
        stage = .empty
        setBadge(.none)
    }

    var recipe: Recipe {
        let photos = hasPhotos && (usePhotos || !isMixed)
        let videos = hasVideos && (useVideos || !isMixed)
        return Recipe(format: photos ? format : .keep, size: photos ? size : .keep,
                      video: videos ? video : .keep, trashOriginals: trash)
    }

    enum Plan { case work(String), skip(String) }

    func plan(_ item: Item, _ recipe: Recipe) -> Plan? {
        let base = item.url.deletingPathExtension().lastPathComponent
        switch item.kind {
        case .photo:
            guard recipe.touchesPhotos else { return nil }
            let target: UTType = recipe.format == .png ? .png : .jpeg
            let same = Photo.isAlready(target, type: item.type, url: item.url)
            let long = max(item.width, item.height)
            switch recipe.size {
            case .keep where same:
                return .skip("already \(Photo.displayName(target))")
            case .megabytes(let mb) where same && item.bytes <= Int64(mb) * 1_000_000:
                return .skip("already under \(mb) MB")
            case .longSide(let px) where same && long > 0 && long <= px:
                return .skip("already \(px) px or smaller")
            default:
                return .work(base + Naming.suffix(for: recipe.size) + "." + Photo.ext(for: target))
            }
        case .video:
            guard recipe.touchesVideos else { return nil }
            let isMP4 = item.url.pathExtension.lowercased() == "mp4"
            if recipe.video == .mp4 && isMP4 { return .skip("already MP4") }
            return .work(base + Naming.suffix(for: recipe.video) + ".mp4")
        }
    }

    struct Preview {
        var work = 0
        var skipReasons: [String] = []
        var skips = 0
    }

    var preview: Preview {
        let recipe = self.recipe
        var p = Preview()
        for item in items {
            switch plan(item, recipe) {
            case .work?:
                p.work += 1
            case .skip(let why)?:
                p.skips += 1
                if !p.skipReasons.contains(why) { p.skipReasons.append(why) }
            case nil:
                break
            }
        }
        return p
    }

    var compresses: Bool {
        let r = recipe
        return r.size != .keep || r.video == .p1080 || r.video == .p720
    }
    var verb: String { compresses ? "Compress" : "Convert" }
    var verbRunning: String { compresses ? "Compressing" : "Converting" }

    func start() {
        guard stage == .ready else { return }
        let recipe = self.recipe
        let work = items.filter {
            if case .work? = plan($0, recipe) { return true }
            if case .skip? = plan($0, recipe) { return true }
            return false
        }
        guard preview.work > 0 else { return }
        ranRecipe = recipe
        outcomes = []
        finished = 0
        total = work.count
        videoFraction = 0
        stopped = false
        stopping = false
        stage = .running
        setBadge(.none)
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Converting files")
        task = Task { [weak self] in
            let results = await Engine.run(work, recipe) { event in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
            }
            self?.finish(results)
        }
    }

    func stop() {
        guard isRunning else { return }
        stopping = true
        stopped = true
        task?.cancel()
    }

    private func handle(_ event: Engine.Event) {
        guard stage == .running else { return }
        switch event {
        case .finished:
            finished += 1
            videoFraction = 0
        case .videoProgress(let f):
            let step = (f * 24).rounded(.down) / 24
            guard step != videoFraction else { return }
            videoFraction = step
        }
        onIconChange?()
    }

    private func finish(_ results: [Outcome]) {
        let order = Dictionary(items.enumerated().map { ($1.url, $0) }, uniquingKeysWith: { first, _ in first })
        outcomes = results.sorted { (order[$0.source] ?? 0) < (order[$1.source] ?? 0) }
        task = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        stopping = false
        stage = .done
        if !panelVisible { setBadge(errors.isEmpty ? .done : .errors) }
        if let done = onFinished {
            onFinished = nil
            done()
        }
    }

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, (Double(finished) + videoFraction) / Double(total))
    }

    var outputs: [URL] { outcomes.compactMap(\.output) }
    var errors: [Outcome] {
        outcomes.filter { if case .failed(let why) = $0.status { return why != "stopped" } else { return false } }
    }
    var skipped: [Outcome] { outcomes.filter { if case .skipped = $0.status { return true } else { return false } } }

    func panelOpened() {
        panelVisible = true
        if badge != .none { setBadge(.none) }
    }

    func panelClosed() {
        panelVisible = false
    }

    private func setBadge(_ value: Badge) {
        badge = value
        onIconChange?()
    }

    func fake(items: [Item], folder: String? = nil, ignored: Int = 0) {
        self.items = items
        self.folderName = folder
        self.ignored = ignored
        stage = .ready
    }

    func fakeRunning(finished: Int, of total: Int) {
        self.finished = finished
        self.total = total
        ranRecipe = recipe
        stage = .running
    }

    func fakeDone(_ outcomes: [Outcome], stopped: Bool = false) {
        ranRecipe = recipe
        self.outcomes = outcomes
        self.stopped = stopped
        stage = .done
    }
}

private extension PhotoSize {
    var isMegabytes: Bool { if case .megabytes = self { return true } else { return false } }
}

struct PanelView: View {
    @ObservedObject var model: Model
    let choices: BarChoices
    var choose: () -> Void = {}
    var reveal: ([URL]) -> Void = { _ in }
    @State private var dropTargeted = false

    static let width: CGFloat = 320
    static let spare: CGFloat = 240

    var body: some View {
        content
            .font(.system(size: Bar.text))
            .foregroundStyle(Bar.t1)
            .padding(Bar.padding)
            .frame(width: Self.width, alignment: .topLeading)
            .barChoices(choices, width: Self.width)
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: Bar.corner - 4, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.5), lineWidth: 1.5)
                        .padding(4)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !model.isRunning else { return false }
                model.load(urls)
                return true
            } isTargeted: { dropTargeted = $0 && !model.isRunning }
            .animation(.smooth(duration: 0.3), value: model.stage)
            .animation(.smooth(duration: 0.3), value: model.items.count)
    }

    @ViewBuilder private var content: some View {
        switch model.stage {
        case .empty: emptyView.transition(Self.swap)
        case .scanning: scanningView.transition(Self.swap)
        case .ready:
            if model.items.isEmpty { nothingView.transition(Self.swap) } else { readyView.transition(Self.swap) }
        case .running: runningView.transition(Self.swap)
        case .done: doneView.transition(Self.swap)
        }
    }

    private static let swap = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.1)),
        removal: .opacity.animation(.easeIn(duration: 0.08)))

    private static let small = Font.system(size: Bar.small)

    private var emptyView: some View {
        Button(action: choose) {
            Image(systemName: "plus")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Bar.t2)
                .frame(maxWidth: .infinity)
                .frame(height: 104)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-Bar.padding)
    }

    private var scanningView: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Looking at the files…").foregroundStyle(Bar.t2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Bar.row)
    }

    private var nothingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(title: model.folderName ?? En.files(model.ignored), subtitle: nil)
            Text(model.folderName == nil ? "Not a photo or a video" : "No photos or videos here (subfolders are not searched)")
                .foregroundStyle(Bar.t2)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Choose", action: choose).buttonStyle(BarButtonStyle())
            }
        }
    }

    private var readyView: some View {
        let preview = model.preview
        return VStack(alignment: .leading, spacing: 12) {
            header(title: setTitle, subtitle: setSubtitle)
            if model.ignored > 0 {
                Text("\(En.count(model.ignored, "file doesn't", "files don't")) fit: skipped")
                    .font(Self.small)
                    .foregroundStyle(Bar.t3)
                    .padding(.top, -8)
            }
            BarLine()
            settings
            BarLine()
            HStack(spacing: 10) {
                if preview.work == 0 {
                    Text(nothingToDo(preview)).font(Self.small).foregroundStyle(Bar.t3).lineLimit(2)
                }
                Spacer(minLength: 0)
                Button(model.verb, action: model.start)
                    .buttonStyle(BarButtonStyle(prominent: true))
                    .disabled(preview.work == 0)
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.hasPhotos {
                let off = model.isMixed && !model.usePhotos
                row(model.isMixed ? "Photos" : "Format", isOn: model.isMixed ? $model.usePhotos : nil) {
                    BarSegments(options: [(.jpeg, "JPEG"), (.png, "PNG")], selection: $model.format, disabled: off)
                }
                BarChoiceRow(title: "Size", value: model.size.title, id: "size", choices: choices, disabled: off) {
                    choices.show("size", titles: PhotoSize.choices.map(\.title), checked: PhotoSize.choices.firstIndex(of: model.size),
                                 panelWidth: Self.width) { model.size = PhotoSize.choices[$0] }
                }
            }
            if model.hasVideos {
                row(model.isMixed ? "Videos" : "Video", isOn: model.isMixed ? $model.useVideos : nil) {
                    BarSegments(options: [(.mp4, "MP4"), (.p1080, "1080p"), (.p720, "720p")], selection: $model.video,
                                disabled: model.isMixed && !model.useVideos)
                }
            }
            BarRow(title: "Delete originals") { BarSwitch(isOn: $model.trash) }
        }
    }

    private func row<C: View>(_ title: String, isOn: Binding<Bool>?, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 0) {
            if let isOn {
                HStack(spacing: 6) {
                    Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(isOn.wrappedValue ? Bar.t1 : Bar.t3)
                    Text(title).lineLimit(1).fixedSize()
                }
                .contentShape(Rectangle())
                .onTapGesture { isOn.wrappedValue.toggle() }
            } else {
                Text(title).lineLimit(1).fixedSize()
            }
            Spacer(minLength: 12)
            control()
        }
        .frame(height: Bar.row)
    }

    private var setTitle: String {
        if let folder = model.folderName { return folder }
        if model.items.count == 1 { return model.items[0].url.lastPathComponent }
        return kinds
    }

    private var setSubtitle: String {
        let bytes = En.bytes(model.items.reduce(0) { $0 + $1.bytes })
        if model.items.count == 1, let item = model.items.first {
            return item.kind == .photo && item.width > 0 ? "\(bytes) · \(item.width)×\(item.height)" : bytes
        }
        return model.folderName != nil ? "\(kinds) · \(bytes)" : bytes
    }

    private var kinds: String {
        let p = model.photos.count, v = model.videos.count
        return [p > 0 ? En.count(p, "photo", "photos") : nil, v > 0 ? En.count(v, "video", "videos") : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private func skipSummary(_ reasons: [String]) -> String {
        reasons.count == 1 ? reasons[0] : "already as asked"
    }

    private func nothingToDo(_ p: Model.Preview) -> String {
        let r = model.recipe
        if !r.touchesPhotos && !r.touchesVideos { return "Nothing chosen" }
        return "Nothing to do: \(skipSummary(p.skipReasons))"
    }

    private var runningView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.stopping ? "Stopping…" : "\(model.verbRunning)… \(model.finished) of \(model.total)")
                .font(.system(size: Bar.title, weight: .semibold))
                .monospacedDigit()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(Color.white.opacity(0.88))
                        .frame(width: max(4, geo.size.width * model.fraction))
                        .animation(.smooth(duration: 0.3), value: model.fraction)
                }
            }
            .frame(height: 4)
            HStack {
                Spacer()
                Button("Stop", action: model.stop)
                    .buttonStyle(BarButtonStyle())
                    .disabled(model.stopping)
            }
        }
    }

    private var doneView: some View {
        let errors = model.errors
        let outputs = model.outputs
        let done = model.outcomes.filter { $0.output != nil }
        let bytesIn = done.reduce(0) { $0 + $1.bytesIn }
        let bytesOut = done.reduce(0) { $0 + $1.bytesOut }
        let skipped = model.skipped
        let trashed = model.ranRecipe.trashOriginals ? done.filter { !$0.originalKept }.count : 0
        let kept = Self.grouped(done.compactMap(\.keptReason))
        let notes = Self.grouped(done.compactMap(\.note))
        let reencoded = done.filter(\.reencoded).count

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(errors.isEmpty ? Bar.t1 : Bar.red)
                Text(doneTitle(errors: errors.count)).font(.system(size: Bar.title, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 3) {
                if !done.isEmpty {
                    Text("\(En.bytes(bytesIn)) → \(En.bytes(bytesOut))").monospacedDigit()
                }
                if !skipped.isEmpty {
                    let reasons = skipped.compactMap { if case .skipped(let why) = $0.status { return why } else { return nil } }
                    let distinct = Self.grouped(reasons).map(\.text)
                    Text("\(skipped.count) skipped: \(distinct.prefix(2).joined(separator: ", "))\(distinct.count > 2 ? "…" : "")")
                        .foregroundStyle(Bar.t2)
                }
                if trashed > 0 {
                    Text(En.count(trashed, "original in the Trash", "originals in the Trash")).foregroundStyle(Bar.t2)
                }
                ForEach(kept, id: \.text) { group in
                    Text("\(En.count(group.count, "original kept", "originals kept")): \(group.text)").foregroundStyle(Bar.t2)
                }
                if reencoded > 0 {
                    Text("\(En.count(reencoded, "video", "videos")) re-encoded: MP4 can't hold it as it is").foregroundStyle(Bar.t2)
                }
                ForEach(notes, id: \.text) { group in
                    Text("\(En.count(group.count, "video", "videos")): \(group.text)").foregroundStyle(Bar.t2)
                }
                if !errors.isEmpty {
                    ForEach(errors.prefix(3), id: \.source) { outcome in
                        Button {
                            reveal([outcome.source])
                        } label: {
                            HStack(spacing: 0) {
                                Text(outcome.source.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Text(": \(failure(outcome))").lineLimit(1).layoutPriority(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if errors.count > 3 {
                        Text("and \(errors.count - 3) more").foregroundStyle(Bar.t2)
                    }
                    Text(errors.count == 1 ? "Its original is untouched" : "Their originals are untouched").foregroundStyle(Bar.t2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if !outputs.isEmpty {
                HStack {
                    Spacer()
                    Button("Show in Finder") { reveal(outputs) }.buttonStyle(BarButtonStyle(prominent: true))
                }
            }
        }
    }

    static func grouped(_ texts: [String]) -> [(text: String, count: Int)] {
        var out: [(text: String, count: Int)] = []
        for t in texts {
            if let i = out.firstIndex(where: { $0.text == t }) { out[i].count += 1 } else { out.append((t, 1)) }
        }
        return out
    }

    private func doneTitle(errors: Int) -> String {
        let total = model.outcomes.count
        if model.stopped { return "Stopped · \(model.outputs.count) of \(model.total)" }
        if errors > 0 { return "Done \(total - errors) of \(total)" }
        return "Done · \(En.files(total))"
    }

    private func failure(_ outcome: Outcome) -> String {
        if case .failed(let why) = outcome.status { return why }
        return ""
    }

    private func header(title: String, subtitle: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: Bar.title, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle).font(Self.small).foregroundStyle(Bar.t3).monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: model.clear) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Bar.t3)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

enum Icon {
    static func symbol(_ name: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Converter")?.withSymbolConfiguration(config)
            ?? NSImage(systemSymbolName: "photo", accessibilityDescription: "Converter")!
        image.isTemplate = true
        return image
    }

    static func progress(_ fraction: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let ring = rect.insetBy(dx: 2.5, dy: 2.5)
            NSColor.black.setStroke()
            let circle = NSBezierPath(ovalIn: ring)
            circle.lineWidth = 1.5
            circle.stroke()
            let f = max(0.04, min(1, fraction))
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let pie = NSBezierPath()
            pie.move(to: center)
            pie.appendArc(withCenter: center, radius: ring.width / 2 - 2, startAngle: 90, endAngle: 90 - 360 * f, clockwise: true)
            pie.close()
            NSColor.black.setFill()
            pie.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = Model()
    private var statusItem: NSStatusItem!
    private var panel: BarPanel!
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Converter: drop photos, videos or a folder here"
        button.window?.registerForDraggedTypes([.fileURL])
        button.window?.delegate = self
        panel = BarPanel(statusItem: statusItem)

        model.onIconChange = { [weak self] in self?.updateIcon() }
        updateIcon()

        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        sigterm = term
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        switch (model.stage, model.badge) {
        case (.running, _): button.image = Icon.progress(model.fraction)
        case (_, .done): button.image = Icon.symbol("checkmark.circle")
        case (_, .errors): button.image = Icon.symbol("exclamationmark.triangle")
        default: button.image = Icon.symbol("photo.on.rectangle")
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            panel.toggle { makeContent() }
        }
    }

    private func showMenu() {
        panel.close(animated: false)
        let menu = NSMenu()
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: model.isRunning ? "Stop and quit" : "Quit Converter",
                              action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login items"
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
        }
    }

    private func makeContent() -> BarContent {
        model.panelOpened()
        let choices = BarChoices()
        var content = BarContent(width: PanelView.width, spare: PanelView.spare) {
            PanelView(model: model, choices: choices,
                      choose: { [weak self] in self?.choose() },
                      reveal: { urls in NSWorkspace.shared.activateFileViewerSelecting(Array(urls.prefix(500))) })
        }
        content.onCancel = {
            guard choices.open != nil else { return false }
            choices.dismiss()
            return true
        }
        content.onKey = { [weak self] event in self?.key(event) ?? false }
        content.staysForDrags = true
        content.onClose = { [model] in
            model.panelClosed()
            if model.stage == .done { model.clear() }
        }
        return content
    }

    private func showPanel() {
        if !panel.isOpen { panel.open(makeContent()) }
    }

    private func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .command {
            switch event.keyCode {
            case 9, 31, 12:
                guard !event.isARepeat else { return true }
                switch event.keyCode {
                case 9: paste()
                case 31: choose()
                default: quit()
                }
                return true
            case 47:
                model.stop()
                return true
            default:
                return false
            }
        }
        guard flags.isEmpty else { return false }
        switch event.keyCode {
        case 51, 117:
            model.clear()
            return true
        case 36, 76:
            guard !event.isARepeat else { return true }
            switch model.stage {
            case .empty: choose()
            case .ready: if model.items.isEmpty { choose() } else { model.start() }
            case .done: if !model.outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(Array(model.outputs.prefix(500))) }
            case .scanning, .running: break
            }
            return true
        default:
            return false
        }
    }

    private func paste() {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                    options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        model.load(urls)
    }

    func choose() {
        guard !model.isRunning else { return }
        let front = NSWorkspace.shared.frontmostApplication
        panel.close(animated: false)
        NSApp.activate()
        let open = NSOpenPanel()
        open.canChooseFiles = true
        open.canChooseDirectories = true
        open.allowsMultipleSelection = true
        open.prompt = "Choose"
        open.message = "Photos, videos or a folder"
        if open.runModal() == .OK {
            model.load(open.urls)
        }
        returnFocus(to: front) { [weak self] in self?.showPanel() }
    }

    private func returnFocus(to app: NSRunningApplication?, then: @escaping @MainActor () -> Void) {
        guard let app, !app.isTerminated, app.processIdentifier != getpid() else { return then() }
        let wait = FocusReturn(then)
        let pid = app.processIdentifier
        wait.token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard activated?.processIdentifier == pid else { return }
            MainActor.assumeIsolated { wait.finish() }
        }
        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { wait.finish() } }
    }

    @MainActor private final class FocusReturn {
        var token: NSObjectProtocol?
        private var then: (@MainActor () -> Void)?

        init(_ then: @escaping @MainActor () -> Void) { self.then = then }

        func finish() {
            guard let then else { return }
            self.then = nil
            if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
            DispatchQueue.main.async { MainActor.assumeIsolated { then() } }
        }
    }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private var dropAccepted = false

    @objc func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropAccepted = !model.isRunning && sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        guard dropAccepted else { return [] }
        statusItem.button?.highlight(true)
        return .copy
    }

    @objc func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropAccepted && !model.isRunning ? .copy : []
    }

    @objc func draggingExited(_ sender: NSDraggingInfo?) {
        statusItem.button?.highlight(panel.isOpen)
    }

    @objc func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !model.isRunning
    }

    @objc func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !model.isRunning, !urls.isEmpty else {
            statusItem.button?.highlight(panel.isOpen)
            return false
        }
        model.load(urls)
        DispatchQueue.main.async { self.showPanel() }
        return true
    }

    @objc func draggingEnded(_ sender: NSDraggingInfo) {
        statusItem.button?.highlight(panel.isOpen)
    }

    @objc func quit() {
        if model.isRunning {
            model.onFinished = { NSApp.terminate(nil) }
            model.stop()
        } else {
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.isRunning { model.stop() }
        Files.removeUnfinished()
        return .terminateNow
    }
}

enum CLI {
    static func handle(_ args: [String]) -> Int32? {
        guard args.count > 1 else { return nil }
        switch args[1] {
        case "--run": return run(Array(args.dropFirst(2)))
        case "--snapshot":
            guard args.count > 2 else { return 2 }
            MainActor.assumeIsolated { Snapshot.render(to: args[2]) }
            return 0
        default: return nil
        }
    }

    static func run(_ args: [String]) -> Int32 {
        var recipe = Recipe()
        var paths: [URL] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            func value() -> String { i += 1; return i < args.count ? args[i] : "" }
            switch a {
            case "--format": recipe.format = PhotoFormat(rawValue: value()) ?? .keep
            case "--size":
                let v = value().lowercased()
                if v.hasSuffix("mb"), let n = Int(v.dropLast(2)) { recipe.size = .megabytes(n) }
                else if v.hasSuffix("px"), let n = Int(v.dropLast(2)) { recipe.size = .longSide(n) }
                else if v.hasSuffix("%"), let n = Int(v.dropLast(1)) { recipe.size = .percent(n) }
            case "--video":
                switch value() {
                case "mp4": recipe.video = .mp4
                case "1080": recipe.video = .p1080
                case "720": recipe.video = .p720
                default: break
                }
            case "--trash": recipe.trashOriginals = true
            default: paths.append(URL(fileURLWithPath: a))
            }
            i += 1
        }
        let (items, ignored) = Scan.items(from: paths)
        print("\(items.count) items, \(ignored) ignored")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failures = 0
        Task.detached {
            let outcomes = await Engine.run(items, recipe) { event in
                guard case .finished(let o) = event else { return }
                switch o.status {
                case .done(let url):
                    print("✓ \(o.source.lastPathComponent) → \(url.lastPathComponent)  \(En.bytes(o.bytesIn)) → \(En.bytes(o.bytesOut))"
                          + (o.reencoded ? "  [re-encoded]" : "") + (o.note.map { "  [\($0)]" } ?? "") + (o.keptReason.map { "  [original kept: \($0)]" } ?? ""))
                case .skipped(let why): print("– \(o.source.lastPathComponent): \(why)")
                case .failed(let why): print("✗ \(o.source.lastPathComponent): \(why)")
                }
            }
            failures = outcomes.filter { if case .failed = $0.status { return true } else { return false } }.count
            done.signal()
        }
        done.wait()
        return failures == 0 ? 0 : 1
    }
}

@MainActor
enum Snapshot {
    static func render(to dir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Bar.offscreen = true
        let defaults = UserDefaults(suiteName: "converter.snapshot")!
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        func shot(_ name: String, _ build: (Model, BarChoices) -> Void) {
            defaults.removePersistentDomain(forName: "converter.snapshot")
            let model = Model(defaults: defaults)
            let choices = BarChoices()
            let host = NSHostingView(rootView: PanelView(model: model, choices: choices)
                .barGlass()
                .padding(16)
                .background(Color(red: 0.17, green: 0.19, blue: 0.24))
                .environment(\.colorScheme, .dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            for pass in 0..<3 {
                if pass == 1 { build(model, choices) }
                host.layoutSubtreeIfNeeded()
                let size = host.fittingSize
                window.setContentSize(size)
                host.frame = NSRect(origin: .zero, size: size)
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("wrote \(url.lastPathComponent) \(Int(host.bounds.width))x\(Int(host.bounds.height))")
        }

        func photo(_ name: String, _ bytes: Int64, _ w: Int = 4032, _ h: Int = 3024, _ type: UTType = .heic) -> Item {
            Item(url: URL(fileURLWithPath: "/Users/me/Pictures/Trip/\(name)"), kind: .photo, bytes: bytes, type: type, width: w, height: h)
        }
        func clip(_ name: String, _ bytes: Int64) -> Item {
            Item(url: URL(fileURLWithPath: "/Users/me/Pictures/Trip/\(name)"), kind: .video, bytes: bytes, type: .quickTimeMovie)
        }
        let heic = photo("IMG_4021.HEIC", 4_100_000)
        let many = [heic] + (2...48).map { photo("IMG_40\($0 + 21).HEIC", 4_300_000) }

        shot("1-empty") { _, _ in }
        shot("2-one-photo") { m, _ in m.fake(items: [heic]) }
        shot("2b-size-list") { m, choices in
            m.fake(items: [heic])
            choices.frames["size"] = CGRect(x: 16, y: 104, width: 288, height: 26)
            choices.show("size", titles: PhotoSize.choices.map(\.title), checked: 3, panelWidth: PanelView.width) { _ in }
        }
        shot("3-folder-photos-3mb") { m, _ in
            m.size = .megabytes(3)
            m.fake(items: many + [photo("small.jpg", 800_000, 1600, 1200, .jpeg)], folder: "Trip", ignored: 2)
        }
        shot("4-videos") { m, _ in m.fake(items: [clip("clip.MOV", 820_000_000), clip("clip 2.MOV", 400_000_000), clip("old.mp4", 30_000_000)]) }
        shot("5-mixed-trash") { m, _ in
            m.trash = true
            m.fake(items: Array(many.prefix(23)) + [clip("clip.MOV", 820_000_000), clip("b.MOV", 1_000_000)], folder: "Trip")
        }
        shot("6-nothing-to-do") { m, _ in m.fake(items: [photo("photo.jpg", 2_000_000, 4000, 3000, .jpeg)]) }
        shot("7-unsupported-folder") { m, _ in m.fake(items: [], folder: "Documents", ignored: 12) }
        shot("8-running") { m, _ in
            m.size = .megabytes(3)
            m.fake(items: many)
            m.fakeRunning(finished: 7, of: 27)
        }
        let dir = "/Users/me/Pictures/Trip/"
        func out(_ s: String, _ status: Outcome.Status, _ i: Int64, _ o: Int64) -> Outcome {
            Outcome(source: URL(fileURLWithPath: dir + s), status: status, bytesIn: i, bytesOut: o)
        }
        shot("9-done") { m, _ in
            m.trash = true
            m.fake(items: many)
            m.fakeDone((1...24).map { out("IMG_\($0).HEIC", .done(URL(fileURLWithPath: dir + "IMG_\($0).jpg")), 50_000_000, 17_000_000) }
                       + (1...3).map { out("x\($0).jpg", .skipped("already JPEG"), 1, 1) })
        }
        shot("10-done-errors") { m, _ in
            m.fake(items: many)
            m.fakeDone((1...25).map { out("IMG_\($0).HEIC", .done(URL(fileURLWithPath: dir + "IMG_\($0).jpg")), 4_000_000, 2_900_000) }
                       + [out("IMG_0042.DNG", .failed("couldn't read it"), 1, 0),
                          out("clip.mov", .failed("the disk is full"), 1, 0)])
        }
        shot("11-done-kept") { m, _ in
            m.trash = true
            m.fake(items: [clip("clip.MOV", 820_000_000)])
            var a = out("clip.MOV", .done(URL(fileURLWithPath: dir + "clip.mp4")), 820_000_000, 815_000_000)
            a.keptReason = "the MP4 isn't lossless"
            a.note = "audio converted to AAC"
            var b = out("b.MOV", .done(URL(fileURLWithPath: dir + "b.mp4")), 20_000_000, 20_000_000)
            b.keptReason = "the file is locked or access is denied"
            m.fakeDone([a, b, out("c.mp4", .skipped("already MP4"), 1, 1), out("d.mp4", .skipped("wouldn't get smaller"), 1, 1)])
        }
        defaults.removePersistentDomain(forName: "converter.snapshot")
    }
}

if getenv("MallocLargeCache") == nil, let exe = Bundle.main.executablePath {
    setenv("MallocLargeCache", "0", 1)
    execv(exe, CommandLine.unsafeArgv)
}

if let code = CLI.handle(CommandLine.arguments) { exit(code) }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
