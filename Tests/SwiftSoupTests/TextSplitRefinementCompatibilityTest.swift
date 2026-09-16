import XCTest
@testable import SwiftSoup

final class TextSplitRefinementCompatibilityTest: XCTestCase {
    func testGraphemeOffsetsPreserveUnicodeBytes() throws {
        for text in ["日本語", "e\u{301}x", "👩🏽‍💻Z", "🇯🇵x", "\r\nx", "a\0b"] {
            for offset in 0..<text.count {
                let node = TextNode(text, "")
                let tail = try node.splitText(offset)
                XCTAssertEqual(node.getWholeTextUTF8(), Array(String(text.prefix(offset)).utf8))
                XCTAssertEqual(tail.getWholeTextUTF8(), Array(String(text.dropFirst(offset)).utf8))
            }
        }
    }

    func testGraphemeEndOffsetIsAllowed() throws {
        for text in ["hello", "日本", "e\u{301}", ""] {
            let node = TextNode(text, nil)
            let tail = try node.splitText(text.count)
            XCTAssertEqual(node.getWholeTextUTF8(), Array(text.utf8))
            XCTAssertEqual(tail.getWholeText(), "")
        }
    }

    func testInvalidGraphemeOffsetThrowsWithoutMutation() throws {
        // The previous implementation validates a character offset against UTF-8 byte count.
        // Run separately when reproducing the old trap so it cannot mask other regressions.
        let node = TextNode("日", "")
        XCTAssertThrowsError(try node.splitText(2))
        XCTAssertEqual(node.getWholeText(), "日")
        XCTAssertThrowsError(try node.splitText(-1))
        XCTAssertThrowsError(try node.splitText(Int.max))
    }

    func testUtf8OffsetsAreExactAtScalarBoundaries() throws {
        for text in ["日本語", "e\u{301}x", "👩🏽‍💻Z", "🇯🇵x", "\r\nx", "a\0b"] {
            let bytes = Array(text.utf8)
            var offset = 0
            for scalar in text.unicodeScalars {
                let node = TextNode(text, "")
                let tail = try node.splitText(utf8Offset: offset)
                XCTAssertEqual(node.getWholeTextUTF8(), Array(bytes[..<offset]))
                XCTAssertEqual(tail.getWholeTextUTF8(), Array(bytes[offset...]))
                offset += scalar.utf8.count
            }
        }
    }

    func testUtf8EndOffsetIsAllowed() throws {
        for text in ["hello", "日本", "e\u{301}", ""] {
            let node = TextNode(text, "")
            let tail = try node.splitText(utf8Offset: text.utf8.count)
            XCTAssertEqual(node.getWholeTextUTF8(), Array(text.utf8))
            XCTAssertEqual(tail.getWholeText(), "")
        }
    }

    func testUtf8ContinuationOffsetsThrowWithoutChangingTree() throws {
        for text in ["日本", "éx", "👩🏽‍💻Z"] {
            for offset in 0..<text.utf8.count where Array(text.utf8)[offset] & 0xC0 == 0x80 {
                let doc = try SwiftSoup.parse("<p>\(text)</p>")
                let p = try XCTUnwrap(doc.select("p").first())
                let node = try XCTUnwrap(p.childNode(0) as? TextNode)
                let source = try p.outerHtml()
                XCTAssertThrowsError(try node.splitText(utf8Offset: offset))
                XCTAssertEqual(node.getWholeText(), text)
                XCTAssertEqual(p.getChildNodes().count, 1)
                XCTAssertEqual(try p.outerHtml(), source)
            }
        }
    }

    func testOutOfRangeUtf8OffsetsThrow() throws {
        let node = TextNode("日本", "")
        for offset in [-1, 7, Int.max] { XCTAssertThrowsError(try node.splitText(utf8Offset: offset)) }
        XCTAssertEqual(node.getWholeText(), "日本")
    }

