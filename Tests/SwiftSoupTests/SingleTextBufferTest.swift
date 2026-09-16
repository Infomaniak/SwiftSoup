import Foundation
import XCTest
@testable import SwiftSoup

final class SingleTextBufferTest: XCTestCase {
    private func assertReads(_ bytes: [UInt8], slice: ByteSlice,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let root = try Element(Tag.valueOf("p"), "")
        try root.appendChild(TextNode(slice: slice, baseUri: []))
        XCTAssertEqual(try root.text(trimAndNormaliseWhitespace: false),
                       String(decoding: bytes, as: UTF8.self), file: file, line: line)
        // Reference the general text traversal rather than the single-node fast path.
        let reference = try Element(Tag.valueOf("p"), "")
        try reference.appendChild(TextNode(bytes, []))
        try reference.appendChild(TextNode([], []))
        XCTAssertEqual(try root.text(), try reference.text(), file: file, line: line)
        XCTAssertEqual(try root.textUTF8(), try reference.textUTF8(), file: file, line: line)
        XCTAssertEqual(try root.textUTF8Slice(), try reference.textUTF8Slice(), file: file, line: line)
    }

    func testAllByteValuesAndMalformedUTF8AcrossBackings() throws {
        let cases: [[UInt8]] = [[], Array("日本語😀é & text".utf8), Array("a\u{00a0}b\t\r\n c".utf8),
            [0, 1, 127, 255, 192, 160], Array(0...255)] + (0...255).map { [UInt8($0)] }
        for bytes in cases {
            let padded = [UInt8(250)] + bytes + [251]
            let array = ByteStorage(array: padded)
            try assertReads(bytes, slice: ByteSlice(storage: array, start: 1, end: bytes.count + 1))
            let data = ByteStorage(data: Data([249] + padded).dropFirst())
            try assertReads(bytes, slice: ByteSlice(storage: data, start: 1, end: bytes.count + 1))
            try padded.withUnsafeBufferPointer { buffer in
                let borrowed = ByteStorage(buffer: buffer.baseAddress!, count: buffer.count, owner: nil)
                try assertReads(bytes, slice: ByteSlice(storage: borrowed, start: 1, end: bytes.count + 1))
            }
        }
    }

    func testWhitespaceEntitiesFragmentsAndXML() throws {
        for content in ["", "\t x \n", "a&nbsp;b", "日本語", "éà", "a&#160;b", "a&#0;b", "😀", " &amp; &lt; "] {
            for parser in [Parser.htmlParser(), Parser.xmlParser()] {
                let doc = try parser.parseInput("<root><p>\(content)</p><pre>\(content)</pre></root>", "")
                for tag in ["p", "pre"] {
                    let element = try XCTUnwrap(doc.getElementsByTag(tag).first())
                    let before = try element.text()
                    let raw = try element.text(trimAndNormaliseWhitespace: false)
                    guard let node = element.getChildNodes().first as? TextNode else {
                        XCTAssertEqual(raw, "")
                        continue
                    }
                    _ = node.getWholeTextUTF8() // Materialize backing.
                    XCTAssertEqual(try element.text(), before)
                    XCTAssertEqual(try element.text(trimAndNormaliseWhitespace: false), raw)
                }
            }
        }
    }

    func testAttributeBackedTextMutationAndSelectorCaches() throws {
        let doc = try SwiftSoup.parse("<p>日本語</p>")
        let p = try XCTUnwrap(doc.getElementsByTag("p").first())
        let text = p.childNode(0) as! TextNode
        _ = text.getAttributes()
        for _ in 0..<4 { _ = try doc.select("p:contains(日本語)") }
        text.text("変更\t後")
        XCTAssertEqual(try p.text(), "変更 後")
        XCTAssertEqual(try p.text(trimAndNormaliseWhitespace: false), "変更\t後")
        XCTAssertEqual(try doc.select("p:contains(日本語)").size(), 0)
        XCTAssertEqual(try doc.select("p:contains(変更)").size(), 1)
    }

    func testLongSingleTextSlicesWithLateWhitespace() throws {
        for count in [1, 7, 15, 16, 31, 32, 255, 4096] {
            for suffix in ["語", "\t", "\u{00a0}", " ", "é"] {
                let bytes = Array((String(repeating: "日", count: count) + suffix).utf8)
                try assertReads(bytes, slice: .fromArray(bytes))
            }
        }
    }
}