import XCTest
@testable import SwiftSoup

final class NodeAttributeMutationTest: XCTestCase {
    private func assertSelection(_ root: Element, _ query: String, _ expected: [Element],
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let evaluator = try QueryParser.parse(query)
        var stack = [root]
        var scanned: [Element] = []
        while let element = stack.popLast() {
            if try evaluator.matches(root, element) { scanned.append(element) }
            stack.append(contentsOf: element.childNodes.reversed().compactMap { $0 as? Element })
        }
        let ids = expected.map(ObjectIdentifier.init)
        XCTAssertEqual(scanned.map(ObjectIdentifier.init), ids, query, file: file, line: line)
        for _ in 0..<4 {
            XCTAssertEqual(try root.select(query).array().map(ObjectIdentifier.init), ids, query, file: file, line: line)
        }
    }

    private func script() throws -> (Document, Element, DataNode) {
        let doc = try SwiftSoup.parse("<html><head><script>before</script></head><body></body></html>")
        doc.outputSettings().prettyPrint(pretty: false)
        let script = try XCTUnwrap(doc.select("script").first())
        let data = try XCTUnwrap(script.getChildNodes().first as? DataNode)
        return (doc, script, data)
    }

    func testRawDataAttributeReadMaterializesExistingValue() throws {
        let (_, _, data) = try script()
        XCTAssertEqual(try data.attr("data"), "before")
        XCTAssertTrue(data.hasAttr("data"))
        XCTAssertEqual(data.getAttributes()?.get(key: "data"), "before")
    }

    func testRawDataAttributeWriteCannotBeOverwrittenByLaterRead() throws {
        for bytes in [false, true] {
            let (doc, script, data) = try script()
            try assertSelection(doc, "script:containsData(before)", [script])
            if bytes { try data.attr(Array("data".utf8), Array("after".utf8)) }
            else { try data.attr("data", "after") }
            XCTAssertEqual(data.getWholeData(), "after")
            XCTAssertEqual(data.getWholeData(), "after")
            try assertSelection(doc, "script:containsData(before)", [])
            try assertSelection(doc, "script:containsData(after)", [script])
            XCTAssertTrue(String(decoding: try doc.outerHtmlUTF8(), as: UTF8.self).contains("<script>after</script>"))
        }
    }

    func testRemovingRawDataCannotResurrectDeferredContent() throws {
        let (doc, script, data) = try script()
        try assertSelection(doc, "script:containsData(before)", [script])
        try data.removeAttr("data")
        XCTAssertEqual(data.getWholeData(), "")
        XCTAssertFalse(data.hasAttr("data"))
        data.appendSlice(ByteSlice.fromArray(Array("after".utf8)))
        XCTAssertEqual(data.getWholeData(), "after")
        try assertSelection(doc, "script:containsData(before)", [])
        try assertSelection(doc, "script:containsData(after)", [script])
    }

    func testDeferredDataWriteBeforeAnyContentRead() throws {
        for bytes in [false, true] {
            let (_, _, data) = try script()
            XCTAssertNil(data.attributes, "fixture must still use deferred storage")
            if bytes { try data.attr(Array("data".utf8), Array("after".utf8)) }
            else { try data.attr("data", "after") }
            XCTAssertEqual(data.getWholeData(), "after")
            XCTAssertEqual(try data.attr("data"), "after")
        }
    }

    func testDeferredDataRemovalBeforeAnyContentRead() throws {
        let (_, _, data) = try script()
        XCTAssertNil(data.attributes)
        try data.removeAttr("data")
        XCTAssertEqual(data.getWholeData(), "")
        XCTAssertFalse(data.hasAttr("data"))
        data.appendSlice(ByteSlice.fromArray(Array("new".utf8)))
        XCTAssertEqual(data.getWholeData(), "new")
    }

    func testDeferredAppendInvalidatesWithoutMaterialization() throws {
        let (doc, script, data) = try script()
        // Do not call :containsData here: it materializes storage on the baseline.
        _ = try doc.select("script")
        XCTAssertNil(data.attributes)
        let version = doc.textMutationVersionToken()
        data.appendSlice(ByteSlice.fromArray(Array("after".utf8)))
        XCTAssertNil(data.attributes)
        XCTAssertNotEqual(doc.textMutationVersionToken(), version)
        XCTAssertEqual(data.getWholeData(), "beforeafter")
        try assertSelection(doc, "script:containsData(beforeafter)", [script])
    }

    func testDirectRawDataAttributeReferenceIsLive() throws {
        let (doc, script, data) = try script()
        let attr = try XCTUnwrap(data.getAttributes()?.first { $0.getKey() == "data" })
        try assertSelection(doc, "script:containsData(before)", [script])
        attr.setValue(value: Array("after".utf8))
        XCTAssertEqual(data.getWholeData(), "after")
        try assertSelection(doc, "script:containsData(before)", [])
        try assertSelection(doc, "script:containsData(after)", [script])
    }

    func testDataMaterializationDoesNotDirtySourceOrTextVersion() throws {
        let (doc, _, data) = try script()
        let version = doc.textMutationVersionToken()
        let dirty = data.sourceRangeDirty
        XCTAssertEqual(data.getWholeData(), "before")
        _ = data.getAttributes()
        XCTAssertEqual(doc.textMutationVersionToken(), version)
        XCTAssertEqual(data.sourceRangeDirty, dirty)
    }