    func testMalformedUtf8IsNotSilentlyRepairedByByteSplit() throws {
        for bytes: [UInt8] in [[0xFF, 0x61], [0xC3, 0x61], [0x61, 0x80], [0xF0, 0x9F]] {
            let node = TextNode(bytes, [])
            XCTAssertThrowsError(try node.splitText(utf8Offset: 1))
            XCTAssertEqual(node.getWholeTextUTF8(), bytes)
        }
    }

    func testSplitUpdatesSiblingOrderAndWarmedText() throws {
        let doc = try SwiftSoup.parse("<p>A<span>日本語</span>Z</p>")
        let span = try XCTUnwrap(doc.select("span").first())
        let node = try XCTUnwrap(span.childNode(0) as? TextNode)
        _ = try doc.text()
        for _ in 0..<2 { XCTAssertEqual(try doc.select("span:contains(日本語)").size(), 1) }
        let tail = try node.splitText(utf8Offset: 3)
        XCTAssertTrue(span.childNode(0) === node)
        XCTAssertTrue(span.childNode(1) === tail)
        XCTAssertEqual(tail.siblingIndex, 1)
        XCTAssertTrue(tail.parent() === span)
        tail.text("語")
        XCTAssertEqual(try doc.select("span:contains(日本語)").size(), 0)
        XCTAssertEqual(try doc.select("span:contains(日語)").size(), 1)
        XCTAssertEqual(try doc.text(), "A日語Z")
    }

    func testSplitAfterDirectAttributeEditUsesCurrentContents() throws {
        let node = TextNode("old", "https://example.test/")
        let attr = try XCTUnwrap(node.getAttributes().asList().first)
        attr.setValue(value: Array("日本".utf8))
        let tail = try node.splitText(utf8Offset: 3)
        XCTAssertEqual(node.getWholeText(), "日")
        XCTAssertEqual(tail.getWholeText(), "本")
        XCTAssertEqual(tail.getBaseUri(), "https://example.test/")
    }

    func testSplitFragmentedStoragePreservesBytes() throws {
        let node = TextNode(slice: ByteSlice.fromArray([0xE6]), baseUri: nil)
        node.appendSlice(ByteSlice.fromArray([0x97, 0xA5, 0xE6]))
        node.appendSlice(ByteSlice.fromArray([0x9C, 0xAC]))
        let tail = try node.splitText(utf8Offset: 3)
        XCTAssertEqual(node.getWholeText(), "日")
        XCTAssertEqual(tail.getWholeText(), "本")
    }

    func testTextGetterIsReadOnceForCharacterSplit() throws {
        final class ProjectedText: TextNode {
            var reads = 0
            override func getWholeText() -> String { reads += 1; return "日本語" }
        }
        let node = ProjectedText("backing bytes", "")
        let tail = try node.splitText(1)
        XCTAssertEqual(node.reads, 1)
        XCTAssertEqual(node.getWholeTextUTF8(), Array("日".utf8))
        XCTAssertEqual(tail.getWholeText(), "本語")
    }
    func testGeneratedUtf8AndGraphemeBoundaryMatrix() throws {
        let fragments = ["日本", "e\u{301}", "👩🏽‍💻", "🇯🇵", "\r\n", "a\0b", "\u{600}x", "क्‍ष", "\u{10FFFF}"]
        for seed in 0..<256 {
            let text = fragments[seed % fragments.count] + fragments[(seed * 7 + 3) % fragments.count] + String(seed)
            let bytes = Array(text.utf8)
            var boundaries: Set<Int> = [0]
            var position = 0
            for scalar in text.unicodeScalars {
                position += scalar.utf8.count
                boundaries.insert(position)
            }
            for offset in 0...bytes.count {
                let node = TextNode(bytes, nil)
                if boundaries.contains(offset) {
                    let tail = try node.splitText(utf8Offset: offset)
                    XCTAssertEqual(node.getWholeTextUTF8(), Array(bytes.prefix(offset)), "seed \(seed), byte \(offset)")
                    XCTAssertEqual(tail.getWholeTextUTF8(), Array(bytes.dropFirst(offset)))
                } else {
                    XCTAssertThrowsError(try node.splitText(utf8Offset: offset))
                    XCTAssertEqual(node.getWholeTextUTF8(), bytes)
                }
            }
            for offset in 0...text.count {
                let node = TextNode(text, nil)
                let tail = try node.splitText(offset)
                XCTAssertEqual(node.getWholeTextUTF8(), Array(String(text.prefix(offset)).utf8))
                XCTAssertEqual(tail.getWholeTextUTF8(), Array(String(text.dropFirst(offset)).utf8))
            }
        }
    }

