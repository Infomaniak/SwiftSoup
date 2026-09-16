import XCTest
@testable import SwiftSoup

final class AttributeValueIndexUpdateTest: XCTestCase {
    private func assertMatchesScan(_ root: Element, _ key: String, _ value: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        // Do not use Collector.collect here: it can use the same value index.
        let evaluator = try Evaluator.AttributeWithValue(key, value)
        var expected: [Element] = []
        var stack = [root]
        while let element = stack.popLast() {
            if try evaluator.matches(root, element) { expected.append(element) }
            for child in element.getChildNodes().reversed() {
                if let child = child as? Element { stack.append(child) }
            }
        }
        let actual = try root.getElementsByAttributeValue(key, value)
        XCTAssertEqual(actual.array().map(ObjectIdentifier.init), expected.map(ObjectIdentifier.init), file: file, line: line)
    }

    func testCombinedIndexPreservesUniqueRepeatedAndNormalizedValues() throws {
        let html = "<main>" + (0..<100).map {
            "<a id='n\($0)' class='link' href=' /ITEM/\($0) ' rel=' TAG ' data-kind='k\($0 % 7)'>text</a>"
        }.joined() + "<a href='/日本語' rel='tag'></a></main>"
        let doc = try SwiftSoup.parse(html)
        XCTAssertNil(doc.normalizedAttributeValueIndex)
        try assertMatchesScan(doc, "href", "/item/50")
        try assertMatchesScan(doc, "rel", "tag")
        try assertMatchesScan(doc, "href", "/日本語")
        try assertMatchesScan(doc, "href", "missing")
        XCTAssertEqual(try doc.getElementsByAttributeValue("rel", "tag").size(), 101)
        XCTAssertFalse(doc.isClassQueryIndexDirty)
        XCTAssertNotNil(doc.normalizedClassNameIndex)
    }

    func testSoloIndexRebuildAfterMutationPreservesOtherIndexes() throws {
        let doc = try SwiftSoup.parse("<main><a href='/one' rel='tag'>one</a><a href='/two' rel='tag'>two</a></main>")
        doc.materializeAttributesRecursively()
        doc.rebuildQueryIndexesForAllTags()
        XCTAssertNotNil(doc.normalizedClassNameIndex)
        XCTAssertNotNil(doc.normalizedIdIndex)
        XCTAssertNotNil(doc.normalizedAttributeNameIndex)
        let link = try XCTUnwrap(doc.getElementsByTag("a").first())
        try link.attr("href", "/new")
        // Prepare unchanged index categories so only the value index is rebuilt.
        doc.rebuildQueryIndexesForAllTags()
        let snapshot = try XCTUnwrap(doc.normalizedAttributeValueIndex)
        doc.isAttributeValueQueryIndexDirty = true
        doc.rebuildQueryIndexesForHotAttributes()
        try assertMatchesScan(doc, "href", "/new")
        try assertMatchesScan(doc, "rel", "tag")
        let key = ByteSlice.fromArray(Array("rel".utf8))
        let value = ByteSlice.fromArray(Array("tag".utf8))
        XCTAssertEqual(snapshot[key]?[value]?.compactMap(\.value).map(ObjectIdentifier.init),
                       doc.normalizedAttributeValueIndex?[key]?[value]?.compactMap(\.value).map(ObjectIdentifier.init))
        XCTAssertFalse(doc.isClassQueryIndexDirty)
        XCTAssertFalse(doc.isIdQueryIndexDirty)
        XCTAssertFalse(doc.isAttributeQueryIndexDirty)
    }

    func testDynamicKeysRebuildAndEvictWithoutChangingResults() throws {
        let attrs = (0..<12).map { "data-k\($0)='v\($0)'" }.joined(separator: " ")
        let doc = try SwiftSoup.parse("<div \(attrs)></div><span \(attrs)></span>")
        for key in 0..<12 { try assertMatchesScan(doc, "data-k\(key)", "v\(key)") }
        for key in (0..<12).reversed() { try assertMatchesScan(doc, "data-k\(key)", "v\(key)") }
        XCTAssertLessThanOrEqual(doc.dynamicAttributeValueIndexKeySet?.count ?? 0, Element.dynamicAttributeValueIndexMaxKeys)
    }

    func testValueIndexTracksRepeatedMutationsRemovalAndMoves() throws {
        let doc = try SwiftSoup.parse("<main><a id='a' href='/old' rel='tag'></a><section><a id='b' href='/old' rel='tag'></a></section></main>")
        let a = try XCTUnwrap(doc.getElementById("a"))
        let section = try XCTUnwrap(doc.getElementsByTag("section").first())
        for _ in 0..<4 { try assertMatchesScan(doc, "href", "/old") }
        try a.attr("href", "/new")
        try assertMatchesScan(doc, "href", "/old")
        try assertMatchesScan(doc, "href", "/new")
        try a.removeAttr("href")
        try assertMatchesScan(doc, "href", "/new")
        try a.attr("href", "/old")
        try section.appendChild(a)
        try assertMatchesScan(doc, "href", "/old")
        let ids = try doc.getElementsByAttributeValue("href", "/old").map { try $0.attr("id") }
        XCTAssertEqual(ids, ["b", "a"])
    }
}
