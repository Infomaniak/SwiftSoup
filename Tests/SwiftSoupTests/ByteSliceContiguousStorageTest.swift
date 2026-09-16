import Foundation
import XCTest
@testable import SwiftSoup

final class ByteSliceContiguousStorageTest: XCTestCase {
    private func read<C: Collection, R>(_ value: C,
                                      _ body: (UnsafeBufferPointer<C.Element>) throws -> R) rethrows -> R? {
        try value.withContiguousStorageIfAvailable(body)
    }

    private func check(_ storage: ByteStorage, count: Int) throws {
        for start in 0...count {
            for end in start...count {
                let slice = ByteSlice(storage: storage, start: start, end: end)
                var calls = 0
                let observed = read(slice) { buffer -> [UInt8] in
                    calls += 1
                    return Array(buffer)
                }
                XCTAssertEqual(calls, 1)
                XCTAssertEqual(observed, slice.toArray())
                XCTAssertEqual(Array(slice), slice.toArray())
                XCTAssertEqual(String(decoding: slice, as: UTF8.self),
                               String(decoding: slice.toArray(), as: UTF8.self))
            }
        }
    }

    func testGenericDispatchAllRangesAndBackings() throws {
        let bytes = Array("a日本😀é".utf8) + [0, 255]
        try check(ByteStorage(array: bytes), count: bytes.count)
        try check(ByteStorage(data: Data([249] + bytes).dropFirst()), count: bytes.count)
        try bytes.withUnsafeBufferPointer { buffer in
            try check(ByteStorage(buffer: buffer.baseAddress!, count: buffer.count, owner: nil),
                      count: buffer.count)
        }
        try check(ByteStorage(array: []), count: 0)
        try check(ByteStorage(data: Data()), count: 0)
    }

    func testOptionalResultRemainsAnInvokedClosure() {
        for slice in [ByteSlice.empty, .fromArray([0, 255])] {
            var calls = 0
            let result: Int?? = read(slice) { _ -> Int? in
                calls += 1
                return nil
            }
            guard case .some(.none) = result else {
                XCTFail("An invoked closure returning nil must not mean unavailable storage")
                continue
            }
            XCTAssertEqual(calls, 1)
        }
    }

    func testThrowingClosurePropagatesUnchanged() {
        enum Failure: Error { case expected }
        for slice in [ByteSlice.empty, .fromArray([0, 255])] {
            XCTAssertThrowsError(try read(slice) { _ -> Int in throw Failure.expected }) {
                guard case Failure.expected = $0 else {
                    XCTFail("Unexpected error: \($0)")
                    return
                }
            }
        }
    }

    func testMalformedDecodingMatchesArrays() {
        let cases = (0...255).map { [UInt8($0)] } + [Array(0...255), [240, 159], [192, 175], [237, 160, 128]]
        for bytes in cases {
            let storage = ByteStorage(data: Data([250] + bytes + [251]))
            let slice = ByteSlice(storage: storage, start: 1, end: bytes.count + 1)
            XCTAssertEqual(String(decoding: slice, as: UTF8.self), String(decoding: bytes, as: UTF8.self))
            XCTAssertEqual(Array(slice), bytes)
        }
    }

    func testTemporaryOwnedBufferSurvivesTheClosure() {
        final class Owner {
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            init() {
                for i in 0..<4096 { pointer.advanced(by: i).initialize(to: UInt8(i % 251)) }
            }
            deinit { pointer.deinitialize(count: 4096); pointer.deallocate() }
        }
        weak var observedOwner: Owner?
        func makeSlice() -> ByteSlice {
            let owner = Owner()
            observedOwner = owner
            return ByteSlice(storage: ByteStorage(buffer: UnsafePointer(owner.pointer), count: 4096, owner: owner),
                             start: 5, end: 4090)
        }
        func consumeTemporary() {
            let bytes = read(makeSlice()) { buffer in
                XCTAssertNotNil(observedOwner)
                XCTAssertEqual(buffer.count, 4085)
                return Array(buffer)
            }
            XCTAssertEqual(bytes, (5..<4090).map { UInt8($0 % 251) })
        }
        consumeTemporary()
        XCTAssertNil(observedOwner)
    }
}