    func testRepeatedSplitsReconstructAttachedTextAndSource() throws {
        let text = "日本e\u{301}👩🏽‍💻\r\nZ"
        let doc = try SwiftSoup.parse("<p></p>")
        doc.outputSettings().prettyPrint(pretty: false)
        let parent = try XCTUnwrap(doc.select("p").first())
        var cursor = TextNode(text, nil)
        try parent.appendChild(cursor)
        _ = try parent.text()
        for scalar in text.unicodeScalars {
            cursor = try cursor.splitText(utf8Offset: scalar.utf8.count)
        }
        let nodes = parent.getChildNodes().compactMap { $0 as? TextNode }
        XCTAssertEqual(nodes.count, text.unicodeScalars.count + 1)
        XCTAssertEqual(nodes.flatMap { $0.getWholeTextUTF8() }, Array(text.utf8))
        XCTAssertEqual(Array(try parent.html().utf8), Array(text.utf8))
        for (index, node) in nodes.enumerated() {
            XCTAssertEqual(node.siblingIndex, index)
            XCTAssertTrue(node.parent() === parent)
        }
        let copy = try XCTUnwrap(parent.copy() as? Element)
        // An element clone is detached; supply the same output settings through
        // its new document instead of comparing against default pretty printing.
        let copiedDoc = try SwiftSoup.parse("")
        copiedDoc.outputSettings().prettyPrint(pretty: false)
        try copiedDoc.body()!.appendChild(copy)
        XCTAssertEqual(Array(try copy.html().utf8), Array(text.utf8))
        cursor.text("added")
        XCTAssertFalse(try copy.text().contains("added"))
        XCTAssertTrue(try parent.text().contains("added"))
    }

    func testByteGetterSnapshotAndBaseUriOverrideArePreserved() throws {
        final class ProjectedBytes: TextNode {
            var reads = 0
            override func getWholeTextUTF8() -> [UInt8] { reads += 1; return Array("日本".utf8) }
            override func getBaseUriUTF8() -> [UInt8] { Array("https://example.test/raw".utf8) }
            override func getBaseUri() -> String { "https://example.test/string-projection" }
        }
        let node = ProjectedBytes("underlying", nil)
        let tail = try node.splitText(utf8Offset: 3)
        XCTAssertEqual(node.reads, 1)
        XCTAssertEqual(tail.getWholeText(), "本")
        XCTAssertEqual(tail.getBaseUri(), "https://example.test/raw")
    }

    func testInvalidSplitKeepsMaterializedAttributeReferenceAndWarmCaches() throws {
        let doc = try SwiftSoup.parse("<p>日本</p>")
        let parent = try XCTUnwrap(doc.select("p").first())
        let node = try XCTUnwrap(parent.childNode(0) as? TextNode)
        let attr = try XCTUnwrap(node.getAttributes().asList().first)
        _ = try parent.text()
        _ = try doc.select("p:contains(日本)")
        let source = try parent.outerHtml()
        for offset in [1, 2, 4, 5, 7, Int.max] {
            XCTAssertThrowsError(try node.splitText(utf8Offset: offset))
            XCTAssertTrue(node.getAttributes().asList().first === attr)
            XCTAssertEqual(try parent.outerHtml(), source)
            XCTAssertTrue(try doc.select("p:contains(日本)").first() === parent)
        }
        attr.setValue(value: Array("変更".utf8))
        XCTAssertEqual(try doc.select("p:contains(日本)").size(), 0)
        XCTAssertEqual(try parent.text(), "変更")
    }

}
