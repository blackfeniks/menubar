import Foundation

struct OrtError: Error, CustomStringConvertible {
	let description: String
}

enum OrtInput {
	case float(String, [Float], [Int64])
	case int64(String, [Int64], [Int64])
	case int32(String, [Int32], [Int64])
}

final class OrtTensor {
	fileprivate let value: OpaquePointer
	let shape: [Int64]

	fileprivate init(_ value: OpaquePointer) {
		self.value = value
		var dims = [Int64](repeating: 0, count: 8)
		let rank = ortw_value_shape(value, &dims, 8)
		shape = rank > 0 ? Array(dims.prefix(Int(rank))) : []
	}

	deinit { ortw_value_release(value) }

	var count: Int { shape.reduce(1) { $0 * Int($1) } }

	var floats: UnsafeBufferPointer<Float> {
		UnsafeBufferPointer(start: ortw_value_data(value)?.assumingMemoryBound(to: Float.self), count: count)
	}

	var int64s: UnsafeBufferPointer<Int64> {
		UnsafeBufferPointer(start: ortw_value_data(value)?.assumingMemoryBound(to: Int64.self), count: count)
	}

	var int32s: UnsafeBufferPointer<Int32> {
		UnsafeBufferPointer(start: ortw_value_data(value)?.assumingMemoryBound(to: Int32.self), count: count)
	}
}

final class OrtSession {
	private let handle: OpaquePointer

	init(path: String, threads: Int = 0) throws {
		var err = [CChar](repeating: 0, count: 512)
		guard let h = ortw_session_create(path, Int32(threads), &err, err.count) else {
			throw OrtError(description: "\((path as NSString).lastPathComponent): \(String(cString: err))")
		}
		handle = h
	}

	deinit { ortw_session_release(handle) }

	func run(_ inputs: [OrtInput], outputs: [String]) throws -> [OrtTensor] {
		var names: [UnsafeMutablePointer<CChar>] = []
		var buffers: [UnsafeMutableRawPointer] = []
		var shapes: [UnsafeMutablePointer<Int64>] = []
		defer {
			names.forEach { free($0) }
			buffers.forEach { $0.deallocate() }
			shapes.forEach { $0.deallocate() }
		}
		func copy<T>(_ a: [T]) -> UnsafeMutableRawPointer {
			let p = UnsafeMutableRawPointer.allocate(byteCount: max(1, a.count * MemoryLayout<T>.stride), alignment: 16)
			a.withUnsafeBytes { if let base = $0.baseAddress { p.copyMemory(from: base, byteCount: $0.count) } }
			buffers.append(p)
			return p
		}
		func shapePtr(_ s: [Int64]) -> UnsafeMutablePointer<Int64> {
			let p = UnsafeMutablePointer<Int64>.allocate(capacity: max(1, s.count))
			for (i, d) in s.enumerated() { p[i] = d }
			shapes.append(p)
			return p
		}
		var cin: [OrtwInput] = []
		for input in inputs {
			let name: String, type: Int32, data: UnsafeMutableRawPointer, shape: [Int64]
			switch input {
			case let .float(n, a, s): (name, type, data, shape) = (n, Int32(ORTW_FLOAT), copy(a), s)
			case let .int64(n, a, s): (name, type, data, shape) = (n, Int32(ORTW_INT64), copy(a), s)
			case let .int32(n, a, s): (name, type, data, shape) = (n, Int32(ORTW_INT32), copy(a), s)
			}
			let cname = strdup(name)!
			names.append(cname)
			cin.append(OrtwInput(name: cname, type: type, data: data, shape: shapePtr(shape), rank: Int32(shape.count)))
		}
		let outNames = outputs.map { strdup($0)! }
		names.append(contentsOf: outNames)
		var outNamePtrs: [UnsafePointer<CChar>?] = outNames.map { UnsafePointer($0) }
		var outValues = [OpaquePointer?](repeating: nil, count: outputs.count)
		var err = [CChar](repeating: 0, count: 512)
		let rc = ortw_run(handle, cin, Int32(cin.count), &outNamePtrs, Int32(outputs.count), &outValues, &err, err.count)
		guard rc == 0 else { throw OrtError(description: String(cString: err)) }
		return outValues.map { OrtTensor($0!) }
	}
}
