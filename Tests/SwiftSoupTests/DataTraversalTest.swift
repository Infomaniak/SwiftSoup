import XCTest
@testable import SwiftSoup

final class DataTraversalTest: XCTestCase {
    private func assertSelection(_ root: Element, _ query: String, _ expected: [Element],
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let evaluator = try QueryParser.parse(query)
        var stack = [root]
        var scanned: [Element] = []
        while let element = stack.popLast() {
            if try evaluator.matches(root, element) { scanned.append(element) }
            stack.append(contentsOf: element.childNodes.reversed().compactMap { $0 as? Element })
        }
        let identities = expected.map(ObjectIdentifier.init)
        XCTAssertEqual(scanned.map(ObjectIdentifier.init), identities, query, file: file, line: line)
        XCTAssertEqual(try Collector.collect(evaluator, root).array().map(ObjectIdentifier.init), identities,
                       query, file: file, line: line)
        for _ in 0..<4 {
            XCTAssertEqual(try root.select(query).array().map(ObjectIdentifier.init), identities,
                           query, file: file, line: line)
        }
    }

    private final class CustomDataNode: DataNode {
        override func getWholeDataUTF8() -> [UInt8] { Array("custom".utf8) }
    }

    func testDataNodeSubclassGetterRemainsAuthoritative() throws {
        let element = Element(try Tag.valueOf("script"), "")
        try element.appendChild(CustomDataNode(Array("stored".utf8), []))
        XCTAssertEqual(element.data(), "custom")
    }

    func testDataIncludesCommentsInDocumentOrder() throws {
        let doc = try SwiftSoup.parse("<main><!--a--><script>b</script><section><!--c--><style>d</style>ignored</section><!--e--></main>")
        let main = try XCTUnwrap(doc.select("main").first())
        XCTAssertEqual(main.data(), "abcde")
        XCTAssertEqual(try doc.select("section").first()?.data(), "cd")
        try assertSelection(doc, "main:containsData(abcde)", [main])
    }

    func testOrdinaryTextAndDeclarationAreNotData() throws {
        let doc = try SwiftSoup.parse("<!doctype html><html><head></head><body><p>ignored</p><!--kept--></body></html>")
        XCTAssertEqual(doc.data(), "kept")
        XCTAssertEqual(try doc.select("p").first()?.data(), "")
        XCTAssertEqual(try doc.text(), "ignored")
    }

    func testContainsDataIsCaseInsensitiveWithoutNormalizingWhitespace() throws {
        let doc = try SwiftSoup.parse("<main><!--MiX\n  Ed--></main>")
        let main = try XCTUnwrap(doc.select("main").first())
        XCTAssertEqual(main.data(), "MiX\n  Ed")
        try assertSelection(doc, "main:containsData(mix\n  ed)", [main])
        try assertSelection(doc, "main:containsData(mix ed)", [])
    }

    func testUnicodeCommentBytesArePreserved() throws {
        let value = "日本e\u{301}👩‍💻 &amp;"
        let doc = try SwiftSoup.parse("<main><!--" + value + "--></main>")
        let main = try XCTUnwrap(doc.select("main").first())
        XCTAssertEqual(Array(main.data().utf8), Array(value.utf8))
        try assertSelection(doc, "main:containsData(日本)", [main])
    }

    func testTraversalDoesNotMaterializeSingleSliceData() throws {
        let doc = try SwiftSoup.parse("<script>one</script>")
        let script = try XCTUnwrap(doc.select("script").first())
        let data = try XCTUnwrap(script.childNodes.first as? DataNode)
        XCTAssertNil(data.attributes)
        let version = doc.textMutationVersionToken()
        let dirty = data.sourceRangeDirty
        XCTAssertEqual(script.data(), "one")
        XCTAssertNil(data.attributes)
        XCTAssertEqual(doc.textMutationVersionToken(), version)
        XCTAssertEqual(data.sourceRangeDirty, dirty)
    }

