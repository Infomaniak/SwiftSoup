import Foundation
import XCTest
@testable import SwiftSoup

final class BlankTextBytesTest: XCTestCase {
    // The original public Character predicate is the compatibility oracle.
    private func reference(_ text: String) -> Bool {
        text.allSatisfy { StringUtil.isWhitespace($0) }
    }

    func testEverySingleByteAndAdjacentWhitespace() {
        for value in UInt16(0)...255 {
            let byte = UInt8(value)
            for bytes in [[byte], [32, byte], [byte, 13, 10], [9, 32, byte, 12]] {
                let text = String(decoding: bytes, as: UTF8.self)
                let expected = reference(text)
                XCTAssertEqual(StringUtil.isBlank(text), expected, "\(bytes)")
                XCTAssertEqual(TextNode(bytes, nil).isBlank(), expected, "\(bytes)")
            }
        }
    }

    func testWhitespaceContractIsNotBroadened() {
        for text in ["", " ", "\t", "\n", "\r", "\u{c}", "\r\n", " \t\r\n\u{c} "] {
            XCTAssertTrue(reference(text))
            XCTAssertTrue(StringUtil.isBlank(text))
            XCTAssertTrue(TextNode(text, nil).isBlank())
        }
        for text in ["\u{b}", "\u{85}", "\u{a0}", "\u{1680}", "\u{2000}", "\u{2028}", "\u{2029}", "\u{202f}", "\u{205f}", "\u{3000}", "\u{feff}", "\0"] {
            XCTAssertFalse(reference(text))
            XCTAssertFalse(StringUtil.isBlank(text))
            XCTAssertFalse(TextNode(text, nil).isBlank())
        }
    }

    func testComposedGraphemesAndCanonicalSpelling() {
        for text in [" \u{301}", "\r\n\u{301}", "\u{301} ", "e\u{301}", "é", "가", "가", "👩🏽‍💻", "🇯🇵", "\u{200d}", "\u{fe0f}"] {
            for value in [text, " \t" + text + "\r\n", String(repeating: text, count: 32)] {
                XCTAssertEqual(StringUtil.isBlank(value), reference(value))
                XCTAssertEqual(TextNode(value, nil).isBlank(), reference(value))
            }
        }
    }

