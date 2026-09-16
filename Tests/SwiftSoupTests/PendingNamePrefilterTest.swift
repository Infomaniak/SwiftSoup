import XCTest
@testable import SwiftSoup

final class PendingNamePrefilterTest: XCTestCase {
    private func pending(_ names: [String], bytes: Bool) -> Attributes {
        Attributes(pendingAttributes: names.enumerated().map { i, name in
            let key = Array(name.utf8)
            return Attributes.PendingAttribute(nameSlice: bytes ? nil : ByteSlice.fromArray(key), nameBytes: bytes ? key : nil,
                hasUppercase: Attributes.containsAsciiUppercase(key), value: .bytes(Array("v\(i)".utf8)))
        })
    }
    func testAllSmallBatchSizesRemainDeferredForUniqueNames() throws {
        for bytes in [false,true] {
            for n in 1...32 {
                let attrs = pending((0..<n).map { "data-k\($0)" }, bytes: bytes)
                XCTAssertEqual(attrs.get(key: "data-k0"), "v0")
                XCTAssertTrue(attrs.attributes.isEmpty, "\(bytes) \(n)")
                XCTAssertEqual(try attrs.getIgnoreCase(key: "DATA-K\(n-1)"), "v\(n-1)")
                XCTAssertTrue(attrs.attributes.isEmpty)
            }
        }
    }
    func testPrefilterCollisionsDoNotMergeDistinctNames() throws {
        // Same length, first byte and final two bytes: all hit the same prefilter bit.
        for bytes in [false,true] {
            for n in [8,31,32,33,64] {
                let names = (0..<n).map { "a\(String(format: "%03d", $0))zz" }
                let attrs = pending(names, bytes: bytes)
                for (i,key) in names.enumerated() { XCTAssertEqual(attrs.get(key: key), "v\(i)") }
                XCTAssertTrue(attrs.attributes.isEmpty)
                XCTAssertEqual(attrs.size(), n)
            }
        }
    }
    func testDuplicatesAtEverySmallBatchPositionUseLastValue() throws {
        for bytes in [false,true] {
            for n in [2,8,16,32,33] {
                for duplicate in 0..<(n-1) {
                    var names = (0..<n).map { "data-k\($0)" }; names[n-1] = names[duplicate]
                    let attrs = pending(names, bytes: bytes)
                    XCTAssertEqual(attrs.get(key: names[duplicate]), "v\(n-1)")
                    XCTAssertEqual(attrs.size(), n-1)
                }
            }
        }
    }
    func testValidationResetsAcrossThresholdAndRawReplacement() throws {
        let attrs = pending((0..<32).map { "k\($0)" }, bytes: false)
        XCTAssertEqual(attrs.get(key: "k0"), "v0")
        var last = try XCTUnwrap(attrs.pendingAttributes?.first)
        last.value = .bytes(Array("replacement".utf8))
        attrs.appendPending(last)
        XCTAssertEqual(attrs.get(key: "k0"), "replacement")
        XCTAssertEqual(attrs.size(), 32)
    }
    func testInvalidAndPaddedNamesAtThresholdMatchMaterializer() throws {
        for n in [8,32,33,128] {
            for bytes in [false,true] {
                let names = (0..<n).map { "k\($0)" } + [" k0 ", "\t", "\r", "\u{B}"]
                let attrs = pending(names, bytes: bytes)
                XCTAssertEqual(attrs.get(key: "k0"), "v\(n)")
                XCTAssertEqual(attrs.size(), n)
                XCTAssertFalse(attrs.hasKey(key: "\t"))
            }
        }
    }
    func testUnicodeByteDistinctKeysAndMixedCaseRemainDistinct() throws {
        for bytes in [false,true] {
            let names = ["é", "e\u{301}", "日本", "ID", "id"] + (0..<28).map { "x\($0)" }
            let attrs = pending(names, bytes: bytes)
            for i in names.indices { XCTAssertEqual(attrs.get(key: names[i]), "v\(i)") }
            XCTAssertEqual(try attrs.getIgnoreCase(key: "id"), "v3")
            XCTAssertEqual(attrs.size(), 33)
        }
    }
}
