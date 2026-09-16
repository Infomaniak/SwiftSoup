import XCTest
@testable import SwiftSoup

final class AttributeInvalidationTraversalTest: XCTestCase {
    func testAllAncestorAttributeIndexesAreInvalidatedWithoutDirtyingTags() throws {
        let doc = try SwiftSoup.parse("<html><head></head><body><main><section><a id='old' class='before' href='/old'>text</a></section></main></body></html>")
        doc.outputSettings().prettyPrint(pretty: false)
        doc.materializeAttributesRecursively()
        let target = try XCTUnwrap(doc.getElementsByTag("a").first())
        var roots: [Element] = [target]
        var parent = target.parent()
        while let root = parent { roots.append(root); parent = root.parent() }
        for root in roots {
            root.rebuildQueryIndexesForAllTags()
            for _ in 0..<4 { _ = try root.select(".before"); _ = try root.select("[href='/old']") }
        }
        try target.attr("data-extra", "yes")
        for root in roots {
            XCTAssertFalse(root.isTagQueryIndexDirty)
            XCTAssertTrue(root.isClassQueryIndexDirty)
            XCTAssertTrue(root.isIdQueryIndexDirty)
            XCTAssertTrue(root.isAttributeQueryIndexDirty)
            XCTAssertTrue(root.isAttributeValueQueryIndexDirty)
            XCTAssertNil(root.selectorResultCache)
        }
        try target.attr("class", "after")
        try target.attr("id", "new")
        try target.attr("href", "/new")
        for root in roots {
            XCTAssertEqual(try root.select(".before, #old, [href='/old']").size(), 0)
            XCTAssertTrue(try root.select(".after#new[href='/new'][data-extra]").first() === target)
        }
        let serialized = String(decoding: try doc.outerHtmlUTF8(), as: UTF8.self)
        let reparsed = try SwiftSoup.parse(serialized)
        XCTAssertEqual(try reparsed.select(".after#new[href='/new'][data-extra]").size(), 1)
    }

    func testAlreadyDirtyDescendantStillInvalidatesRebuiltAncestor() throws {
        let doc = try SwiftSoup.parse("<main><section><a id='target' class='before' href='/one'></a></section></main>")
        doc.materializeAttributesRecursively()
        let target = try XCTUnwrap(doc.getElementById("target"))
        let section = try XCTUnwrap(target.parent())
        section.isClassQueryIndexDirty = true
        for _ in 0..<4 { _ = try doc.select(".before") }
        try target.attr("class", "after")
        XCTAssertEqual(try doc.select(".before").size(), 0)
        XCTAssertTrue(try doc.select(".after").first() === target)
    }

    func testLowercasingAllKeysInvalidatesWarmedIndexes() throws {
        let parser = Parser.htmlParser().settings(ParseSettings.preserveCase)
        let doc = try parser.parseInput("<main><a ID='node' CLASS='before' HREF='/one'></a></main>", "")
        let target = try XCTUnwrap(doc.getElementsByTag("a").first())
        let attrs = try XCTUnwrap(target.getAttributes())
        _ = Array(attrs)
        for _ in 0..<4 { _ = try doc.select(".before"); _ = try doc.select("[href='/one']") }
        attrs.lowercaseAllKeys()
        XCTAssertTrue(attrs.hasKey(key: "href"))
        XCTAssertFalse(attrs.hasKey(key: "HREF"))
        XCTAssertTrue(try doc.select(".before[href='/one']").first() === target)
    }
}
