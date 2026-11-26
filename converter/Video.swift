import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia
import os

enum Video {
    static let mp4Video: Set<FourCharCode> = [fourCC("avc1"), fourCC("avc3"), fourCC("hvc1"), fourCC("hev1"),
                                              fourCC("dvh1"), fourCC("dvhe"), fourCC("mp4v")]
    static let mp4Audio: Set<FourCharCode> = [kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
                                              kAudioFormatAppleLossless, kAudioFormatAC3, kAudioFormatEnhancedAC3]
    static let hevc: Set<FourCharCode> = [fourCC("hvc1"), fourCC("hev1"), fourCC("dvh1"), fourCC("dvhe")]

    static let toAAC = "audio converted to AAC"
    static let noSpatial = "no spatial audio"
    static let lostTracks = "extra tracks didn't fit in MP4"

    static func fourCC(_ s: String) -> FourCharCode {
        s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    static func format(_ track: AVAssetTrack) async -> CMFormatDescription? {
        try? await track.load(.formatDescriptions).first
    }

    static func codec(_ track: AVAssetTrack) async -> FourCharCode? {
        await format(track).map(CMFormatDescriptionGetMediaSubType)
    }

    static func isHDR(_ format: CMFormatDescription?) -> Bool {
        guard let format, let tf = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String else { return false }
        return tf == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
            || tf == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
    }

    static func decodable(_ codec: FourCharCode) -> Bool {
        var id = codec, size: UInt32 = 0
        return codec == kAudioFormatLinearPCM
            || AudioFormatGetPropertyInfo(kAudioFormatProperty_Decoders, UInt32(MemoryLayout.size(ofValue: id)), &id, &size) == noErr
            && size > 0
    }

    static let layouts: [Int: (wav: AudioChannelLayoutTag, aac: AudioChannelLayoutTag)] = [
        3: (kAudioChannelLayoutTag_WAVE_3_0, kAudioChannelLayoutTag_AAC_3_0),
        4: (kAudioChannelLayoutTag_WAVE_4_0_A, kAudioChannelLayoutTag_AAC_Quadraphonic),
        5: (kAudioChannelLayoutTag_WAVE_5_0_A, kAudioChannelLayoutTag_AAC_5_0),
        6: (kAudioChannelLayoutTag_WAVE_5_1_A, kAudioChannelLayoutTag_AAC_5_1),
        7: (kAudioChannelLayoutTag_WAVE_6_1, kAudioChannelLayoutTag_AAC_6_1),
        8: (kAudioChannelLayoutTag_WAVE_7_1, kAudioChannelLayoutTag_AAC_7_1_B)]

    static func layout(_ tag: AudioChannelLayoutTag) -> Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = tag
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }

