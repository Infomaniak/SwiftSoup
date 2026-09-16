import XCTest
@testable import SwiftSoup

final class TextSplitBoundaryTest: XCTestCase {
    func testCharacterOffsetsUseCharactersRatherThanBytes() throws {
        for value in ["日本語", "A🇯🇵e\u{301}👨‍👩‍👧‍👦Z", "a\r\nb", "éé"] {
            let characters = Array(value)
            for offset in 0...characters.count {
                let node = TextNode(value, "https://example.test/")
                let tail = try node.splitText(offset)
                XCTAssertEqual(Array(node.getWholeTextUTF8()), Array(String(characters[..<offset]).utf8))
                XCTAssertEqual(Array(tail.getWholeTextUTF8()), Array(String(characters[offset...]).utf8))
                XCTAssertEqual(tail.getBaseUri(), "https://example.test/")
                XCTAssertNil(tail.parent())
            }
        }
    }
    func testCharacterOffsetsBetweenCharacterCountAndByteCountThrow() throws {
        for value in ["日本", "🇯🇵", "e\u{301}"] {
            let node = TextNode(value, "")
            let version = node.textMutationVersionToken()
            for offset in (value.count + 1)..<value.utf8.count {
                XCTAssertThrowsError(try node.splitText(offset), "\(value) @ \(offset)")
                XCTAssertEqual(Array(node.getWholeTextUTF8()), Array(value.utf8))
                XCTAssertEqual(version, node.textMutationVersionToken())
            }
        }
    }
    func testEndAndEmptyCharacterOffsetsAreValid() throws {
        for value in ["", "abc", "日本", "🇯🇵"] {
            let node = TextNode(value, "")
            let tail = try node.splitText(value.count)
            XCTAssertEqual(node.getWholeText(), value)
            XCTAssertEqual(tail.getWholeText(), "")
        }
    }
    func testByteOffsetsAtEveryScalarBoundaryAreExact() throws {
        for value in ["日本語", "e\u{301}x", "🇯🇵!", "👨‍👩‍👧‍👦x", "a\r\nb", "a\u{0}b"] {
            var offsets = [0]
            for scalar in value.unicodeScalars { offsets.append(offsets.last! + String(scalar).utf8.count) }
            let bytes = Array(value.utf8)
            for offset in offsets {
                let node = TextNode(value, "")
                let tail = try node.splitText(utf8Offset: offset)
                XCTAssertEqual(node.getWholeTextUTF8(), Array(bytes[..<offset]), "\(value) @ \(offset)")
                XCTAssertEqual(tail.getWholeTextUTF8(), Array(bytes[offset...]), "\(value) @ \(offset)")
            }
        }
    }
    func testByteOffsetsInsideScalarsThrowWithoutMutation() throws {
        for value in ["日本", "é", "🇯🇵", "a👩‍🔬b"] {
            let bytes = Array(value.utf8)
            for offset in bytes.indices where bytes[offset] & 0xC0 == 0x80 {
                let node = TextNode(value, "")
                let version = node.textMutationVersionToken()
                XCTAssertThrowsError(try node.splitText(utf8Offset: offset))
                XCTAssertEqual(node.getWholeTextUTF8(), bytes)
                XCTAssertEqual(node.textMutationVersionToken(), version)
            }
        }
    }
    func testEndAndEmptyByteOffsetsAreValid() throws {
        for value in ["", "abc", "日本", "e\u{301}"] {
            let node = TextNode(value, "")
            let tail = try node.splitText(utf8Offset: value.utf8.count)
            XCTAssertEqual(node.getWholeTextUTF8(), Array(value.utf8))
            XCTAssertEqual(tail.getWholeTextUTF8(), [])
        }
    }
    func testInvalidBoundsAreAtomicInAttachedNodes() throws {
        for byteOffset in [false,true] {
            for offset in [-1, Int.min, 100, Int.max] {
                let doc = try SwiftSoup.parse("<p>日本語</p>")
                let parent = try XCTUnwrap(doc.select("p").first())
                let node = try XCTUnwrap(parent.textNodes().first)
                let before = try doc.outerHtml()
                let version = doc.textMutationVersionToken()
                if byteOffset { XCTAssertThrowsError(try node.splitText(utf8Offset: offset)) }
                else { XCTAssertThrowsError(try node.splitText(offset)) }
                XCTAssertEqual(try doc.outerHtml(), before)
                XCTAssertEqual(doc.textMutationVersionToken(), version)
                XCTAssertEqual(parent.childNodeSize(), 1)
                XCTAssertTrue(node.parent() === parent)
            }
        }
    }
    func testSplitKeepsSiblingIdentityOrderAndWarmedSelectionCurrent() throws {
        let doc = try SwiftSoup.parse("<p>日本語<i>suffix</i></p>")
        let parent = try XCTUnwrap(doc.select("p").first())
        let node = try XCTUnwrap(parent.textNodes().first)
        let suffix = parent.childNode(1)
        for _ in 0..<3 { XCTAssertTrue(try doc.select("p:contains(日本語)").first() === parent) }
        let tail = try node.splitText(utf8Offset: 3)
        XCTAssertTrue(parent.childNode(0) === node)
        XCTAssertTrue(parent.childNode(1) === tail)
        XCTAssertTrue(parent.childNode(2) === suffix)
        XCTAssertEqual(tail.siblingIndex, 1)
        XCTAssertEqual(suffix.siblingIndex, 2)
        tail.text("別")
        XCTAssertEqual(try doc.select("p:contains(日本語)").size(), 0)
        XCTAssertTrue(try doc.select("p:contains(日別)").first() === parent)
        XCTAssertTrue(try parent.html().contains("日別"))
    }
    func testScalarSplitInsideGraphemeRemainsExactAfterRecombining() throws {
        for value in ["e\u{301}", "🇯🇵", "👩‍🔬", "\r\n"] {
            let first = String(value.unicodeScalars.first!)
            let parent = Element(try Tag.valueOf("span"), "")
            let node = TextNode(value, "")
            try parent.appendChild(node)
            let tail = try node.splitText(utf8Offset: first.utf8.count)
            XCTAssertEqual(node.getWholeTextUTF8() + tail.getWholeTextUTF8(), Array(value.utf8))
            XCTAssertEqual(Array(try parent.text(trimAndNormaliseWhitespace: false).utf8), Array(value.utf8))
        }
    }
    func testByteSplitRejectsInvalidStoredUTF8WithoutRepairingIt() throws {
        for bytes: [UInt8] in [[0xFF,0x41], [0xE3,0x81], [0xC0,0xAF,0x41]] {
            let node = TextNode(bytes, [])
            XCTAssertThrowsError(try node.splitText(utf8Offset: 1))
            XCTAssertEqual(node.getWholeTextUTF8(), bytes)
        }
    }
    func testSplitDeferredFragmentedAndMaterializedText() throws {
        for materialized in [false,true] {
            let node = TextNode(slice: ByteSlice.fromArray(Array("e".utf8)), baseUri: [])
            node.appendSlice(ByteSlice.fromArray(Array("\u{301}x".utf8)))
            if materialized { _ = node.getAttributes().size() }
            let tail = try node.splitText(utf8Offset: 1)
            XCTAssertEqual(node.getWholeTextUTF8(), Array("e".utf8))
            XCTAssertEqual(tail.getWholeTextUTF8(), Array("\u{301}x".utf8))
            XCTAssertEqual(try node.attr("text"), "e")
        }
    }
    func testCharacterSplitReadsPublicTextProjectionOnce() throws {
        final class Projected: TextNode {
            var reads = 0
            override func getWholeText() -> String {
                reads += 1
                return reads == 1 ? "日本語" : "changed"
            }
        }
        let node = Projected("backing", "")
        let tail = try node.splitText(1)
        XCTAssertEqual(node.reads, 1)
        XCTAssertEqual(node.getWholeTextUTF8(), Array("日".utf8))
        XCTAssertEqual(tail.getWholeTextUTF8(), Array("本語".utf8))
    }
    func testTailRetainsExactBaseURIBytes() throws {
        let base: [UInt8] = [0x2f, 0xff, 0x80, 0x61]
        for useBytes in [false, true] {
            let node = TextNode(Array("abc".utf8), base)
            let tail = try useBytes ? node.splitText(utf8Offset: 1) : node.splitText(1)
            XCTAssertEqual(tail.getBaseUriUTF8(), base)
        }
    }
    func testByteSplitReadsProjectionOnceAndDoesNotDelegateToCharacterOffset() throws {
        final class Projected: TextNode {
            var reads = 0
            override func getWholeTextUTF8() -> [UInt8] {
                reads += 1
                return Array((reads == 1 ? "e\u{301}x" : "other").utf8)
            }
            override func splitText(_ offset: Int) throws -> TextNode {
                XCTFail("A byte offset must not be reinterpreted as a Character offset")
                return self
            }
        }
        let node = Projected("backing", "")
        let tail = try node.splitText(utf8Offset: 1)
        XCTAssertEqual(node.reads, 1)
        XCTAssertEqual(tail.getWholeTextUTF8(), Array("\u{301}x".utf8))
    }

