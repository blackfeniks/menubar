import Foundation
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreGraphics

enum PhotoFormat: String, CaseIterable, Sendable {
    case keep, jpeg, png, heic
}

enum PhotoSize: Hashable, Sendable {
    case keep
    case megabytes(Int)
    case longSide(Int)
    case percent(Int)
}

enum VideoMode: String, CaseIterable, Sendable {
    case keep, mp4, p1080, p720
}

struct Recipe: Sendable, Equatable {
    var format: PhotoFormat = .keep
    var size: PhotoSize = .keep
    var video: VideoMode = .keep
    var trashOriginals = false

    var touchesPhotos: Bool { format != .keep || size != .keep }
    var touchesVideos: Bool { video != .keep }
}

struct Item: Sendable, Hashable {
    enum Kind: Sendable { case photo, video }
    let url: URL
    let kind: Kind
    let bytes: Int64
    var type: UTType?
    var width = 0
    var height = 0
}

struct Outcome: Sendable {
    enum Status: Sendable {
        case done(URL)
        case skipped(String)
        case failed(String)
    }
    let source: URL
    let status: Status
    var bytesIn: Int64 = 0
    var bytesOut: Int64 = 0
    var reencoded = false
    var note: String?
    var keptReason: String?
    var originalKept: Bool { keptReason != nil }

    var output: URL? { if case .done(let url) = status { return url } else { return nil } }
}

struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

enum Scan {
    static let photoTypes: Set<String> = {
        let readable = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
        let left = ["com.compuserve.gif", "com.microsoft.ico", "com.apple.icns", "com.adobe.pdf",
                    "public.svg-image", "public.heics", "public.avis"]
        return readable.subtracting(left)
    }()

    static let videoTypes: [UTType] = [.quickTimeMovie, .mpeg4Movie, UTType("com.apple.m4v-video")].compactMap { $0 }

    static func kind(of url: URL) -> Item.Kind? {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return nil }
        if videoTypes.contains(where: { type.conforms(to: $0) }) { return .video }
        if photoTypes.contains(type.identifier) { return .photo }
        if type.conforms(to: .rawImage), photoTypes.contains(where: { UTType($0)?.conforms(to: .rawImage) == true }) {
            return .photo
        }
        if type.isDynamic || type == .data,
           let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let sniffed = CGImageSourceGetType(src) as String?, photoTypes.contains(sniffed) {
            return .photo
        }
        return nil
    }

    struct Probe {
        var width = 0, height = 0
        var type: UTType?
        var frames = 1
    }

    static func probe(_ url: URL) -> Probe {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return Probe() }
        var p = Probe(type: (CGImageSourceGetType(src) as String?).flatMap { UTType($0) },
                      frames: CGImageSourceGetCount(src))
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue {
            let rotated = ((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5
            (p.width, p.height) = rotated ? (h, w) : (w, h)
        }
        return p
    }

    static func isMultiFrame(_ type: UTType?, frames: Int) -> Bool {
        guard frames > 1, let type else { return false }
        return type.conforms(to: .tiff) && !type.conforms(to: .rawImage) || type.conforms(to: .png)
            || type.conforms(to: .webP)
    }

    static func isBeingCopied(_ url: URL) -> Bool {
        var info = [UInt8](repeating: 0, count: 32)
        guard getxattr(url.path, "com.apple.FinderInfo", &info, 32, 0, 0) >= 4 else { return false }
        return info[0..<4] == [0x62, 0x72, 0x6F, 0x6B]
    }

    static func items(from urls: [URL]) -> (items: [Item], ignored: Int) {
        var seen = Set<String>()
        var items: [Item] = []
        var ignored = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .fileSizeKey, .contentTypeKey, .isRegularFileKey]

        func add(_ url: URL) {
            let url = url.standardizedFileURL
            guard !url.lastPathComponent.hasPrefix("."), seen.insert(url.path.lowercased()).inserted else { return }
            guard let kind = kind(of: url), !isBeingCopied(url) else { ignored += 1; return }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
            var item = Item(url: url, kind: kind, bytes: Int64(values?.fileSize ?? 0), type: values?.contentType)
            if kind == .photo {
                let p = probe(url)
                guard !isMultiFrame(p.type, frames: p.frames) else { ignored += 1; return }
                item.width = p.width
                item.height = p.height
                item.type = p.type ?? item.type
            }
            items.append(item)
        }

        for url in urls {
            if Task.isCancelled { break }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true, values?.isPackage != true {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
                for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                    if Task.isCancelled { break }
                    let v = try? child.resourceValues(forKeys: [.isRegularFileKey])
                    if v?.isRegularFile == true { add(child) }
                }
            } else if values?.isRegularFile == true {
                add(url)
            } else {
                ignored += 1
            }
        }
        return (items, ignored)
    }
}

