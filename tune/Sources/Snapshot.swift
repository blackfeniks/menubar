import AppKit
import CoreAudio
import SwiftUI

@MainActor
enum Snapshot {
    static func run(_ dir: String) -> Int32 {
        Log.toStdout = true
        PanelView.offscreen = true
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("tune-snapshot-\(getpid()).json")
        defer { try? FileManager.default.removeItem(at: temp) }
        let settings = SettingsStore(url: temp)
        let engine = Engine(settings: settings)
        let model = Model(engine: engine)

        func preset(_ name: String) -> Preset? { settings.data.presets.first { $0.name == name } }
        let my3 = preset("my3") ?? settings.addPreset(named: "my3", gains: [-2.7, 6.3, 2.2, -1.9, -3.4, -3.1, -2.7, -0.8, 1.4, 5.6])
        let video = preset("video") ?? settings.addPreset(named: "video", gains: [-2.7, 6.3, 2.2, -4.8, -6.6, -5.5, -6.6, -4.0, 1.4, 8.4])
        settings.select("com.spotify.client", preset: my3.id)
        settings.select("com.apple.Safari", preset: video.id)
        settings.select("ru.keepcoder.Telegram", preset: video.id)
        settings.setGain("com.spotify.client", 0.593)
        settings.setGain("com.apple.Safari", 1.6)
        settings.setGain("ru.keepcoder.Telegram", 1)

        let outputs = [
            AudioDevice(id: 1, uid: "mac", name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn, outputChannels: 2, inputChannels: 0),
            AudioDevice(id: 2, uid: "max", name: "AirPods Max", transport: kAudioDeviceTransportTypeBluetooth, outputChannels: 2, inputChannels: 0),
            AudioDevice(id: 3, uid: "ear", name: "EarPods", transport: kAudioDeviceTransportTypeUSB, outputChannels: 2, inputChannels: 0),
        ]
        let inputs = [
            AudioDevice(id: 11, uid: "earmic", name: "EarPods Microphone", transport: kAudioDeviceTransportTypeUSB, outputChannels: 0, inputChannels: 1),
            AudioDevice(id: 12, uid: "macmic", name: "MacBook Pro Microphone", transport: kAudioDeviceTransportTypeBuiltIn, outputChannels: 0, inputChannels: 1),
        ]
        func row(_ key: String, _ name: String, playing: Bool = true) -> AppRow {
            let p = settings.prefs(key)
            return AppRow(key: key, name: name, gain: p.gain, presetID: p.presetID, presetName: settings.preset(p.presetID)?.name, playing: playing)
        }
        let apps = [row("com.spotify.client", "Spotify"), row("com.apple.Safari", "Safari"), row("ru.keepcoder.Telegram", "Telegram", playing: false)]
        model.loadPreview(outputs: outputs, inputs: inputs, apps: apps, presets: settings.data.presets)

        func render(_ name: String, page: Page) {
            let state = PanelState()
            state.page = page
            let view = PanelView(model: model, state: state)
                .frame(width: PanelMetrics.width + 2 * PanelMetrics.margin)
                .fixedSize(horizontal: false, vertical: true)
                .background(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.10)], startPoint: .top, endPoint: .bottom))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                print("could not render \(name)")
                return
            }
            try? png.write(to: out.appendingPathComponent("\(name).png"))
            print("wrote \(name).png  \(Int(image.size.width))×\(Int(image.size.height))")
        }

        func renderShift(_ name: String, from: Page, to: Page) {
            let panel = PanelView(model: model, state: PanelState())
            let inner = PanelMetrics.width - 2 * PanelMetrics.padding
            func height(_ p: Page) -> CGFloat {
                NSHostingController(rootView: panel.page(p).frame(width: inner).environment(\.colorScheme, .dark))
                    .sizeThatFits(in: CGSize(width: inner, height: 10_000)).height
            }
            let h0 = height(from), h1 = height(to)
            var images: [NSImage] = []
            for e in [0, 0.15, 0.3, 0.45, 0.6, 0.8, 1.0] {
                let frame = ZStack(alignment: .topLeading) {
                    panel.page(from).modifier(PageShift(progress: e, edge: from.edge, leaving: true))
                    panel.page(to).modifier(PageShift(progress: 1 - e, edge: to.edge, leaving: false))
                }
                .frame(width: inner, height: h0 + (h1 - h0) * e, alignment: .topLeading)
                .modifier(PanelChrome())
                .padding(PanelMetrics.margin)
                .frame(height: max(h0, h1) + 2 * PanelMetrics.padding + 2 * PanelMetrics.margin, alignment: .top)
                .background(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.10)], startPoint: .top, endPoint: .bottom))
                .environment(\.colorScheme, .dark)
                let renderer = ImageRenderer(content: frame)
                renderer.scale = 2
                if let image = renderer.nsImage { images.append(image) }
            }
            guard let first = images.first else { return }
            let strip = NSImage(size: NSSize(width: first.size.width * CGFloat(images.count), height: first.size.height))
            strip.lockFocus()
            for (i, image) in images.enumerated() { image.draw(at: NSPoint(x: first.size.width * CGFloat(i), y: 0), from: .zero, operation: .copy, fraction: 1) }
            strip.unlockFocus()
            guard let tiff = strip.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return }
            try? jpg.write(to: out.appendingPathComponent("\(name).jpg"))
            print("wrote \(name).jpg  \(images.count) frames")
        }

        func renderRowReveal(_ name: String) {
            let inner = PanelMetrics.width - 2 * PanelMetrics.padding
            let rows = model.apps
            guard rows.count >= 3 else { return }
            let mid = rows[1]
            func view(_ r: AppRow) -> some View { AppRowView(model: model, row: r) {}.padding(.top, UI.rowGap) }
            let h = NSHostingController(rootView: view(mid).frame(width: inner).environment(\.colorScheme, .dark))
                .sizeThatFits(in: CGSize(width: inner, height: 10_000)).height
            var images: [NSImage] = []
            for e in [0, 0.2, 0.4, 0.6, 0.8, 1.0] {
                let frame = VStack(alignment: .leading, spacing: 0) {
                    view(rows[0])
                    ZStack(alignment: .topLeading) {
                        view(mid).modifier(RowReveal(progress: 1 - e, leaving: false))
                    }
                    .frame(height: h * e, alignment: .top)
                    view(rows[2])
                }
                .frame(width: inner, alignment: .topLeading)
                .modifier(PanelChrome())
                .padding(PanelMetrics.margin)
                .frame(height: 3 * h + 2 * PanelMetrics.padding + 2 * PanelMetrics.margin, alignment: .top)
                .background(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.10)], startPoint: .top, endPoint: .bottom))
                .environment(\.colorScheme, .dark)
                let renderer = ImageRenderer(content: frame)
                renderer.scale = 2
                if let image = renderer.nsImage { images.append(image) }
            }
            guard let first = images.first else { return }
            let strip = NSImage(size: NSSize(width: first.size.width * CGFloat(images.count), height: first.size.height))
            strip.lockFocus()
            for (i, image) in images.enumerated() { image.draw(at: NSPoint(x: first.size.width * CGFloat(i), y: 0), from: .zero, operation: .copy, fraction: 1) }
            strip.unlockFocus()
            guard let tiff = strip.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return }
            try? jpg.write(to: out.appendingPathComponent("\(name).jpg"))
            print("wrote \(name).jpg  \(images.count) frames")
        }

        render("1-main", page: .main)
        render("2-eq-spotify", page: .app("com.spotify.client"))
        render("3-eq-safari-boost", page: .app("com.apple.Safari"))
        model.setPreviewMic(false)
        render("4-main-no-mic", page: .main)
        model.setPreviewMic(true)
        renderRowReveal("9-row-appears")
        renderShift("7-shift-to-safari", from: .main, to: .app("com.apple.Safari"))
        renderShift("8-shift-back", from: .app("com.apple.Safari"), to: .main)
        model.setPreviewState(permission: .denied, fineTune: true)
        render("5-notes", page: .main)
        model.loadPreview(outputs: outputs, inputs: inputs, apps: [], presets: settings.data.presets, mic: false)
        render("6-nothing-playing", page: .main)
        return 0
    }
}
