import XCTest
@testable import SwiftSoup

final class OwnerDocumentLookupTest: XCTestCase {
    func testLookupFollowsReparentingAndDetachment() throws {
        let first = try SwiftSoup.parse("<main><p>one</p></main>")
        let second = try SwiftSoup.parse("<section></section>")
        let paragraph = try XCTUnwrap(first.getElementsByTag("p").first())
        let text = paragraph.childNode(0)
        XCTAssertTrue(first.ownerDocument() === first)
        XCTAssertTrue(text.ownerDocument() === first)
        try XCTUnwrap(second.body()).appendChild(paragraph)
        XCTAssertTrue(paragraph.ownerDocument() === second)
        XCTAssertTrue(text.ownerDocument() === second)
        try paragraph.remove()
        XCTAssertNil(paragraph.ownerDocument())
        XCTAssertNil(text.ownerDocument())
    }

    func testAncestorOverrideIsNotBypassed() throws {
        let physical = Document("")
        let logical = Document("")
        let ancestor = RedirectElement(try Tag.valueOf("section"), "")
        ancestor.redirect = logical
        try physical.appendChild(ancestor)
        let paragraph = try ancestor.appendElement("p")
        try paragraph.text("value")
        XCTAssertTrue(paragraph.ownerDocument() === logical)
        XCTAssertTrue(paragraph.childNode(0).ownerDocument() === logical)
        XCTAssertTrue(paragraph.getOutputSettings() === logical.outputSettings())
        ancestor.redirect = nil
        XCTAssertNil(paragraph.ownerDocument())
        XCTAssertNil(paragraph.childNode(0).ownerDocument())
    }

    func testDocumentOverrideIsNotBypassedFromChild() throws {
        let logical = Document("")
        let physical = RedirectDocument("")
        physical.redirect = logical
        let child = try physical.appendElement("div")
        XCTAssertTrue(child.ownerDocument() === logical)
        XCTAssertTrue(child.getOutputSettings() === logical.outputSettings())
    }

    func testOutputSettingsRemainLiveAndClonesUseTheirOwnDocument() throws {
        let doc = try SwiftSoup.parse("<div><p>text</p></div>")
        let paragraph = try XCTUnwrap(doc.getElementsByTag("p").first())
        XCTAssertTrue(paragraph.getOutputSettings() === doc.outputSettings())
        let replacement = OutputSettings().prettyPrint(pretty: false).syntax(syntax: .xml)
        doc.outputSettings(replacement)
        XCTAssertTrue(paragraph.getOutputSettings() === replacement)
        let clone = doc.copy() as! Document
        let cloned = try XCTUnwrap(clone.getElementsByTag("p").first())
        XCTAssertTrue(cloned.ownerDocument() === clone)
        XCTAssertTrue(cloned.getOutputSettings() === clone.outputSettings())
        XCTAssertFalse(cloned.getOutputSettings() === replacement)
        XCTAssertEqual(try paragraph.outerHtml(), try cloned.outerHtml())
    }

    func testDetachedDefaultsAreFreshAndMatchDocumentDefaults() throws {
        let detached = try Element(Tag.valueOf("p"), "")
        let first = detached.getOutputSettings()
        let second = detached.getOutputSettings()
        let reference = Document("").outputSettings()
        XCTAssertFalse(first === second)
        XCTAssertEqual(first.prettyPrint(), reference.prettyPrint())
        XCTAssertEqual(first.syntax(), reference.syntax())
        XCTAssertEqual(first.indentAmount(), reference.indentAmount())
        XCTAssertEqual(first.charset(), reference.charset())
        first.prettyPrint(pretty: !reference.prettyPrint())
        XCTAssertEqual(detached.getOutputSettings().prettyPrint(), reference.prettyPrint())
    }

    private final class RedirectElement: Element {
        var redirect: Document?
        override func ownerDocument() -> Document? { redirect }
    }

    private final class RedirectDocument: Document {
        var redirect: Document?
        override func ownerDocument() -> Document? { redirect }
    }
}
