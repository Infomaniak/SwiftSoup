import XCTest
@testable import SwiftSoup

final class DeferredLookupRefinementTest: XCTestCase {
    private func pending(_ keys: [String], bytes: Bool = false) -> Attributes {
        Attributes(pendingAttributes: keys.enumerated().map { i, key in
            let raw = Array(key.utf8)
            return Attributes.PendingAttribute(nameSlice: bytes ? nil : ByteSlice.fromArray(raw),
                nameBytes: bytes ? raw : nil, hasUppercase: Attributes.containsAsciiUppercase(raw),
                value: .bytes(Array("v\(i)".utf8)))
        })
    }

    func testMissingExactLookupDoesNotMaterialize() {
        for count in [1, 8, 32, 64, 65, 256] {
            let attrs = pending((0..<count).map { "data-k\($0)" })
            XCTAssertEqual(attrs.get(key: "missing"), "")
            XCTAssertTrue(attrs.attributes.isEmpty)
            XCTAssertEqual(attrs.pendingAttributesCount, count)
            XCTAssertEqual(attrs.get(key: "data-k0"), "v0")
        }
    }

    func testMissingIgnoreCaseLookupDoesNotMaterialize() throws {
        for count in [1, 8, 32, 64, 65] {
            let attrs = pending((0..<count).map { "DATA-k\($0)" }, bytes: true)
            XCTAssertEqual(try attrs.getIgnoreCase(key: "missing"), "")
            XCTAssertTrue(attrs.attributes.isEmpty)
            XCTAssertEqual(try attrs.getIgnoreCase(key: "data-K0"), "v0")
        }
    }

    func testMissingSliceLookupDoesNotMaterialize() throws {
        let attrs = pending(["id", "title", "data-x"])
        XCTAssertEqual(try attrs.getIgnoreCaseSlice(key: Array("MISS".utf8)).count, 0)
        XCTAssertTrue(attrs.attributes.isEmpty)
        XCTAssertNil(attrs.valueSliceCaseSensitive(Array("miss".utf8)))
        XCTAssertTrue(attrs.attributes.isEmpty)
    }

    func testMissingPresenceLookupDoesNotMaterialize() {
        for kind in 0..<3 {
            let attrs = pending(["ID", "title", "data-x"])
            switch kind {
            case 0: XCTAssertFalse(attrs.hasKey(key: "missing"))
            case 1: XCTAssertFalse(attrs.hasKeyIgnoreCase(key: "MISSING"))
            default: XCTAssertFalse(attrs.hasKeyIgnoreCase(key: Array("?MISSING?".utf8).dropFirst().dropLast()))
            }
            XCTAssertTrue(attrs.attributes.isEmpty)
            XCTAssertTrue(attrs.hasKeyIgnoreCase(key: "id"))
        }
    }

    func testInvalidLookupIsAtomic() throws {
        for kind in 0..<2 {
            let attrs = pending(["id", "title"])
            if kind == 0 { XCTAssertThrowsError(try attrs.getIgnoreCase(key: "")) }
            else { XCTAssertThrowsError(try attrs.getIgnoreCaseSlice(key: [])) }
            XCTAssertTrue(attrs.attributes.isEmpty)
            XCTAssertEqual(attrs.pendingAttributesCount, 2)
        }
    }

    func testEmptyPresenceQueriesStayDeferred() {
        let attrs = pending(["id"])
        XCTAssertFalse(attrs.hasKey(key: ""))
        XCTAssertFalse(attrs.hasKeyIgnoreCase(key: ""))
        XCTAssertFalse(attrs.hasKeyIgnoreCase(key: Array<UInt8>()[...]))
        XCTAssertTrue(attrs.attributes.isEmpty)
    }

    func testNegativeLookupThenAppendAndMutation() throws {
        let attrs = pending(["id"])
        XCTAssertEqual(attrs.get(key: "title"), "")
        let incoming = pending(["title"])
        attrs.appendPending(incoming.pendingAttributes![0])
        XCTAssertEqual(attrs.get(key: "title"), "v0")
        let ref = try XCTUnwrap(attrs.asList().first { $0.getKey() == "title" })
        ref.setValue(value: Array("new".utf8))
        XCTAssertEqual(attrs.get(key: "title"), "new")
        try attrs.remove(key: "title")
        XCTAssertEqual(attrs.get(key: "title"), "")
    }

    func testMissingLookupStillNormalizesAmbiguousBatches() throws {
        let attrs = pending(["id", " id ", "\t", "id", "ID"])
        XCTAssertEqual(attrs.get(key: "missing"), "")
        XCTAssertEqual(attrs.get(key: "id"), "v3")
        XCTAssertEqual(try attrs.getIgnoreCase(key: "Id"), "v3")
        XCTAssertEqual(attrs.asList().map { $0.getKey() }, ["id", "ID"])
    }

    func testDistinctCollidingNamesRemainDeferred() {
        // Equal lengths and identical endpoints intentionally collide in the cheap prefilter.
        for count in [8, 32, 64, 65, 256] {
            let keys = (0..<count).map { String(format: "k%04dz", $0) }
            for bytes in [false, true] {
                let attrs = pending(keys, bytes: bytes)
                XCTAssertEqual(attrs.get(key: keys[count - 1]), "v\(count - 1)")
                XCTAssertTrue(attrs.attributes.isEmpty)
                XCTAssertEqual(attrs.size(), count)
            }
        }
    }

    func testDuplicateDetectionAtEverySmallBatchPosition() {
        for count in [2, 8, 32, 64, 65] {
            for index in 0..<(count - 1) {
                var keys = (0..<count).map { String(format: "k%04dz", $0) }
                keys[count - 1] = keys[index]
                let attrs = pending(keys, bytes: index.isMultiple(of: 2))
                XCTAssertEqual(attrs.get(key: keys[index]), "v\(count - 1)")
                XCTAssertEqual(attrs.size(), count - 1)
                XCTAssertEqual(attrs.asList()[index].getValue(), "v\(count - 1)")
            }
        }
    }