    func testFragmentedDataDoesNotDirtySourceOnRead() throws {
        let doc = try SwiftSoup.parse("<script></script>")
        let script = try XCTUnwrap(doc.select("script").first())
        let data = DataNode(slice: ByteSlice.fromArray(Array("one".utf8)), baseUri: [])
        data.appendSlice(ByteSlice.fromArray(Array("two".utf8)))
        try script.appendChild(data)
        let version = doc.textMutationVersionToken()
        let dirty = data.sourceRangeDirty
        XCTAssertEqual(script.data(), "onetwo")
        XCTAssertEqual(script.data(), "onetwo")
        XCTAssertEqual(doc.textMutationVersionToken(), version)
        XCTAssertEqual(data.sourceRangeDirty, dirty)
    }

    func testDeepDataTraversalPreservesOrder() throws {
        let root = Element(try Tag.valueOf("main"), "")
        var ancestors = [root]
        for index in 0..<1500 {
            let child = Element(try Tag.valueOf("div"), "")
            try ancestors.last!.appendChild(Comment(Array("a".utf8), []))
            try ancestors.last!.appendChild(child)
            try ancestors.last!.appendChild(DataNode(Array(String(index % 10).utf8), []))
            ancestors.append(child)
        }
        try ancestors.last!.appendChild(Comment(Array("middle".utf8), []))
        let suffix = (0..<1500).reversed().map { String($0 % 10) }.joined()
        XCTAssertEqual(root.data(), String(repeating: "a", count: 1500) + "middle" + suffix)
        // Explicit teardown avoids making this a test of recursive ARC destruction.
        for node in ancestors.dropFirst().reversed() { try node.remove() }
    }

    func testCommentRemovalAndReparentingInvalidatesBothRoots() throws {
        let doc = try SwiftSoup.parse("<main><!--kept--></main><aside></aside>")
        let main = try XCTUnwrap(doc.select("main").first())
        let aside = try XCTUnwrap(doc.select("aside").first())
        let comment = try XCTUnwrap(main.childNodes.first as? Comment)
        try assertSelection(doc, "main:containsData(kept)", [main])
        try assertSelection(doc, "aside:containsData(kept)", [])
        try aside.appendChild(comment)
        try assertSelection(doc, "main:containsData(kept)", [])
        try assertSelection(doc, "aside:containsData(kept)", [aside])
        try comment.remove()
        XCTAssertEqual(doc.data(), "")
        try assertSelection(doc, "aside:containsData(kept)", [])
    }

    func testEmptyCommentAndDataAddNoSeparators() throws {
        let doc = try SwiftSoup.parse("<main><!----><script>a</script><!----><script></script><!--b--></main>")
        XCTAssertEqual(try doc.select("main").first()?.data(), "ab")
    }
    func testCommentObjectMutationUpdatesSourceReuseAndDataSelectors() throws {
        let doc = try SwiftSoup.parse("<html><head></head><body><main><!--before--></main></body></html>")
        doc.outputSettings().prettyPrint(pretty: false)
        let main = try XCTUnwrap(doc.select("main").first())
        let comment = try XCTUnwrap(main.getChildNodes().first as? Comment)
        let a = try XCTUnwrap(comment.getAttributes()?.first(where: { _ in true }))
        try assertSelection(doc, "main:containsData(before)", [main])
        a.setValue(value: Array("after".utf8))
        XCTAssertEqual(comment.getData(), "after")
        try assertSelection(doc, "main:containsData(before)", [])
        try assertSelection(doc, "main:containsData(after)", [main])
        for bytes in [try doc.outerHtmlUTF8(), try doc.outerHtmlUTF8WithoutSourceReuse(), try doc.outerHtmlUTF8ReusingSourceOutsideBody()] {
            let html = String(decoding: bytes, as: UTF8.self)
            XCTAssertTrue(html.contains("<!--after-->"))
            XCTAssertFalse(html.contains("<!--before-->"))
        }
    }

}