    static func aac(_ format: CMFormatDescription?) -> (pcm: [String: Any], aac: [String: Any])? {
        guard let format, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return nil }
        let channels = Int(asbd.mChannelsPerFrame)
        var pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM]
        var aac: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: channels,
                                  AVSampleRateKey: min(asbd.mSampleRate, 48_000)]
        if asbd.mSampleRate >= 44_100 { aac[AVEncoderBitRateKey] = 128_000 * channels }
        if channels > 2 {
            guard let tags = layouts[channels] else { return nil }
            aac[AVChannelLayoutKey] = layout(tags.aac)
            if CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: nil) == nil {
                pcm[AVChannelLayoutKey] = layout(tags.wav)
                pcm[AVNumberOfChannelsKey] = channels
            }
        }
        return (pcm, aac)
    }

    static func playable(_ on: [Bool]) -> [Bool] {
        on.isEmpty || on.contains(true) ? on : [true] + on.dropFirst()
    }

    static func metadata(of asset: AVAsset) async -> [AVMetadataItem] {
        var items = (try? await asset.load(.commonMetadata)) ?? []
        if !items.contains(where: { $0.commonKey == .commonKeyCreationDate }),
           let date = try? await asset.load(.creationDate) {
            items.append(date)
        }
        return items
    }

    enum Way { case passthrough, remux, reencode }

    static func process(_ source: URL, _ recipe: Recipe, cancelled: @escaping @Sendable () -> Bool,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> Outcome {
        let bytesIn = Files.size(source)
        let stamp = Files.stamp(source)
        let asset = AVURLAsset(url: source)
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard let main = videoTracks.first else { throw Failure("no video track") }
        let (natural, transform) = try await main.load(.naturalSize, .preferredTransform)
        let shown = CGRect(origin: .zero, size: natural).applying(transform).size
        let long = max(shown.width, shown.height), short = min(shown.width, shown.height)
        let isMP4 = (try? source.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .mpeg4Movie) == true
            && source.pathExtension.lowercased() == "mp4"

        func skip(_ why: String) -> Outcome {
            Outcome(source: source, status: .skipped(why), bytesIn: bytesIn, bytesOut: bytesIn)
        }
        let box: (long: CGFloat, short: CGFloat)? = switch recipe.video {
        case .p1080: (1920, 1080)
        case .p720: (1280, 720)
        default: nil
        }
        let scale = box.map { min(1, $0.long / long, $0.short / short) } ?? 1
        let fitBox = box.map { scale < min(1, $0.long / long) * 0.999 } ?? false
        if scale == 1 && isMP4 {
            return skip(box.map { "already \(Int($0.short))p or smaller" } ?? "already MP4")
        }

        let mainFormat = await format(main)
        let mainCodec = mainFormat.map(CMFormatDescriptionGetMediaSubType) ?? 0
        let copyPicture = scale == 1 && mp4Video.contains(mainCodec)
        var video = [main]
        for track in videoTracks.dropFirst() where copyPicture {
            if let c = await codec(track), mp4Video.contains(c) { video.append(track) }
        }
        var notes: [String] = []
        func note(_ s: String) { if !notes.contains(s) { notes.append(s) } }
        var audio: [(track: AVAssetTrack, encode: Bool)] = []
        for track in (try? await asset.loadTracks(withMediaType: .audio)) ?? [] {
            let c = await codec(track) ?? 0
            if mp4Audio.contains(c) { audio.append((track, false)) }
            else if c == kAudioFormatAPAC { note(noSpatial) }
            else if decodable(c) { audio.append((track, true)) }
            else { note(lostTracks) }
        }

        var ways: [Way] = []
        if copyPicture {
            if !audio.contains(where: \.encode) { ways.append(.passthrough) }
            ways.append(.remux)
        }
        ways.append(.reencode)
        let preset = switch recipe.video {
        case .p1080: AVAssetExportPreset1920x1080
        case .p720: AVAssetExportPreset1280x720
        default: hevc.contains(mainCodec) || isHDR(mainFormat) ? AVAssetExportPresetHEVCHighestQuality
                                                               : AVAssetExportPresetHighestQuality
        }
        let metadata = await metadata(of: asset)

        let tmp = Files.temp(near: source, ext: "mp4")
        var lastError: Error = Failure("couldn't save the MP4")
        var used: (way: Way, notes: [String])?
        for way in ways {
            if cancelled() { Files.remove(tmp); throw CancellationError() }
            try? FileManager.default.removeItem(at: tmp)
            do {
                switch way {
                case .passthrough:
                    let composition = try await composition(video, audio.map(\.track))
                    try await export(composition, AVAssetExportPresetPassthrough, to: tmp, metadata: metadata,
                                     cancelled: cancelled, progress: progress)
                    used = (way, [])
                case .remux:
                    used = (way, try await mux(video, audio, to: tmp, metadata: metadata, cancelled: cancelled, progress: progress))
                case .reencode:
                    used = (way, try await reencode(main, scale: fitBox ? scale : 1, preset: preset, audio: audio, to: tmp, near: source,
                                                    metadata: metadata, cancelled: cancelled, progress: progress))
                }
                break
            } catch {
                if error is CancellationError || cancelled() { Files.remove(tmp); throw CancellationError() }
                lastError = error
            }
        }
        if cancelled() { Files.remove(tmp); throw CancellationError() }
        guard let used else {
            Files.remove(tmp)
            throw (lastError as? Failure) ?? Failure(Engine.reason(lastError))
        }
        guard (try? await AVURLAsset(url: tmp).loadTracks(withMediaType: .video).isEmpty) == false else {
            Files.remove(tmp)
            throw Failure("the result can't be read")
        }
        if box != nil && used.way == .reencode && Files.size(tmp) >= bytesIn {
            Files.remove(tmp)
            return skip("wouldn't get smaller")
        }

        used.notes.forEach(note)
        if (used.way == .reencode ? 1 : video.count) < videoTracks.count { note(lostTracks) }
        let lossless = used.way != .reencode && notes.isEmpty
        let trash = recipe.trashOriginals && (recipe.video != .mp4 || lossless)
        let base = source.deletingPathExtension().lastPathComponent + Naming.suffix(for: recipe.video)
        let (url, kept) = try Files.finish(tmp, source: source, stamp: stamp, base: base, ext: "mp4", trashOriginal: trash)
        return Outcome(source: source, status: .done(url), bytesIn: bytesIn, bytesOut: Files.size(url),
                       reencoded: recipe.video == .mp4 && used.way == .reencode,
                       note: notes.isEmpty ? nil : notes.joined(separator: ", "),
                       keptReason: recipe.trashOriginals && !trash ? "the MP4 isn't lossless" : kept)
    }

    static func composition(_ video: [AVAssetTrack], _ audio: [AVAssetTrack]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        for (type, tracks) in [(AVMediaType.video, video), (.audio, audio)] {
            var on: [Bool] = []
            for track in tracks { on.append(try await track.load(.isEnabled)) }
            for (track, on) in zip(tracks, playable(on)) {
                let (range, transform, language, tag) = try await track.load(.timeRange, .preferredTransform,
                                                                             .languageCode, .extendedLanguageTag)
                guard let added = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw Failure("couldn't write the video")
                }
                try added.insertTimeRange(range, of: track, at: range.start)
                added.preferredTransform = transform
                added.isEnabled = on
                added.languageCode = language
                added.extendedLanguageTag = tag
            }
        }
        return composition
    }

    static func reencode(_ main: AVAssetTrack, scale: CGFloat, preset: String, audio: [(track: AVAssetTrack, encode: Bool)],
                         to url: URL, near source: URL, metadata: [AVMetadataItem],
                         cancelled: @escaping @Sendable () -> Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> [String] {
        let composition = try await composition([main], [])
        var fit: AVVideoComposition?
        if scale < 1, let track = composition.tracks(withMediaType: .video).first {
            let bounds = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
            func even(_ v: CGFloat) -> CGFloat { max(2, (v * scale / 2).rounded() * 2) }
            let size = CGSize(width: even(bounds.width), height: even(bounds.height))
            var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
            layer.setTransform(track.preferredTransform
                .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                .concatenating(CGAffineTransform(scaleX: size.width / bounds.width, y: size.height / bounds.height)), at: .zero)
            let instruction = AVVideoCompositionInstruction(configuration: .init(
                layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
                timeRange: CMTimeRange(start: .zero, duration: composition.duration)))
            let frame = try await main.load(.minFrameDuration)
            fit = AVVideoComposition(configuration: .init(
                frameDuration: frame.isValid && frame > .zero ? frame : CMTime(value: 1, timescale: 30),
                instructions: [instruction], renderSize: size,
                sourceTrackIDForFrameTiming: track.trackID))
        }
        guard !audio.isEmpty else {
            try await export(composition, preset, fit, to: url, metadata: metadata, cancelled: cancelled, progress: progress)
            return []
        }
        let picture = Files.temp(near: source, ext: "mp4")
        defer { Files.remove(picture) }
        try await export(composition, preset, fit, to: picture, metadata: [], cancelled: cancelled) { progress($0 * 0.9) }
        let encoded = AVURLAsset(url: picture)
        return try await mux(encoded.loadTracks(withMediaType: .video), audio, to: url, metadata: metadata,
                             cancelled: cancelled) { progress(0.9 + $0 * 0.1) }
    }

    static func export(_ asset: AVAsset, _ preset: String, _ videoComposition: AVVideoComposition? = nil, to url: URL,
                       metadata: [AVMetadataItem], cancelled: @escaping @Sendable () -> Bool,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw Failure("couldn't save the MP4")
        }
        session.shouldOptimizeForNetworkUse = true
        session.metadata = metadata
        session.videoComposition = videoComposition
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await session.export(to: url, as: .mp4)
                return true
            }
            group.addTask {
                for await state in session.states(updateInterval: 0.3) {
                    if cancelled() { throw CancellationError() }
                    if case .exporting(let p) = state { progress(p.fractionCompleted) }
                }
                return false
            }
            while try await group.next() == false {}
            group.cancelAll()
        }
    }

    static func mux(_ video: [AVAssetTrack], _ audio: [(track: AVAssetTrack, encode: Bool)], to url: URL,
                    metadata: [AVMetadataItem], cancelled: @escaping @Sendable () -> Bool,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [String] {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = metadata
        var readers: [AVAssetReader] = []
        var pairs: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)] = []
        var notes: [String] = []
        func note(_ s: String) { if !notes.contains(s) { notes.append(s) } }

        func add(_ track: AVAssetTrack, _ output: AVAssetReaderTrackOutput, _ input: AVAssetWriterInput) throws -> Bool {
            guard let asset = track.asset else { return false }
            let reader = try readers.first { $0.asset === asset } ?? AVAssetReader(asset: asset)
            guard reader.canAdd(output), writer.canAdd(input) else { return false }
            if !readers.contains(reader) { readers.append(reader) }
            output.alwaysCopiesSampleData = false
            input.expectsMediaDataInRealTime = false
            reader.add(output)
            writer.add(input)
            pairs.append((output, input))
            return true
        }

        var picture: [(input: AVAssetWriterInput, on: Bool)] = []
        for track in video {
            let (formats, transform, timescale, enabled) = try await track.load(.formatDescriptions, .preferredTransform,
                                                                                .naturalTimeScale, .isEnabled)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
            input.transform = transform
            input.mediaTimeScale = timescale
            guard try add(track, AVAssetReaderTrackOutput(track: track, outputSettings: nil), input) else {
                throw Failure("couldn't write the video")
            }
            picture.append((input, enabled))
        }
        var sound: [(input: AVAssetWriterInput, on: Bool)] = []
        for (track, encode) in audio {
            let (formats, language, tag, enabled) = try await track.load(.formatDescriptions, .languageCode,
                                                                         .extendedLanguageTag, .isEnabled)
            var input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: formats.first)
            var added = try !encode && add(track, AVAssetReaderTrackOutput(track: track, outputSettings: nil), input)
            if !added, let settings = aac(formats.first), writer.canApply(outputSettings: settings.aac, forMediaType: .audio) {
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings.aac)
                added = try add(track, AVAssetReaderTrackOutput(track: track, outputSettings: settings.pcm), input)
                if added { note(toAAC) }
            }
            guard added else { note(lostTracks); continue }
            input.languageCode = language
            input.extendedLanguageTag = tag
            sound.append((input, enabled))
        }
        for tracks in [picture, sound] {
            for (track, on) in zip(tracks, playable(tracks.map(\.on))) { track.input.marksOutputTrackAsEnabled = on }
        }

        guard readers.allSatisfy({ $0.startReading() }), writer.startWriting() else {
            throw readers.lazy.compactMap(\.error).first ?? writer.error ?? Failure("couldn't write the video")
        }
        writer.startSession(atSourceTime: .zero)
        let duration = try await video[0].load(.timeRange).end.seconds
        var shownProgress = 0.0
        var active = pairs
        let finishing = OSAllocatedUnfairLock(initialState: (started: false, cancelled: false))
        nonisolated(unsafe) let finisher = writer
        do {
            try await withTaskCancellationHandler {
                while !active.isEmpty {
                    if cancelled() || Task.isCancelled { throw CancellationError() }
                    var moved = false
                    for (n, pair) in active.enumerated().reversed() {
                        while pair.input.isReadyForMoreMediaData {
                            guard let sample = pair.output.copyNextSampleBuffer() else {
                                if let error = readers.first(where: { $0.status == .failed })?.error { throw error }
                                pair.input.markAsFinished()
                                active.remove(at: n)
                                break
                            }
                            guard pair.input.append(sample) else { throw writer.error ?? Failure("couldn't write the video") }
                            moved = true
                            if pair.input === pairs[0].input, duration > 0 {
                                let done = CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration
                                if done - shownProgress >= 0.01 {
                                    shownProgress = done
                                    progress(min(1, done))
                                }
                            }
                        }
                    }
                    if !moved { try await Task.sleep(for: .milliseconds(2)) }
                }
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    finishing.withLock {
                        guard !$0.cancelled else { return done.resume() }
                        $0.started = true
                        finisher.finishWriting { done.resume() }
                    }
                }
            } onCancel: {
                finishing.withLock {
                    $0.cancelled = true
                    if $0.started { finisher.cancelWriting() }
                }
                removeStaging(of: url)
            }
            guard writer.status == .completed else { throw writer.error ?? CancellationError() }
        } catch {
            readers.forEach { $0.cancelReading() }
            writer.cancelWriting()
            removeStaging(of: url)
            throw error
        }
        return notes
    }

    static func removeStaging(of url: URL) {
        let dir = url.deletingLastPathComponent()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where name.hasPrefix(url.lastPathComponent + ".sb-") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
