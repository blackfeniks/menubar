import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct InputDevice: Equatable {
	let id: AudioDeviceID
	let uid: String
	let name: String
	let transport: UInt32

	var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
	var isBluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
}

enum AudioDevices {
	private static func property(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout UInt32) -> Bool {
		var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
		                                      mElement: kAudioObjectPropertyElementMain)
		var size = UInt32(MemoryLayout<UInt32>.size)
		return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr
	}

	private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
		var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
		                                      mElement: kAudioObjectPropertyElementMain)
		var size = UInt32(MemoryLayout<CFString?>.size)
		var value: CFString?
		let status = withUnsafeMutablePointer(to: &value) {
			AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
		}
		guard status == noErr, let value else { return nil }
		return value as String
	}

	private static func inputChannels(_ id: AudioDeviceID) -> Int {
		var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
		                                      mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
		var size: UInt32 = 0
		guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
		let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
		defer { raw.deallocate() }
		guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
		let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
		return list.reduce(0) { $0 + Int($1.mNumberChannels) }
	}

	static func inputs() -> [InputDevice] {
		var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
		                                      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
		var size: UInt32 = 0
		guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
		var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
		guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
		var result: [InputDevice] = []
		for id in ids where inputChannels(id) > 0 {
			var transport: UInt32 = 0
			_ = property(id, kAudioDevicePropertyTransportType, &transport)
			guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { continue }
			let name = string(id, kAudioObjectPropertyName) ?? uid
			if transport == kAudioDeviceTransportTypeAggregate && name.hasPrefix("CADefaultDeviceAggregate") { continue }
			let plumbing = ["zoomaudiodevice", "msteamsaudiodevice", "microsoft teams audio", "webexmediaaudiodevice"]
			if plumbing.contains(where: { uid.lowercased().contains($0) || name.lowercased().contains($0) }) { continue }
			result.append(InputDevice(id: id, uid: uid, name: name, transport: transport))
		}
		return result.sorted { ($0.isBuiltIn ? 0 : 1, $0.name) < ($1.isBuiltIn ? 0 : 1, $1.name) }
	}

	static var builtIn: InputDevice? { inputs().first(where: \.isBuiltIn) }

	static func resolve(uid: String?) -> InputDevice? {
		let all = inputs()
		if let uid, let d = all.first(where: { $0.uid == uid }) { return d }
		return all.first(where: \.isBuiltIn) ?? all.first
	}

	static func observeChanges(_ handler: @escaping () -> Void) {
		var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
		                                      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
		AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { _, _ in handler() }
	}

	static func isAlive(_ id: AudioDeviceID) -> Bool {
		var alive: UInt32 = 0
		return property(id, kAudioDevicePropertyDeviceIsAlive, &alive) && alive != 0
	}
}

final class AudioCapture: @unchecked Sendable {
	private var unit: AudioUnit?
	private var deviceFormat = AudioStreamBasicDescription()
	private var converter: AVAudioConverter?
	private var inFormat: AVAudioFormat?
	private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
	private var renderBuffer: UnsafeMutablePointer<Float>?
	private var renderCapacity = 0
	private let lock = NSLock()
	private var pending: [Float] = []
	private var scheduled = false
	let queue: DispatchQueue
	var onSamples: (([Float], Float) -> Void)?
	var onDeviceLost: (() -> Void)?
	private(set) var device: InputDevice?

	private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

	init(queue: DispatchQueue) { self.queue = queue }

	deinit { stop() }

	func start(device: InputDevice) throws {
		stop()
		try configure(device)
		watch(device.id, kAudioDevicePropertyNominalSampleRate) { [weak self] in
			guard let self, let d = self.device else { return }
			self.teardown()
			do { try self.configure(d) } catch { self.onDeviceLost?() }
		}
		watch(device.id, kAudioDevicePropertyDeviceIsAlive) { [weak self] in
			guard let self, let d = self.device, !AudioDevices.isAlive(d.id) else { return }
			self.onDeviceLost?()
		}
	}