    func testSeededUnicodeAndMalformedBytes() {
        var seed: UInt64 = 0x62b1a9
        func next() -> UInt64 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return seed
        }
        let pieces = [" ", "\t", "\n", "\r", "\r\n", "\u{c}", "\u{b}", "\0", "\u{a0}", "日本", "e\u{301}", "👩🏽‍💻", "🇯🇵", "\u{301}"]
        for _ in 0..<2048 {
            let length = Int(next() % 40)
            let text = (0..<length).map { _ in pieces[Int(next() % UInt64(pieces.count))] }.joined()
            XCTAssertEqual(StringUtil.isBlank(text), reference(text))
            XCTAssertEqual(TextNode(text, nil).isBlank(), reference(text))
            let bytes = (0..<length).map { _ in UInt8(truncatingIfNeeded: next() >> 32) }
            let decoded = String(decoding: bytes, as: UTF8.self)
            let node = TextNode(bytes, nil)
            XCTAssertEqual(node.isBlank(), reference(decoded))
            XCTAssertEqual(node.getWholeTextUTF8(), bytes)
        }
    }

    func testTextGetterSubclassDispatchAndReadOrder() {
        final class Projected: TextNode {
            var calls: [String] = []
            var projection = " "
            override func getWholeText() -> String { calls.append("string"); return projection }
            override func getWholeTextUTF8() -> [UInt8] { calls.append("bytes"); return [88] }
        }
        let node = Projected("backing", nil)
        for projection in [" ", "\u{a0}", "", "日本"] {
            node.calls = []
            node.projection = projection
            XCTAssertEqual(node.isBlank(), reference(projection))
            XCTAssertEqual(node.calls, ["string"])
        }
        final class BytesOnly: TextNode {
            var reads = 0
            override func getWholeTextUTF8() -> [UInt8] { reads += 1; return [13, 10] }
        }
        let bytes = BytesOnly("not blank", nil)
        XCTAssertTrue(bytes.isBlank())
        XCTAssertEqual(bytes.reads, 1)
    }

    func testSlicedAndFragmentedStorageRemainsMaterializedAsBefore() {
        for text in [" \r\n", "日本語", "\u{a0}", ""] {
            let bytes = Array(text.utf8)
            var padded = [UInt8(88), 89]; padded += bytes; padded += [90]
            let node = TextNode(slice: ArraySlice(padded[2..<(2 + bytes.count)]), baseUri: nil)
            XCTAssertEqual(node.isBlank(), reference(text))
            XCTAssertEqual(node._text, bytes)
            XCTAssertNil(node.attributes)
            node.appendSlice(ByteSlice.fromArray([32, 9]))
            XCTAssertEqual(node.isBlank(), reference(text + " \t"))
            XCTAssertEqual(node._text, bytes + [32, 9])
        }
        let fragmented = TextNode(slice: ByteSlice.fromArray([32]), baseUri: nil)
        fragmented.appendSlice(ByteSlice.fromArray([0xC2]))
        fragmented.appendSlice(ByteSlice.fromArray([0xA0]))
        XCTAssertFalse(fragmented.isBlank())
        XCTAssertEqual(fragmented._text, [32, 0xC2, 0xA0])
    }

    func testAttributeEditsRemainAuthoritative() throws {
        let node = TextNode("pending", nil)
        let attribute = try XCTUnwrap(node.getAttributes().asList().first)
        for bytes in [[UInt8](), [32, 13, 10], [0xFF], Array("日本".utf8)] {
            attribute.setValue(value: bytes)
            XCTAssertEqual(node.isBlank(), reference(String(decoding: bytes, as: UTF8.self)))
            XCTAssertEqual(node.getWholeTextUTF8(), bytes)
        }
        try attribute.setKey(key: "renamed")
        XCTAssertTrue(node.isBlank())
        try node.attr("text", "new")
        XCTAssertFalse(node.isBlank())
        try node.removeAttr("text")
        XCTAssertTrue(node.isBlank())
    }

    func testBlankReadDoesNotDirtySourceOrWarmedSelectors() throws {
        let doc = try SwiftSoup.parse("<main><p> \t </p><p>日本 &amp; text</p></main>")
        let queries = ["p", "p:contains(日本)", "p:empty", "p:matches(text)"]
        let before = try queries.map { try doc.select($0).array().map(ObjectIdentifier.init) }
        let html = try doc.outerHtmlUTF8()
        let token = doc.textMutationVersionToken()
        for p in try doc.select("p") {
            for text in p.textNodes() {
                let dirty = text.sourceRangeDirty
                for _ in 0..<8 { XCTAssertEqual(text.isBlank(), reference(text.getWholeText())) }
                XCTAssertEqual(text.sourceRangeDirty, dirty)
            }
        }
        XCTAssertEqual(doc.textMutationVersionToken(), token)
        XCTAssertEqual(try doc.outerHtmlUTF8(), html)
        XCTAssertEqual(try queries.map { try doc.select($0).array().map(ObjectIdentifier.init) }, before)
        let first = try XCTUnwrap(doc.select("p").first())
        first.textNodes()[0].text("日本")
        XCTAssertTrue(first.hasText())
        XCTAssertEqual(try doc.select("p:contains(日本)").size(), 2)
    }

    func testPublicHasTextEachTextAndSerialization() throws {
        let doc = try SwiftSoup.parse("<main><p> \r\n </p><p>日本</p><p>&nbsp;</p><p>e&#x301;</p><p>\u{b}</p></main>")
        let paragraphs = try doc.select("p")
        XCTAssertEqual(paragraphs.array().map { $0.hasText() }, [false, true, true, true, true])
        XCTAssertEqual(try paragraphs.eachText().count, 4)
        let copy = doc.copy() as! Document
        XCTAssertEqual(try copy.outerHtmlUTF8(), try doc.outerHtmlUTF8())
        XCTAssertEqual(try copy.text(), try doc.text())
    }
}