enum Files {
    private static let lock = NSLock()

    static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    nonisolated(unsafe) private static var live = Set<URL>()

    static func temp(near source: URL, ext: String) -> URL {
        let base = String(source.deletingPathExtension().lastPathComponent.prefix(40))
        let url = source.deletingLastPathComponent()
            .appendingPathComponent(".\(base).converter-\(UUID().uuidString.prefix(8)).\(ext)")
        lock.lock()
        live.insert(url)
        lock.unlock()
        return url
    }

    static func removeUnfinished() {
        lock.lock()
        let urls = live
        live.removeAll()
        lock.unlock()
        urls.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    static func fitting(_ base: String, ext: String) -> String {
        var base = base
        while !base.isEmpty && (base + " 9999." + ext).utf8.count > 255 { base.removeLast() }
        return base
    }

    static func place(_ temp: URL, dir: URL, base: String, ext: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        let base = fitting(base, ext: ext)
        for n in 1...9999 {
            let name = n == 1 ? base : "\(base) \(n)"
            let candidate = dir.appendingPathComponent(name).appendingPathExtension(ext)
            if fm.fileExists(atPath: candidate.path) { continue }
            do {
                try fm.moveItem(at: temp, to: candidate)
                live.remove(temp)
                return candidate
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw Failure("no free name for \(base).\(ext)")
    }

    static func trash(_ original: URL) -> String? {
        do {
            try FileManager.default.trashItem(at: original, resultingItemURL: nil)
            return nil
        } catch CocoaError.featureUnsupported {
            return "this disk has no Trash"
        } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile {
            return "the file is gone"
        } catch CocoaError.fileWriteNoPermission, CocoaError.fileReadNoPermission {
            return "the file is locked or access is denied"
        } catch {
            return "couldn't move it to the Trash"
        }
    }

    static func stamp(_ url: URL) -> [Int64] {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return [] }
        return [Int64(st.st_dev), Int64(bitPattern: UInt64(st.st_ino)), Int64(st.st_size),
                Int64(st.st_mtimespec.tv_sec), Int64(st.st_mtimespec.tv_nsec)]
    }

    private static let carried = ["com.apple.metadata:_kMDItemUserTags",
                                  "com.apple.metadata:kMDItemWhereFroms",
                                  "com.apple.metadata:kMDItemFinderComment"]

    static func attributes(of url: URL) -> [(String, Data)] {
        carried.compactMap { name in
            let size = getxattr(url.path, name, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
            return read == size ? (name, data) : nil
        }
    }

    static func apply(attributes: [(String, Data)], to url: URL) {
        for (name, data) in attributes {
            _ = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, data.count, 0, 0) }
        }
    }

    static func finish(_ temp: URL, source: URL, stamp before: [Int64], base: String, ext: String,
                       trashOriginal: Bool) throws -> (URL, String?) {
        guard !before.isEmpty, stamp(source) == before else {
            remove(temp)
            throw Failure("the file changed meanwhile")
        }
        let dates = dates(of: source)
        let attrs = attributes(of: source)
        let url: URL
        do {
            url = try place(temp, dir: source.deletingLastPathComponent(), base: base, ext: ext)
        } catch {
            remove(temp)
            throw error
        }
        apply(attributes: attrs, to: url)
        apply(dates: dates, to: url)
        guard trashOriginal else { return (url, nil) }
        guard stamp(source) == before else { return (url, "the file changed meanwhile") }
        return (url, trash(source))
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        lock.lock()
        live.remove(url)
        lock.unlock()
    }

    static func dates(of url: URL) -> [FileAttributeKey: Any] {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        return attrs.filter { $0.key == .creationDate || $0.key == .modificationDate }
    }

    static func apply(dates: [FileAttributeKey: Any], to url: URL) {
        guard !dates.isEmpty else { return }
        try? FileManager.default.setAttributes(dates, ofItemAtPath: url.path)
    }
}

enum Naming {
    static func suffix(for size: PhotoSize) -> String {
        switch size {
        case .keep: return ""
        case .megabytes(let mb): return "_\(mb)mb"
        case .longSide(let px): return "_\(px)px"
        case .percent(let p): return "_\(p)pct"
        }
    }

