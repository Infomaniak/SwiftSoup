import XCTest
@testable import SwiftSoup

final class AttributeMaterializationTest: XCTestCase {
    private func pending(_ key: String, _ value: String? = nil) -> Attributes.PendingAttribute {
        let bytes = Array(key.utf8)
        return Attributes.PendingAttribute(
            nameSlice: ByteSlice.fromArray(bytes), nameBytes: nil,
            hasUppercase: Attributes.containsAsciiUppercase(bytes),
            value: value.map { $0.isEmpty ? .empty : .slice(ByteSlice.fromArray(Array($0.utf8))) } ?? .none
        )
    }

    private func appendDeferred(_ items: [Attributes.PendingAttribute], to attrs: Attributes) {
        attrs.pendingAttributes = items
        attrs.pendingAttributesCount = items.count
    }

    func testDuplicateKeysKeepFirstPositionAndLastValue() throws {
        let attrs = Attributes()
        for item in [pending("data-a", "first"), pending("Class", "upper"),
                     pending("class", "lower"), pending("data-a", "last"),
                     pending("disabled"), pending("empty", ""), pending(" \t ", "drop")] {
            attrs.appendPending(item)
        }
        XCTAssertEqual(Array(attrs).map { $0.getKey() }, ["data-a", "Class", "class", "disabled", "empty"])
        XCTAssertEqual(attrs.get(key: "data-a"), "last")
        XCTAssertEqual(try attrs.getIgnoreCase(key: "CLASS"), "upper")
        XCTAssertTrue(Array(attrs)[3] is BooleanAttribute)
        XCTAssertFalse(Array(attrs)[4] is BooleanAttribute)
        XCTAssertEqual(attrs.pendingAttributesCount, 0)
        XCTAssertTrue(attrs.pendingAttributes?.isEmpty ?? true)
    }

    func testMaterializationRebuildsAnExistingKeyIndex() throws {
        let attrs = Attributes()
        for i in 0..<16 { try attrs.put("k\(i)", "v\(i)") }
        attrs.ensureKeyIndex()
        XCTAssertFalse(attrs.keyIndexDirty)
        appendDeferred([pending("k3", "replacement"), pending("k16", "new"), pending("k3", "last")], to: attrs)
        attrs.ensureMaterialized()
        XCTAssertEqual(attrs.size(), 17)
        XCTAssertEqual(attrs.get(key: "k3"), "last")
        XCTAssertEqual(attrs.get(key: "k16"), "new")
        for (index, attr) in Array(attrs).enumerated() {
            XCTAssertEqual(attrs.keyIndex?[attr.keySlice], index)
        }
    }

    func testMaterializationInvalidatesWarmedOwnerIndexes() throws {
        let doc = try SwiftSoup.parse("<html><head></head><body><div id='old' class='before' data-x='one' title='t'></div></body></html>")
        doc.outputSettings().prettyPrint(pretty: false)
        let element = try XCTUnwrap(doc.body()?.children().first())
        let attrs = try XCTUnwrap(element.getAttributes())
        _ = Array(attrs)
        for _ in 0..<4 {
            XCTAssertEqual(try doc.select(".before").size(), 1)
            XCTAssertEqual(try doc.select("#old").size(), 1)
            XCTAssertEqual(try doc.select("[data-x=one]").size(), 1)
            XCTAssertEqual(try doc.select("[data-new]").size(), 0)
        }
        appendDeferred([pending("id", "new"), pending("class", "after"),
                        pending("data-x", "two"), pending("data-new", "yes")], to: attrs)
        attrs.ensureMaterialized()
        XCTAssertEqual(try doc.select(".before, #old, [data-x=one]").size(), 0)
        XCTAssertTrue(try doc.select(".after#new[data-x=two][data-new]").first() === element)
        let reparsed = try SwiftSoup.parse(String(decoding: doc.outerHtmlUTF8(), as: UTF8.self))
        XCTAssertEqual(try reparsed.select(".after#new[data-x=two][data-new]").size(), 1)
        try attrs.put("class", "again")
        XCTAssertEqual(try doc.select(".after").size(), 0)
        XCTAssertEqual(try doc.select(".again").size(), 1)
    }