    func testTextMaterializationDoesNotDirtySourceOrTextVersion() throws {
        let doc = try SwiftSoup.parse("<p>one&amp;two</p>")
        let p = try XCTUnwrap(doc.select("p").first())
        let text = try XCTUnwrap(p.getChildNodes().first as? TextNode)
        let version = doc.textMutationVersionToken()
        let dirty = text.sourceRangeDirty
        let attrs = text.getAttributes()
        XCTAssertEqual(attrs.get(key: "text"), "one&two")
        XCTAssertEqual(text.getWholeText(), "one&two")
        XCTAssertEqual(doc.textMutationVersionToken(), version)
        XCTAssertEqual(text.sourceRangeDirty, dirty)
    }

    func testFragmentedTextAttributeWriteIsNotLost() throws {
        let text = TextNode(slice: ByteSlice.fromArray(Array("one".utf8)), baseUri: [])
        text.appendSlice(ByteSlice.fromArray(Array("two".utf8)))
        text.appendSlice(ByteSlice.fromArray(Array("three".utf8)))
        XCTAssertEqual(text.getAttributes().get(key: "text"), "onetwothree")
        try text.attr("text", "after")
        XCTAssertEqual(text.getWholeText(), "after")
        XCTAssertEqual(text.text(), "after")
    }

    func testTextAttributeMutationInvalidatesWarmedSelectors() throws {
        let doc = try SwiftSoup.parse("<p>before</p>")
        let p = try XCTUnwrap(doc.select("p").first())
        let text = try XCTUnwrap(p.getChildNodes().first as? TextNode)
        let attr = try XCTUnwrap(text.getAttributes().first { $0.getKey() == "text" })
        try assertSelection(doc, "p:contains(before)", [p])
        try assertSelection(doc, "p:matches(^before$)", [p])
        attr.setValue(value: Array("after".utf8))
        try assertSelection(doc, "p:contains(before)", [])
        try assertSelection(doc, "p:containsOwn(after)", [p])
        try assertSelection(doc, "p:matches(^before$)", [])
        try assertSelection(doc, "p:matchesOwn(^after$)", [p])
    }

    func testTextRemoveThenAppendDoesNotRestoreOldText() throws {
        let text = TextNode("old", "")
        try text.attr("text", "before")
        try text.removeAttr("text")
        XCTAssertEqual(text.getWholeText(), "")
        text.appendSlice(ByteSlice.fromArray(Array("after".utf8)))
        XCTAssertEqual(text.getWholeText(), "after")
    }

    func testRawDataAppendInvalidatesCachedDataPredicate() throws {
        let (doc, script, data) = try script()
        try assertSelection(doc, "script:containsData(after)", [])
        data.appendSlice(ByteSlice.fromArray(Array("after".utf8)))
        try assertSelection(doc, "script:containsData(after)", [script])
        XCTAssertEqual(data.getWholeData(), "beforeafter")
    }

    func testNonElementAttributeClonesAreIndependent() throws {
        let nodes: [Node] = [TextNode("before", ""), DataNode(Array("before".utf8), []), Comment(Array("before".utf8), [])]
        for node in nodes {
            let attrs = try XCTUnwrap(node.getAttributes())
            let original = try XCTUnwrap(attrs.first(where: { _ in true }))
            let copy = node.copy() as! Node
            let copied = try XCTUnwrap(copy.getAttributes()?.first(where: { _ in true }))
            copied.setValue(value: Array("after".utf8))
            XCTAssertEqual(original.getValue(), "before")
            XCTAssertFalse(original === copied)
        }
    }

    func testNoOpAttributeMutationDoesNotInvalidateCaches() throws {
        let doc = try SwiftSoup.parse("<p class='old'></p>")
        let p = try XCTUnwrap(doc.select("p").first())
        let a = try XCTUnwrap(p.getAttributes()?.first(where: { _ in true }))
        try assertSelection(doc, ".old", [p])
        a.setValue(value: Array("old".utf8))
        try a.setKey(key: "class")
        XCTAssertFalse(doc.isClassQueryIndexDirty)
        try assertSelection(doc, ".old", [p])
    }

    func testAttributeMutationChangesAllSerializerModes() throws {
        let doc = try SwiftSoup.parse("<html><head></head><body><p title='before'>text</p></body></html>")
        doc.outputSettings().prettyPrint(pretty: false)
        let p = try XCTUnwrap(doc.select("p").first())
        let a = try XCTUnwrap(p.getAttributes()?.first(where: { _ in true }))
        _ = try doc.outerHtmlUTF8()
        a.setValue(value: Array("after".utf8))
        for bytes in [try doc.outerHtmlUTF8(), try doc.outerHtmlUTF8WithoutSourceReuse(), try doc.outerHtmlUTF8ReusingSourceOutsideBody()] {
            let parsed = try SwiftSoup.parse(String(decoding: bytes, as: UTF8.self))
            XCTAssertEqual(try parsed.select("p").attr("title"), "after")
        }
    }
}