    static func suffix(for video: VideoMode) -> String {
        switch video {
        case .p1080: return "_1080p"
        case .p720: return "_720p"
        default: return ""
        }
    }
}

enum Photo {
    static let bestQuality = 0.95
    static let lowestQuality = 0.80

    static func sameFormat(_ source: UTType?) -> UTType? {
        guard let source, !source.conforms(to: .rawImage) else { return nil }
        if source.conforms(to: .jpeg) { return .jpeg }
        if source.conforms(to: .png) { return .png }
        if source.conforms(to: .heic) || source.conforms(to: .heif) { return .heic }
        if source.conforms(to: .tiff) { return .tiff }
        if let avif = UTType("public.avif"), source.conforms(to: avif) { return avif }
        return nil
    }

    static func isAlready(_ target: UTType, type: UTType?, url: URL) -> Bool {
        guard sameFormat(type) == target else { return false }
        let named = UTType(filenameExtension: url.pathExtension)
        return sameFormat(named) == target
    }

    static func outputType(_ format: PhotoFormat, source: UTType?, hasAlpha: Bool) -> UTType {
        switch format {
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .keep: return sameFormat(source) ?? (hasAlpha ? .png : .jpeg)
        }
    }

    static func ext(for type: UTType) -> String {
        switch type {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .heic: return "heic"
        case .tiff: return "tiff"
        default: return type.preferredFilenameExtension ?? "img"
        }
    }

    static func displayName(_ type: UTType) -> String {
        switch type {
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        default: return type.preferredFilenameExtension?.uppercased() ?? "that format"
        }
    }

    static func isLossy(_ type: UTType) -> Bool { type != .png && type != .tiff }

