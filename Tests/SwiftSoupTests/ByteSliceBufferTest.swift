import XCTest
@testable import SwiftSoup

final class ByteSliceBufferTest: XCTestCase {
    private final class Owner {
        let pointer: UnsafeMutablePointer<UInt8>
        let count: Int
        init(_ bytes: [UInt8]) {
            count = bytes.count
            pointer = .allocate(capacity: max(count, 1))
            for (index, byte) in bytes.enumerated() { pointer.advanced(by: index).initialize(to: byte) }
        }
        deinit { pointer.deinitialize(count: count); pointer.deallocate() }
    }

    private func views(_ bytes: [UInt8], offset: Int) -> [ByteSlice] {
        let padded = Array(repeating: UInt8(253), count: offset) + bytes + [254, 255]
        let owner = Owner(padded)
        let storages = [ByteStorage(array: padded), ByteStorage(data: Data(padded)),
                        ByteStorage(buffer: UnsafePointer(owner.pointer), count: padded.count, owner: owner)]
        var result = storages.map { ByteSlice(storage: $0, start: offset, end: offset + bytes.count) }
        let nonzeroData = Data([1, 2, 3] + padded).dropFirst(3)
        result.append(ByteSlice(storage: ByteStorage(data: nonzeroData), start: offset, end: offset + bytes.count))
        result.append(ByteSlice.fromArray([42] + bytes + [43])[1..<(bytes.count + 1)])
        return result
    }

    func testEqualViewsHashIdenticallyAcrossStorageAndOffsets() {
        for length in [0, 1, 2, 7, 8, 15, 16, 17, 31, 32, 63, 64, 65, 255, 256, 257] {
            let bytes = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 37) }
            for offset in 0..<8 {
                let slices = views(bytes, offset: offset)
                let referenceHash = slices[0].hashValue
                for lhs in slices {
                    XCTAssertEqual(lhs.toArray(), bytes)
                    XCTAssertEqual(lhs.hashValue, referenceHash)
                    for rhs in slices { XCTAssertEqual(lhs, rhs) }
                }
                XCTAssertEqual(Set(slices).count, 1)
                let dictionary = [slices[0]: length]
                for slice in slices { XCTAssertEqual(dictionary[slice], length) }
            }
        }
    }

    func testDifferentBytesAndLengthsDoNotCompareEqual() {
        for length in [1, 2, 7, 8, 15, 16, 17, 31, 32, 63, 64, 65, 257] {
            let bytes = (0..<length).map { UInt8(truncatingIfNeeded: $0) }
            let originals = views(bytes, offset: 3)
            for index in Set([0, length / 2, length - 1]) {
                var changed = bytes
                changed[index] ^= 255
                for lhs in originals {
                    for rhs in views(changed, offset: 7) { XCTAssertNotEqual(lhs, rhs) }
                }
            }
            for lhs in originals { XCTAssertNotEqual(lhs, ByteSlice.fromArray(bytes + [0])) }
        }
    }

    func testEmptyAndZeroContainingViews() {
        let empty = views([], offset: 4)
        for slice in empty { XCTAssertEqual(slice, ByteSlice.empty) }
        let values: [[UInt8]] = [[], [0], [0, 0], [0, 1], [1, 0], [255, 0, 254]]
        var dictionary: [ByteSlice: Int] = [:]
        for (i, bytes) in values.enumerated() { dictionary[views(bytes, offset: 1)[0]] = i }
        for (i, bytes) in values.enumerated() {
            for slice in views(bytes, offset: 6) { XCTAssertEqual(dictionary[slice], i) }
        }
    }
    func testEqualityWithLongCommonPrefixes() {
        for length in [511, 512, 1023, 1024, 4095, 4096] {
            let bytes = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 37) }
            let original = ByteSlice.fromArray(bytes)
            for offset in [0, 1, 3, 7] {
                for view in views(bytes, offset: offset) { XCTAssertEqual(original, view) }
                for index in [0, length / 2, length - 1] {
                    var changed = bytes
                    changed[index] ^= 255
                    for view in views(changed, offset: offset) {
                        XCTAssertNotEqual(original, view)
                        XCTAssertNotEqual(view, original)
                    }
                }
            }
        }
    }

    func testASCIIScansMatchArrayReferenceAcrossBackingStores() {
        func whitespace(_ byte: UInt8) -> Bool { byte == 32 || (byte >= 9 && byte <= 13) }
        var cases: [[UInt8]] = [[], [32], [9, 10, 11, 12, 13, 32], [0, 65, 0], [65], [90], [91], [64], [97], [255]]
        cases += (0..<256).map { [UInt8($0)] }
        cases += (0..<80).map { i in Array(repeating: UInt8(32), count: i % 7) + Array(("AbC-日本語-" + String(i)).utf8) + [13, 10] }
        for bytes in cases {
            let expectedLower = bytes.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
            var begin = 0
            var end = bytes.count
            while begin < end && whitespace(bytes[begin]) { begin += 1 }
            while begin < end && whitespace(bytes[end - 1]) { end -= 1 }
            for offset in [0, 3, 7] {
                for view in views(bytes, offset: offset) {
                    XCTAssertEqual(view.lowercased().toArray(), expectedLower)
                    XCTAssertEqual(view.trim().toArray(), Array(bytes[begin..<end]))
                    XCTAssertTrue(view.trim().storage === view.storage)
                    XCTAssertEqual(Attributes.containsAsciiUppercase(view), bytes.contains { $0 >= 65 && $0 <= 90 })
                    XCTAssertEqual(view.toArray(), bytes)
                    if expectedLower == bytes { XCTAssertTrue(view.lowercased().storage === view.storage) }
                }
            }
        }
    }

}