    func testValidationResetsAfterNegativeLookupAndRawReplacement() {
        let attrs = pending(["id", "title"])
        XCTAssertEqual(attrs.get(key: "none"), "")
        let replacement = pending(["id", "id"])
        attrs.pendingAttributes = replacement.pendingAttributes
        attrs.pendingAttributesCount = 2
        XCTAssertEqual(attrs.get(key: "id"), "v1")
        XCTAssertEqual(attrs.size(), 1)
    }

    func testColdNegativeLookupDoesNotDirtySourceOrSelectors() throws {
        let doc = try SwiftSoup.parse("<p id='a' data-x='v'>日本</p>")
        let p = try XCTUnwrap(doc.body()?.getChildNodes().first as? Element)
        let attrs = try XCTUnwrap(p.getAttributes())
        let before = p.sourceRangeDirty
        for _ in 0..<4 {
            XCTAssertEqual(try p.attr("missing"), "")
            XCTAssertFalse(p.hasAttr("missing"))
        }
        XCTAssertEqual(p.sourceRangeDirty, before)
        for _ in 0..<2 { XCTAssertEqual(try doc.select("[missing]").size(), 0) }
        try attrs.put("missing", "present")
        XCTAssertTrue(try doc.select("[missing=present]").first() === p)
    }
    func testNegativeLookupBeforeFragmentedValueRead() throws {
        var item = pending(["title"]).pendingAttributes![0]
        item.value = .slices([ByteSlice.fromArray([0xE6]), ByteSlice.fromArray([0x97, 0xA5])], 3)
        for kind in 0..<4 {
            let attrs = Attributes(pendingAttributes: [item])
            switch kind {
            case 0: XCTAssertEqual(attrs.get(key: "missing"), "")
            case 1: XCTAssertEqual(try attrs.getIgnoreCase(key: "MISSING"), "")
            case 2: XCTAssertFalse(attrs.hasKeyIgnoreCase(key: "missing"))
            default: XCTAssertTrue(try attrs.getIgnoreCaseSlice(key: Array("missing".utf8)).isEmpty)
            }
            XCTAssertTrue(attrs.attributes.isEmpty)
            XCTAssertEqual(try attrs.getIgnoreCaseSlice(key: Array("TITLE".utf8)).toArray(), Array("日".utf8))
            XCTAssertTrue(attrs.attributes.isEmpty)
            XCTAssertEqual(attrs.asList().first?.getValue(), "日")
        }
    }

    func testGeneratedMixedNameStorageAndEveryPositionDuplicate() throws {
        // Exercise the prefilter limit and the set fallback with mixed storage.
        for count in [1, 2, 7, 8, 9, 31, 32, 63, 64, 65, 127, 128, 129] {
            for seed in 0..<8 {
                let keys = (0..<count).map { "日本-\(seed)-\($0)-e\u{301}" }
                var items = pending(keys).pendingAttributes!
                for index in items.indices where index.isMultiple(of: 2) {
                    items[index].nameBytes = Array(keys[index].utf8)
                    items[index].nameSlice = ByteSlice.fromArray(Array("ignored-\(index)".utf8))
                }
                let attrs = Attributes(pendingAttributes: items)
                XCTAssertEqual(attrs.get(key: "missing"), "")
                XCTAssertTrue(attrs.attributes.isEmpty)
                for (index, key) in keys.enumerated() {
                    XCTAssertEqual(attrs.get(key: key), "v\(index)")
                }
                XCTAssertTrue(attrs.attributes.isEmpty)
                if count > 1 {
                    let duplicate = (seed * 13) % (count - 1)
                    items[count - 1].nameBytes = Array(keys[duplicate].utf8)
                    let repeated = Attributes(pendingAttributes: items)
                    XCTAssertEqual(repeated.get(key: keys[duplicate]), "v\(count - 1)")
                    XCTAssertEqual(repeated.size(), count - 1)
                }
            }
        }
    }

    func testEmptyPendingBatchCanBeReadThenAppended() throws {
        let attrs = Attributes(pendingAttributes: [])
        XCTAssertEqual(attrs.get(key: "none"), "")
        XCTAssertEqual(try attrs.getIgnoreCase(key: "NONE"), "")
        XCTAssertFalse(attrs.hasKeyIgnoreCase(key: "none"))
        for item in pending(["id", "id"]).pendingAttributes! { attrs.appendPending(item) }
        XCTAssertEqual(attrs.get(key: "id"), "v1")
        XCTAssertEqual(attrs.size(), 1)
    }

    func testNegativeReadThenSharedMutationStillNotifiesBothOwners() throws {
        let attrs = pending(["id", "class"])
        XCTAssertFalse(attrs.hasKey(key: "missing"))
        let a = try SwiftSoup.parse("<p></p>")
        let b = try SwiftSoup.parse("<p></p>")
        let pa = try XCTUnwrap(a.select("p").first())
        let pb = try XCTUnwrap(b.select("p").first())
        pa.getAttributes()!.addAll(incoming: attrs)
        pb.getAttributes()!.addAll(incoming: attrs)
        for doc in [a, b] { XCTAssertEqual(try doc.select("#v0").size(), 1) }
        let id = try XCTUnwrap(attrs.asList().first { $0.getKey() == "id" })
        id.setValue(value: Array("updated".utf8))
        for doc in [a, b] {
            XCTAssertEqual(try doc.select("#v0").size(), 0)
            XCTAssertEqual(try doc.select("#updated").size(), 1)
        }
    }

}