    static func process(_ source: URL, _ recipe: Recipe, cancelled: () -> Bool) throws -> Outcome {
        let bytesIn = Files.size(source)
        let stamp = Files.stamp(source)
        guard let src = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else { throw Failure("couldn't read it") }

        let sourceType = (CGImageSourceGetType(src) as String?).flatMap { UTType($0) }
        let hasAlpha = (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
        let target = outputType(recipe.format, source: sourceType, hasAlpha: hasAlpha)
        let sameType = isAlready(target, type: sourceType, url: source)
        let long = max(width, height)

        func skip(_ why: String) -> Outcome {
            Outcome(source: source, status: .skipped(why), bytesIn: bytesIn, bytesOut: bytesIn)
        }
        if Scan.isMultiFrame(sourceType, frames: CGImageSourceGetCount(src)) {
            return skip("several frames")
        }
        switch recipe.size {
        case .keep where sameType:
            return skip("already \(displayName(target))")
        case .megabytes(let mb) where sameType && bytesIn <= Int64(mb) * 1_000_000:
            return skip("already under \(mb) MB")
        case .longSide(let px) where sameType && long <= px:
            return skip("already \(px) px or smaller")
        default:
            break
        }

        let meta = metadata(props)
        let data: Data
        switch recipe.size {
        case .megabytes(let mb):
            data = try fit(src, long: long, type: target, budget: mb * 1_000_000, meta: meta, cancelled: cancelled)
        case .keep:
            data = try encode(render(src, long: long, for: target), target, meta)
        case .longSide(let px):
            data = try encode(render(src, long: min(px, long), for: target), target, meta)
        case .percent(let p):
            let side = max(1, Int((Double(long) * Double(p) / 100).rounded()))
            data = try encode(render(src, long: min(side, long), for: target), target, meta)
        }
        if cancelled() { throw CancellationError() }

        if case .megabytes(let mb) = recipe.size, data.count > mb * 1_000_000 {
            throw Failure("can't be squeezed to \(mb) MB")
        }

        let ext = self.ext(for: target)
        let tmp = Files.temp(near: source, ext: ext)
        do {
            try data.write(to: tmp)
            guard verify(tmp) else { throw Failure("the result can't be read") }
        } catch {
            Files.remove(tmp)
            throw (error as? Failure) ?? Failure(Engine.reason(error))
        }
        let base = source.deletingPathExtension().lastPathComponent + Naming.suffix(for: recipe.size)
        let (url, kept) = try Files.finish(tmp, source: source, stamp: stamp, base: base, ext: ext,
                                           trashOriginal: recipe.trashOriginals)
        return Outcome(source: source, status: .done(url), bytesIn: bytesIn, bytesOut: Int64(data.count), keptReason: kept)
    }

    static func fit(_ src: CGImageSource, long: Int, type: UTType, budget: Int,
                    meta: [CFString: Any], cancelled: () -> Bool) throws -> Data {
        let lossy = isLossy(type)
        let floor: Double? = lossy ? lowestQuality : nil
        func check() throws { if cancelled() { throw CancellationError() } }

        var full: CGImage? = try render(src, long: long, for: type)
        let hopeful = lossy && budget * 3 >= full!.width * full!.height
        if hopeful {
            let best = try encode(full!, type, meta, quality: bestQuality)
            if best.count <= budget { return best }
        }
        var data = try encode(full!, type, meta, quality: floor)
        if lossy && !hopeful && data.count <= budget {
            let best = try encode(full!, type, meta, quality: bestQuality)
            if best.count <= budget { return best }
        }

        let image: CGImage
        let atFullSize = data.count <= budget
        if atFullSize {
            image = full!
        } else {
            full = nil
            var tooBig = (side: long, bytes: data.count)
            var fits: (side: Int, image: CGImage, data: Data)?
            for _ in 0..<12 {
                try check()
                let side: Int
                if let fits {
                    guard tooBig.side - fits.side > max(8, tooBig.side / 33) else { break }
                    side = (fits.side + tooBig.side) / 2
                } else {
                    let ratio = (Double(budget) / Double(tooBig.bytes)).squareRoot() * 0.97
                    side = min(tooBig.side - 1, Int(Double(tooBig.side) * ratio))
                }
                guard side >= 32 else { break }
                let candidate = try render(src, long: side, for: type)
                let bytes = try encode(candidate, type, meta, quality: floor)
                if bytes.count <= budget {
                    fits = (side, candidate, bytes)
                } else {
                    tooBig = (side, bytes.count)
                }
            }
            guard let fits else { throw Failure("can't be squeezed to \(budget / 1_000_000) MB") }
            image = fits.image
            data = fits.data
        }
        guard lossy else { return data }

        var lo = Int(lowestQuality * 100) + 1
        var hi = Int(bestQuality * 100) - (atFullSize ? 1 : 0)
        while lo <= hi {
            try check()
            let mid = (lo + hi) / 2
            let attempt = try encode(image, type, meta, quality: Double(mid) / 100)
            if attempt.count <= budget { data = attempt; lo = mid + 1 } else { hi = mid - 1 }
        }
        return data
    }

    static func render(_ src: CGImageSource, long: Int, for type: UTType) throws -> CGImage {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let sourceHasAlpha = (props?[kCGImagePropertyHasAlpha] as? Bool) ?? false
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, long),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw Failure("couldn't read the pixels")
        }
        return prepared(image, for: type, sourceHasAlpha: sourceHasAlpha)
    }

    static func prepared(_ image: CGImage, for type: UTType, sourceHasAlpha: Bool = true) -> CGImage {
        let model = image.colorSpace?.model ?? .unknown
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let dropAlpha = !opaque && (type == .jpeg || !sourceHasAlpha)
        let modelOK = model == .rgb || model == .monochrome || (model == .cmyk && (type == .jpeg || type == .tiff))
        guard dropAlpha || !modelOK else { return image }

        let keepAlpha = !opaque && !dropAlpha
        let info = keepAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let spaces = model == .rgb ? [image.colorSpace!, srgb] : [srgb]
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        for space in spaces {
            guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: info.rawValue) else { continue }
            if !keepAlpha {
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(rect)
            }
            ctx.draw(image, in: rect)
            if let out = ctx.makeImage() { return out }
        }
        return image
    }

    static func metadata(_ props: [CFString: Any]) -> [CFString: Any] {
        var meta: [CFString: Any] = [:]
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary,
                    kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let value = props[key] { meta[key] = value }
        }
        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            meta[kCGImagePropertyExifDictionary] = exif
        }
        var tiff: [CFString: Any] = [kCGImagePropertyTIFFOrientation: 1]
        if let src = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware,
                        kCGImagePropertyTIFFDateTime, kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright,
                        kCGImagePropertyTIFFImageDescription, kCGImagePropertyTIFFHostComputer] {
                if let value = src[key] { tiff[key] = value }
            }
        }
        meta[kCGImagePropertyTIFFDictionary] = tiff
        meta[kCGImagePropertyOrientation] = 1
        return meta
    }

    static func encode(_ image: CGImage, _ type: UTType, _ meta: [CFString: Any], quality: Double? = nil) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw Failure("can't write \(displayName(type))")
        }
        var props = meta
        if isLossy(type) {
            props[kCGImageDestinationLossyCompressionQuality] = quality ?? bestQuality
        }
        if type == .jpeg {
            props[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true]
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure("couldn't save \(displayName(type))") }
        return data as Data
    }

    static func verify(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetStatus(src) == .statusComplete,
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              ((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0) > 0
        else { return false }
        return true
    }
}

