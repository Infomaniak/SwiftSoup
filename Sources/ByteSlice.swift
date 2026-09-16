import Foundation

@usableFromInline
final class ByteStorage: @unchecked Sendable {
    @usableFromInline
    enum Backing {
        case array([UInt8])
        case data(Data)
        case buffer(UnsafePointer<UInt8>, Int, AnyObject?)
    }

    @usableFromInline
    let backing: Backing

    @usableFromInline
    init(array: [UInt8]) {
        self.backing = .array(array)
    }

    @usableFromInline
    init(data: Data) {
        self.backing = .data(data)
    }

    @usableFromInline
    init(buffer base: UnsafePointer<UInt8>, count: Int, owner: AnyObject?) {
        self.backing = .buffer(base, count, owner)
    }

    @inline(__always)
    func byte(at index: Int) -> UInt8 {
        switch backing {
        case .array(let array):
            return array[index]
        case .data(let data):
            return data[data.startIndex + index]
        case .buffer(let base, _, _):
            return base[index]
        }
    }

    @inline(__always)
    func withUnsafeBytes<R>(_ start: Int, _ end: Int, _ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        let length = end - start
        switch backing {
        case .array(let array):
            return try array.withUnsafeBufferPointer { buf in
                let base = buf.baseAddress
                let slice = UnsafeBufferPointer(start: base == nil ? nil : base! + start, count: length)
                return try body(slice)
            }
        case .data(let data):
            return try data.withUnsafeBytes { raw in
                let base = raw.bindMemory(to: UInt8.self).baseAddress
                let slice = UnsafeBufferPointer(start: base == nil ? nil : base! + start, count: length)
                return try body(slice)
            }
        case .buffer(let base, _, _):
            let slice = UnsafeBufferPointer(start: base + start, count: length)
            return try body(slice)
        }
    }

    @inline(__always)
    func toArray(_ start: Int, _ end: Int) -> [UInt8] {
        let length = end - start
        if length <= 0 { return [] }
        switch backing {
        case .array(let array):
            return Array(array[start..<end])
        case .data(let data):
            return Array(data[data.startIndex + start ..< data.startIndex + end])
        case .buffer(let base, _, _):
            return Array(UnsafeBufferPointer(start: base + start, count: length))
        }
    }

    @inline(__always)
    func toArraySlice(_ start: Int, _ end: Int) -> ArraySlice<UInt8> {
        switch backing {
        case .array(let array):
            return array[start..<end]
        case .data:
            return ArraySlice(toArray(start, end))
        case .buffer:
            return ArraySlice(toArray(start, end))
        }
    }
}

@usableFromInline
struct ByteSlice: RandomAccessCollection, Hashable, Sendable {
    @usableFromInline typealias Index = Int
    @usableFromInline typealias Element = UInt8
    @usableFromInline typealias SubSequence = ByteSlice

    @usableFromInline
    let storage: ByteStorage
    @usableFromInline
    let start: Int
    @usableFromInline
    let end: Int

    @inline(__always)
    init(storage: ByteStorage, start: Int, end: Int) {
        self.storage = storage
        self.start = start
        self.end = end
    }

    @usableFromInline
    @inline(__always)
    var startIndex: Int { 0 }

    @usableFromInline
    @inline(__always)
    var endIndex: Int { end - start }

    @usableFromInline
    @inline(__always)
    var count: Int { end - start }

    @usableFromInline
    @inline(__always)
    var isEmpty: Bool { start >= end }

    @usableFromInline
    @inline(__always)
    subscript(position: Int) -> UInt8 {
        return storage.byte(at: start + position)
    }

    @usableFromInline
    @inline(__always)
    subscript(bounds: Range<Int>) -> ByteSlice {
        return ByteSlice(storage: storage, start: start + bounds.lowerBound, end: start + bounds.upperBound)
    }

    @usableFromInline
    @inline(__always)
    func toArray() -> [UInt8] {
        return storage.toArray(start, end)
    }

    @usableFromInline
    @inline(__always)
    func toArraySlice() -> ArraySlice<UInt8> {
        return storage.toArraySlice(start, end)
    }

    @usableFromInline
    @inline(__always)
    func withUnsafeBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        return try storage.withUnsafeBytes(start, end, body)
    }

    @usableFromInline
    @inline(__always)
    func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        return try withUnsafeBytes(body)
    }

    /// All backing stores expose contiguous bytes for the duration of the closure.
    @usableFromInline
    @inline(__always)
    func withContiguousStorageIfAvailable<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R? {
        return try withUnsafeBytes(body)
    }
}

extension ByteSlice {
    @usableFromInline
    static let emptyStorage = ByteStorage(array: [])
    @usableFromInline
    static let empty = ByteSlice(storage: emptyStorage, start: 0, end: 0)

    @inline(__always)
    func lowercased() -> ByteSlice {
        return withUnsafeBytes { bytes in
            guard let firstUppercase = bytes.firstIndex(where: { $0 >= 65 && $0 <= 90 }) else {
                return self
            }
            var lowered = Array(bytes)
            for index in firstUppercase..<lowered.count {
                let byte = lowered[index]
                if byte >= 65 && byte <= 90 {
                    lowered[index] = byte + 32
                }
            }
            return ByteSlice.fromArray(lowered)
        }
    }

    @inline(__always)
    func trim() -> ByteSlice {
        return withUnsafeBytes { bytes in
            @inline(__always)
            func isWhitespace(_ byte: UInt8) -> Bool {
                return byte == TokeniserStateVars.spaceByte ||
                    (byte >= TokeniserStateVars.tabByte && byte <= TokeniserStateVars.carriageReturnByte)
            }
            var lower = 0
            var upper = bytes.count
            while lower < upper, isWhitespace(bytes[lower]) { lower += 1 }
            while lower < upper, isWhitespace(bytes[upper - 1]) { upper -= 1 }
            return self[lower..<upper]
        }
    }

}

extension ByteSlice {
    @usableFromInline
    @inline(__always)
    static func fromArray(_ array: [UInt8]) -> ByteSlice {
        let storage = ByteStorage(array: array)
        return ByteSlice(storage: storage, start: 0, end: array.count)
    }

    @usableFromInline
    @inline(__always)
    static func fromArraySlice(_ slice: ArraySlice<UInt8>) -> ByteSlice {
        return fromArray(Array(slice))
    }
}

extension ByteSlice {
    @usableFromInline
    @inline(__always)
    static func == (lhs: ByteSlice, rhs: ByteSlice) -> Bool {
        if lhs.count != rhs.count { return false }
        return lhs.withUnsafeBytes { left in
            rhs.withUnsafeBytes { right in
                for index in 0..<left.count {
                    if left[index] != right[index] { return false }
                }
                return true
            }
        }
    }

    @usableFromInline
    @inline(__always)
    func hash(into hasher: inout Hasher) {
        hasher.combine(count)
        withUnsafeBytes { bytes in
            hasher.combine(bytes: UnsafeRawBufferPointer(bytes))
        }
    }
}
