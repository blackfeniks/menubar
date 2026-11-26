import AudioToolbox
import CoreAudio
import Foundation

let systemObject = AudioObjectID(kAudioObjectSystemObject)
let noObject = AudioObjectID(kAudioObjectUnknown)

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

enum CA {
    static func settable(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool {
        var a = a
        var result: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &a, &result) == noErr && result.boolValue
    }

    static func get<T: BitwiseCopyable>(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress, as initial: T) -> T? {
        var a = a
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr ? value : nil
    }

    @discardableResult
    static func set<T: BitwiseCopyable>(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var a = a
        var value = value
        return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }

    static func ids(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var a = a
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        var result = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &result) == noErr else { return [] }
        return Array(result.prefix(Int(size) / MemoryLayout<AudioObjectID>.stride))
    }

    static func string(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress) -> String? {
        var a = a
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func streamChannels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    static func translate(uid: String) -> AudioObjectID? {
        var a = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cf = uid as CFString
        var id = noObject
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(systemObject, &a, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        return err == noErr && id != noObject ? id : nil
    }
}

struct IOProc: Equatable {
    let bits: UInt
    var id: AudioDeviceIOProcID { unsafeBitCast(bits, to: AudioDeviceIOProcID.self) }

    static func create(on device: AudioObjectID, _ proc: @escaping AudioDeviceIOProc, _ client: UnsafeMutableRawPointer?) -> (IOProc?, OSStatus) {
        var raw: UInt = 0
        let err = withUnsafeMutablePointer(to: &raw) { p in
            p.withMemoryRebound(to: AudioDeviceIOProcID?.self, capacity: 1) { AudioDeviceCreateIOProcID(device, proc, client, $0) }
        }
        return (err == noErr && raw != 0 ? IOProc(bits: raw) : nil, err)
    }

    @discardableResult func start(_ device: AudioObjectID) -> OSStatus { AudioDeviceStart(device, id) }
    @discardableResult func stop(_ device: AudioObjectID) -> OSStatus { AudioDeviceStop(device, id) }
    func destroy(_ device: AudioObjectID) { AudioDeviceDestroyIOProcID(device, id) }
}

final class Listener {
    private final class Box {
        var handler: (() -> Void)?
        init(_ handler: @escaping () -> Void) { self.handler = handler }
    }

    private let object: AudioObjectID
    private var where_: AudioObjectPropertyAddress
    private let box: Box
    private var active = false

    private static let proc: AudioObjectPropertyListenerProc = { _, _, _, client in
        guard let client else { return noErr }
        let box = Unmanaged<Box>.fromOpaque(client).takeUnretainedValue()
        DispatchQueue.main.async { box.handler?() }
        return noErr
    }

    init?(_ object: AudioObjectID, _ a: AudioObjectPropertyAddress, _ handler: @escaping () -> Void) {
        self.object = object
        self.where_ = a
        self.box = Box(handler)
        let context = Unmanaged.passRetained(box).toOpaque()
        guard AudioObjectAddPropertyListener(object, &where_, Self.proc, context) == noErr else {
            Unmanaged<Box>.fromOpaque(context).release()
            return nil
        }
        active = true
    }

    func cancel() {
        guard active else { return }
        active = false
        box.handler = nil
        let context = Unmanaged.passUnretained(box).toOpaque()
        AudioObjectRemovePropertyListener(object, &where_, Self.proc, context)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Unmanaged<Box>.fromOpaque(context).release() }
    }

    deinit { cancel() }
}