enum Engine {
    enum Event: Sendable {
        case finished(Outcome)
        case videoProgress(Double)
    }

    static func photoLanes(for photos: [Item]) -> Int {
        let cores = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount / 2))
        let worst = photos.map {
            Double(max(1, $0.width * $0.height)) * ($0.type?.conforms(to: .rawImage) == true ? 70 : 20)
        }.max() ?? 1
        let budget = Double(ProcessInfo.processInfo.physicalMemory) / 3
        return max(1, min(cores, Int(budget / worst)))
    }

    static func run(_ items: [Item], _ recipe: Recipe, report: @escaping @Sendable (Event) -> Void) async -> [Outcome] {
        let photos = recipe.touchesPhotos ? items.filter { $0.kind == .photo } : []
        let videos = recipe.touchesVideos ? items.filter { $0.kind == .video } : []

        @Sendable func failed(_ item: Item, _ error: Error) -> Outcome {
            Outcome(source: item.url, status: .failed(reason(error)), bytesIn: item.bytes)
        }

        return await withTaskGroup(of: [Outcome].self) { group in
            if !videos.isEmpty {
                group.addTask(priority: .userInitiated) {
                    var out: [Outcome] = []
                    for item in videos {
                        if Task.isCancelled { break }
                        let outcome: Outcome
                        do {
                            outcome = try await Video.process(item.url, recipe, cancelled: { Task.isCancelled },
                                                              progress: { report(.videoProgress($0)) })
                        } catch {
                            outcome = failed(item, error)
                        }
                        report(.videoProgress(0))
                        report(.finished(outcome))
                        out.append(outcome)
                    }
                    return out
                }
            }
            let queue = Queue(photos)
            for _ in 0..<min(photoLanes(for: photos), photos.count) {
                group.addTask(priority: .userInitiated) {
                    var out: [Outcome] = []
                    while !Task.isCancelled, let item = queue.next() {
                        let outcome: Outcome
                        do {
                            outcome = try autoreleasepool {
                                try Photo.process(item.url, recipe, cancelled: { Task.isCancelled })
                            }
                        } catch {
                            outcome = failed(item, error)
                        }
                        report(.finished(outcome))
                        out.append(outcome)
                    }
                    return out
                }
            }
            var all: [Outcome] = []
            for await chunk in group { all += chunk }
            return all
        }
    }

    static func reason(_ error: Error) -> String {
        if let failure = error as? Failure { return failure.message }
        if error is CancellationError { return "stopped" }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return "the disk is full" }
        if ns.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: ns.code) {
            case .fileWriteOutOfSpace: return "the disk is full"
            case .fileWriteNoPermission, .fileReadNoPermission: return "access denied"
            case .fileWriteVolumeReadOnly: return "the disk is read-only"
            case .fileNoSuchFile, .fileReadNoSuchFile: return "the file is gone"
            default: break
            }
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOSPC) {
            return "the disk is full"
        }
        if ns.domain == AVFoundationErrorDomain {
            if ns.code == AVError.diskFull.rawValue { return "the disk is full" }
            return "couldn't re-encode the video"
        }
        return ns.localizedDescription
    }

    final class Queue: @unchecked Sendable {
        private var items: [Item]
        private var index = 0
        private let lock = NSLock()
        init(_ items: [Item]) { self.items = items }
        func next() -> Item? {
            lock.lock()
            defer { lock.unlock() }
            guard index < items.count else { return nil }
            defer { index += 1 }
            return items[index]
        }
    }
}