	private func watch(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ action: @escaping () -> Void) {
		var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
		                                      mElement: kAudioObjectPropertyElementMain)
		let block: AudioObjectPropertyListenerBlock = { _, _ in action() }
		if AudioObjectAddPropertyListenerBlock(id, &addr, queue, block) == noErr { listeners.append((addr, block)) }
	}

	private func configure(_ device: InputDevice) throws {
		var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
		                                     componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
		guard let comp = AudioComponentFindNext(nil, &desc) else { throw CaptureError("audio input is unavailable") }
		var au: AudioUnit?
		try check(AudioComponentInstanceNew(comp, &au), "AudioComponentInstanceNew")
		guard let au else { throw CaptureError("audio input could not be created") }
		unit = au
		var one: UInt32 = 1, zero: UInt32 = 0
		try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "EnableIO in")
		try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4), "EnableIO out")
		var devID = device.id
		try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
		                               &devID, UInt32(MemoryLayout<AudioDeviceID>.size)), "CurrentDevice")
		var hw = AudioStreamBasicDescription()
		var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
		try check(AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size), "hw format")
		let rate = hw.mSampleRate > 0 ? hw.mSampleRate : 48000
		var client = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
		                                         mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
		                                         mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
		                                         mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
		try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size), "client format")
		deviceFormat = client
		inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
		converter = AVAudioConverter(from: inFormat!, to: outFormat)
		converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
		var maxFrames: UInt32 = 4096
		size = 4
		AudioUnitGetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &size)
		renderCapacity = Int(max(maxFrames, 4096))
		renderBuffer = .allocate(capacity: renderCapacity)
		var cb = AURenderCallbackStruct(inputProc: { refCon, flags, ts, bus, frames, _ in
			Unmanaged<AudioCapture>.fromOpaque(refCon).takeUnretainedValue().render(flags, ts, bus, frames)
		}, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
		try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
		                               &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "input callback")
		try check(AudioUnitInitialize(au), "AudioUnitInitialize")
		try check(AudioOutputUnitStart(au), "AudioOutputUnitStart")
		self.device = device
	}

	func stop() {
		if let id = device?.id {
			for (addr, block) in listeners {
				var a = addr
				AudioObjectRemovePropertyListenerBlock(id, &a, queue, block)
			}
		}
		listeners.removeAll()
		teardown()
		device = nil
	}

	private func teardown() {
		if let unit {
			AudioOutputUnitStop(unit)
			AudioUnitUninitialize(unit)
			AudioComponentInstanceDispose(unit)
		}
		unit = nil
		renderBuffer?.deallocate()
		renderBuffer = nil
		lock.lock()
		pending.removeAll()
		lock.unlock()
		converter = nil
	}

	private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ ts: UnsafePointer<AudioTimeStamp>,
	                    _ bus: UInt32, _ frames: UInt32) -> OSStatus {
		guard let unit, let renderBuffer, Int(frames) <= renderCapacity else { return noErr }
		var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4,
		                                                                     mData: UnsafeMutableRawPointer(renderBuffer)))
		let st = AudioUnitRender(unit, flags, ts, bus, frames, &list)
		guard st == noErr else { return st }
		lock.lock()
		pending.append(contentsOf: UnsafeBufferPointer(start: renderBuffer, count: Int(frames)))
		let needSchedule = !scheduled
		scheduled = true
		lock.unlock()
		if needSchedule { queue.async { [weak self] in self?.drain() } }
		return noErr
	}

	private func drain() {
		lock.lock()
		let chunk = pending
		pending.removeAll(keepingCapacity: true)
		scheduled = false
		lock.unlock()
		guard !chunk.isEmpty, let converter, let inFormat else { return }
		let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
		guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(chunk.count)) else { return }
		inBuf.frameLength = AVAudioFrameCount(chunk.count)
		chunk.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: chunk.count) }
		let outCap = AVAudioFrameCount(Double(chunk.count) * 16000 / inFormat.sampleRate) + 64
		guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else { return }
		var fed = false
		var error: NSError?
		converter.convert(to: outBuf, error: &error) { _, status in
			if fed {
				status.pointee = .noDataNow
				return nil
			}
			fed = true
			status.pointee = .haveData
			return inBuf
		}
		let n = Int(outBuf.frameLength)
		guard n > 0 else { return }
		onSamples?(Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: n)), rms)
	}

	private func check(_ status: OSStatus, _ what: String) throws {
		if status != noErr { throw CaptureError("\(what): \(status)") }
	}
}

final class FileFeeder {
	private let samples: [Float]
	private let queue: DispatchQueue
	private var timer: DispatchSourceTimer?
	private var position = 0
	var onSamples: (([Float], Float) -> Void)?

	init(path: String, queue: DispatchQueue) throws {
		samples = try readAudioFile(URL(fileURLWithPath: path))
		self.queue = queue
	}

	func start() {
		let t = DispatchSource.makeTimerSource(queue: queue)
		t.schedule(deadline: .now(), repeating: 0.1)
		t.setEventHandler { [weak self] in
			guard let self else { return }
			let n = 1600
			var chunk = [Float](repeating: 0, count: n)
			for i in 0..<n where position + i < samples.count { chunk[i] = samples[position + i] }
			position += n
			let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(n))
			onSamples?(chunk, rms)
		}
		t.resume()
		timer = t
	}

	func stop() {
		timer?.cancel()
		timer = nil
	}
}

struct CaptureError: Error, CustomStringConvertible {
	let description: String
	init(_ d: String) { description = d }
}

func readAudioFile(_ url: URL) throws -> [Float] {
	let f = try AVAudioFile(forReading: url)
	let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
	guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { return [] }
	try f.read(into: buf)
	if f.processingFormat.sampleRate == 16000 && f.processingFormat.channelCount == 1 {
		return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
	}
	guard let conv = AVAudioConverter(from: f.processingFormat, to: fmt),
	      let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(f.length) * 16000 / f.processingFormat.sampleRate) + 1024)
	else { return [] }
	var done = false
	conv.convert(to: out, error: nil) { _, status in
		if done {
			status.pointee = .endOfStream
			return nil
		}
		done = true
		status.pointee = .haveData
		return buf
	}
	return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
}
