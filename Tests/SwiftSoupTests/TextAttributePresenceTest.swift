import XCTest
@testable import SwiftSoup

final class TextAttributePresenceTest: XCTestCase {
    func testFreshByteQueriesAgreeWithStringQueries() throws {
        for value in ["", "text", "日本", "e\u{301}", "👩🏽‍💻"] {
            for key in ["text", "TEXT", "TeXt", "missing", ""] {
                let bytesNode = TextNode(value, nil)
                let stringNode = TextNode(value, nil)
                XCTAssertEqual(bytesNode.hasAttr(Array(key.utf8)), stringNode.hasAttr(key), key)
            }
        }
    }

    func testByteQueriesThroughNodeReferenceDoNotDirtyParsedSource() throws {
        let doc = try SwiftSoup.parse("<p>日本 &amp; text</p>")
        let text = try XCTUnwrap(doc.select("p").first()?.textNodes().first)
        let node: Node = text
        let version = doc.textMutationVersionToken()
        let dirty = text.sourceRangeDirty
        let before = try doc.outerHtmlUTF8()
        XCTAssertTrue(node.hasAttr(Array("text".utf8)))
        XCTAssertTrue(node.hasAttr(Array("TEXT".utf8)))
        XCTAssertEqual(doc.textMutationVersionToken(), version)
        XCTAssertEqual(text.sourceRangeDirty, dirty)
        XCTAssertEqual(try doc.outerHtmlUTF8(), before)
    }

    func testReadThenRemoveDoesNotRestoreDeferredText() throws {
        let node = TextNode("pending", nil)
        XCTAssertTrue(node.hasAttr(Array("text".utf8)))
        try node.removeAttr(Array("text".utf8))
        for _ in 0..<4 {
            XCTAssertFalse(node.hasAttr(Array("text".utf8)))
            XCTAssertFalse(node.hasAttr("text"))
            XCTAssertEqual(node.getWholeTextUTF8(), [])
        }
    }

    func testPresenceQueryUsesCurrentSharedAttributeState() throws {
        let node = TextNode("original", nil)
        XCTAssertTrue(node.hasAttr(Array("text".utf8)))
        let attribute = try XCTUnwrap(node.getAttributes().asList().first)
        let other = TextNode("other", nil)
        other.getAttributes().put(attribute: attribute)
        try attribute.setKey(key: "renamed")
        for node in [node, other] {
            XCTAssertFalse(node.hasAttr(Array("text".utf8)))
            XCTAssertTrue(node.hasAttr(Array("RENAMED".utf8)))
            XCTAssertEqual(node.getWholeTextUTF8(), [])
        }
    }
}
