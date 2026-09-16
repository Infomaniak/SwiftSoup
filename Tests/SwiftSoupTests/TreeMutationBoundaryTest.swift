import XCTest
@testable import SwiftSoup

final class TreeMutationBoundaryTest: XCTestCase {
    private func fixture() throws -> (Document, Element, Element, Element, Element) {
        let doc = try SwiftSoup.parse("<main><div id='left'><i id='a'>a</i><i id='b'>b</i><i id='c'>c</i></div><div id='right'></div></main>")
        let left = try XCTUnwrap(doc.getElementById("left"))
        return (doc, left, try XCTUnwrap(doc.getElementById("a")), try XCTUnwrap(doc.getElementById("b")), try XCTUnwrap(doc.getElementById("c")))
    }
    private func assertChildren(_ parent: Element, _ nodes: [Node], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(parent.childNodeSize(), nodes.count, file: file, line: line)
        for (i, node) in nodes.enumerated() {
            guard i < parent.childNodeSize() else { continue }
            XCTAssertTrue(parent.childNode(i) === node, file: file, line: line)
            XCTAssertTrue(node.parent() === parent, file: file, line: line)
            XCTAssertEqual(node.siblingIndex, i, file: file, line: line)
        }
    }
    func testAppendTextInvalidatesWarmedSelectorsAndExternalVersion() throws {
        let doc = try SwiftSoup.parse("<main><p>old</p></main>")
        let p = try XCTUnwrap(doc.select("p").first())
        for root in [doc as Element, p] {
            for _ in 0..<3 {
                XCTAssertEqual(try root.select("p:contains(new)").size(), 0)
                XCTAssertEqual(try root.select("p:matches(new)").size(), 0)
            }
        }
        let version = p.textMutationVersionToken()
        try p.appendText("new")
        XCTAssertNotEqual(version, p.textMutationVersionToken())
        for root in [doc as Element, p] {
            XCTAssertTrue(try root.select("p:contains(new)").first() === p)
            XCTAssertTrue(try root.select("p:matches(new)").first() === p)
        }
        XCTAssertEqual(try p.text(), "oldnew")
    }
    func testAppendDataAndCommentInvalidatesWarmedDataSelectors() throws {
        for comment in [false, true] {
            let doc = try SwiftSoup.parse("<main></main>")
            let root = try XCTUnwrap(doc.select("main").first())
            for _ in 0..<4 { XCTAssertEqual(try root.select(":containsData(added)").size(), 0) }
            if comment { try root.appendChild(Comment(Array("added".utf8), [])) }
            else { try root.appendChild(DataNode(Array("added".utf8), [])) }
            XCTAssertTrue(try root.select(":containsData(added)").first() === root)
            XCTAssertEqual(root.data(), "added")
        }
    }
    func testAppendToEmptyInvalidatesEmptySelector() throws {
        let doc = try SwiftSoup.parse("<p></p>")
        let p = try XCTUnwrap(doc.select("p:empty").first())
        for _ in 0..<4 { XCTAssertEqual(try p.select(":empty").size(), 1) }
        try p.appendChild(TextNode("text", ""))
        XCTAssertEqual(try p.select(":empty").size(), 0)
    }
    func testAppendPopulatedElementChangesTextVersion() throws {
        let (_, left, _, _, _) = try fixture()
        let child = try Element(Tag.valueOf("strong"), "").text("added")
        let version = left.textMutationVersionToken()
        try left.appendChild(child)
        XCTAssertNotEqual(version, left.textMutationVersionToken())
        XCTAssertTrue(try left.text().contains("added"))
    }
    func testEmptyDetachesRetainedChildrenAndKeepsSubtreesIntact() throws {
        let (doc, left, a, b, c) = try fixture()
        let nested = a.childNode(0)
        _ = try left.select("i")
        left.empty()
        assertChildren(left, [])
        for child in [a, b, c] { XCTAssertNil(child.parent()); XCTAssertNil(child.ownerDocument()) }
        XCTAssertTrue(nested.parent() === a)
        XCTAssertEqual(try doc.select("i").size(), 0)
        XCTAssertTrue(try a.select("#a").first() === a)
    }
    func testEmptyChildrenCanBeReinsertedWithoutRemovingUnrelatedSiblings() throws {
        let (doc, left, a, b, c) = try fixture()
        left.empty()
        let right = try XCTUnwrap(doc.getElementById("right"))
        try right.appendChild(b)
        try left.appendChild(a)
        try right.prependChild(c)
        assertChildren(left, [a]); assertChildren(right, [c, b])
        XCTAssertEqual(try doc.select("i").array().map { $0.id() }, ["a", "c", "b"])
    }
    func testTextAndHtmlReplacementDetachRetainedChildren() throws {
        for useHTML in [false, true] {
            let (_, left, a, b, c) = try fixture()
            if useHTML { try left.html("<em>replacement</em>") } else { try left.text("replacement") }
            for child in [a, b, c] { XCTAssertNil(child.parent()) }
        }
    }
    func testSelfReplacementIsNoOpAtEveryPosition() throws {
        let (_, left, a, b, c) = try fixture()
        for child in [a, b, c] {
            let version = left.textMutationVersionToken()
            try child.replaceWith(child)
            assertChildren(left, [a, b, c])
            XCTAssertEqual(version, left.textMutationVersionToken())
        }
    }
    func testInsertExistingChildAtEndUsesOriginalGap() throws {
        let (_, left, a, b, c) = try fixture()
        try left.insertChildren(-1, [a])
        assertChildren(left, [b, c, a])
    }
    func testInsertMultipleExistingChildrenUsesOriginalGap() throws {
        let (_, left, a, b, c) = try fixture()
        try left.insertChildren(3, [a, b])
        assertChildren(left, [c, a, b])
    }
    func testSiblingMovesBeforeAfterAndSelf() throws {
        let (_, left, a, b, c) = try fixture()
        try c.after(a)
        assertChildren(left, [b, c, a])
        try b.before(a)
        assertChildren(left, [a, b, c])
        try a.before(a)
        try c.after(c)
        assertChildren(left, [a, b, c])
    }
    func testIndexedInsertionRejectsInvalidOffsetWithoutDetachingInput() throws {
        let (doc, left, a, b, c) = try fixture()
        let right = try XCTUnwrap(doc.getElementById("right"))
        for index in [-1, 1, Int.max] {
            XCTAssertThrowsError(try right.addChildren(index, [a]))
            assertChildren(left, [a,b,c]); assertChildren(right, [])
        }
    }
    func testRejectSelfAndAncestorBeforeChangingEitherTree() throws {
        let (_, left, a, b, c) = try fixture()
        XCTAssertThrowsError(try left.appendChild(left))
        XCTAssertThrowsError(try a.appendChild(left))
        assertChildren(left, [a,b,c])
    }
    func testReplacementRejectsAncestorBeforeDetachingIt() throws {
        let (doc, left, a, b, c) = try fixture()
        let main = try XCTUnwrap(doc.select("main").first())
        XCTAssertThrowsError(try a.replaceWith(main))
        XCTAssertTrue(left.parent() === main)
        assertChildren(left, [a,b,c])
    }
    func testBatchRejectsAncestorAtomically() throws {
        for indexed in [false, true] {
            let (doc, left, a, b, c) = try fixture()
            let right = try XCTUnwrap(doc.getElementById("right"))
            if indexed { XCTAssertThrowsError(try a.addChildren(0, [right, left])) }
            else { XCTAssertThrowsError(try a.addChildren([right, left])) }
            XCTAssertTrue(right.parent() === left.parent())
            assertChildren(left, [a,b,c])
        }
    }
    func testSetParentRejectsCycleBeforeDetaching() throws {
        let (_, left, a, b, c) = try fixture()
        XCTAssertThrowsError(try left.setParentNode(a))
        assertChildren(left, [a,b,c])
    }
    func testExistingSiblingReplacementPreservesIdentityOrder() throws {
        for earlier in [false, true] {
            let (_, left, a, b, c) = try fixture()
            if earlier { try c.replaceWith(a); assertChildren(left, [b,a]); XCTAssertNil(c.parent()) }
            else { try a.replaceWith(c); assertChildren(left, [c,b]); XCTAssertNil(a.parent()) }
        }
    }
    func testRepeatedReferenceInsertionDoesNotDuplicateNodes() throws {
        let (_, left, a, b, c) = try fixture()
        try left.insertChildren(-1, [a,b,a])
        assertChildren(left, [c,a,b])
    }
}