    func testGeneratedUnicodeSplitsAgainstIndependentByteAndCharacterModels() throws {
        let scalars: [UnicodeScalar] = ["A", "é", "日", "\u{301}", "\u{200D}", "\u{1F1EF}", "\u{1F1F5}", "\u{1F469}", "\u{1F3FD}", "\u{1F52C}", "\r", "\n", "\u{0}"]
        var state: UInt64 = 0xAB931E
        for iteration in 0..<256 {
            var value = ""
            for _ in 0..<(iteration % 7 + 1) {
                state = state &* 6364136223846793005 &+ 1
                value.unicodeScalars.append(scalars[Int((state >> 32) % UInt64(scalars.count))])
            }
            let bytes = Array(value.utf8)
            for offset in 0...bytes.count {
                let node = TextNode(value, "")
                if offset < bytes.count && bytes[offset] & 0xC0 == 0x80 {
                    XCTAssertThrowsError(try node.splitText(utf8Offset: offset))
                    XCTAssertEqual(node.getWholeTextUTF8(), bytes)
                } else {
                    let tail = try node.splitText(utf8Offset: offset)
                    XCTAssertEqual(node.getWholeTextUTF8(), Array(bytes[..<offset]))
                    XCTAssertEqual(tail.getWholeTextUTF8(), Array(bytes[offset...]))
                }
            }
            let characters = Array(value)
            for offset in 0...characters.count {
                let node = TextNode(value, "")
                let tail = try node.splitText(offset)
                XCTAssertEqual(node.getWholeTextUTF8(), Array(String(characters[..<offset]).utf8))
                XCTAssertEqual(tail.getWholeTextUTF8(), Array(String(characters[offset...]).utf8))
            }
        }
    }

}