    func testInvalidPendingNamesPreserveExistingValues() throws {
        let attrs = Attributes()
        try attrs.put("id", "kept")
        appendDeferred([pending(" \t\n", "discarded"), pending("", "discarded")], to: attrs)
        attrs.ensureMaterialized()
        XCTAssertEqual(Array(attrs).map { $0.getKey() }, ["id"])
        XCTAssertEqual(attrs.get(key: "id"), "kept")
        XCTAssertEqual(attrs.pendingAttributesCount, 0)
    }

    func testWideDeferredAttributesSupportRemovalAndCaseInsensitiveLookup() throws {
        let attrs = Attributes()
        for i in 0..<128 { attrs.appendPending(pending("Data-Key-\(i)", "v\(i)")) }
        attrs.appendPending(pending("Data-Key-63", "changed"))
        XCTAssertEqual(Array(attrs).count, 128)
        XCTAssertEqual(try attrs.getIgnoreCase(key: "data-key-63"), "changed")
        try attrs.remove(key: "Data-Key-62")
        XCTAssertEqual(try attrs.getIgnoreCase(key: "DATA-KEY-63"), "changed")
        attrs.lowercaseAllKeys()
        XCTAssertEqual(attrs.get(key: "data-key-127"), "v127")
        XCTAssertEqual(attrs.size(), 127)
    }

    func testMultiSliceAndByteValuesMaterializeUnchanged() throws {
        let attrs = Attributes()
        var split = pending("data-split")
        split.value = .slices([ByteSlice.fromArray(Array("日本".utf8)), ByteSlice.fromArray(Array("語&".utf8))], 10)
        var bytes = pending("data-bytes")
        bytes.nameSlice = nil
        bytes.nameBytes = Array(" data-bytes ".utf8)
        bytes.value = .bytes(Array("value<&".utf8))
        attrs.appendPending(split)
        attrs.appendPending(bytes)
        _ = Array(attrs)
        XCTAssertEqual(attrs.get(key: "data-split"), "日本語&")
        XCTAssertEqual(attrs.get(key: "data-bytes"), "value<&")
        XCTAssertTrue(try attrs.html().contains("日本語&amp;"))
    }
    func testDeferredBatchesMatchOrderedReferenceAtThresholds() throws {
        for existingCount in [0, 1, 3, 4, 8] {
            for batchCount in [0, 1, 2, 3, 4, 5, 16, 129] {
                let attrs = Attributes()
                var expected: [(String, String)] = []
                for index in 0..<existingCount {
                    let key = "key-\(index)"
                    try attrs.put(key, "initial")
                    expected.append((key, "initial"))
                }
                attrs.ensureKeyIndex()
                let oldArray = Array(attrs)
                var deferred: [Attributes.PendingAttribute] = []
                for index in 0..<batchCount {
                    let rawKey = index % 11 == 0 ? " \t " : " key-\(index % 9) "
                    let value = "value-\(index)"
                    deferred.append(pending(rawKey, value))
                    let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    if key.isEmpty { continue }
                    if let position = expected.firstIndex(where: { $0.0 == key }) {
                        expected[position] = (key, value)
                    } else {
                        expected.append((key, value))
                    }
                }
                appendDeferred(deferred, to: attrs)
                attrs.ensureMaterialized()
                XCTAssertEqual(Array(attrs).map { $0.getKey() }, expected.map { $0.0 })
                XCTAssertEqual(Array(attrs).map { $0.getValue() }, expected.map { $0.1 })
                XCTAssertEqual(oldArray.map { $0.getValue() }, Array(repeating: "initial", count: existingCount))
                for (key, value) in expected { XCTAssertEqual(attrs.get(key: key), value) }
            }
        }
    }

}
