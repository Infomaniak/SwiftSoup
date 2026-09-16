import Foundation
import XCTest
@testable import SwiftSoup

final class EntityEscapeRunTest: XCTestCase {
    private let modes = [Entities.EscapeMode.base, .extended, .xhtml]

    // Independent byte oracle for the historical non-normalizing UTF path.
    // Its deliberately permissive lead-byte stepping also covers malformed input.
    private func reference(_ bytes: [UInt8], attribute: Bool, xhtml: Bool) -> [UInt8] {
        var result: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b < 128 {
                let replacement: String?
                switch b {
                case 38: replacement = "&amp;"
                case 60 where !attribute || xhtml: replacement = "&lt;"
                case 62 where !attribute: replacement = "&gt;"
                case 34 where attribute: replacement = "&quot;"
                default: replacement = nil
                }
                if let replacement { result.append(contentsOf: replacement.utf8) }
                else { result.append(b) }
                i += 1
            } else {
                let width = b < 224 ? 2 : b < 240 ? 3 : 4
                let end = min(i + width, bytes.count)
                if end - i == 2 && b == 194 && bytes[i + 1] == 160 {
                    result.append(contentsOf: (xhtml ? "&#xa0;" : "&nbsp;").utf8)
                } else { result.append(contentsOf: bytes[i..<end]) }
                i = end
            }
        }
        return result
    }

    private func check(_ bytes: [UInt8], mode: Entities.EscapeMode, attribute: Bool,
                       encoding: String.Encoding = .utf8, file: StaticString = #filePath, line: UInt = #line) {
        let expected = reference(bytes, attribute: attribute, xhtml: mode == .xhtml)
        let settings = OutputSettings().charset(encoding).escapeMode(mode)
        func assertOutput(_ action: (StringBuilder) -> Void) {
            let builder = StringBuilder(1)
            action(builder)
            XCTAssertEqual(Array(builder.buffer), expected, file: file, line: line)
        }
        assertOutput { Entities.escape($0, bytes, settings, attribute, false, false) }
        let padded: [UInt8] = [255, 34, 60] + bytes + [38, 255]
        assertOutput { Entities.escape($0, padded[3..<(3 + bytes.count)], settings, attribute, false, false) }
        for storage in [ByteStorage(array: padded), ByteStorage(data: Data(padded)),
                        ByteStorage(data: Data([99] + padded).dropFirst())] {
            let slice = ByteSlice(storage: storage, start: 3, end: 3 + bytes.count)
            assertOutput { Entities.escape($0, slice, settings, attribute, false, false) }
        }
        padded.withUnsafeBufferPointer { buffer in
            let storage = ByteStorage(buffer: buffer.baseAddress!, count: buffer.count, owner: nil)
            let slice = ByteSlice(storage: storage, start: 3, end: 3 + bytes.count)
            assertOutput { Entities.escape($0, slice, settings, attribute, false, false) }
        }
    }

    func testUnicodeRunsAcrossSettingsAndStorage() {
        let texts = ["&", "&日本語東京京都", "&é¢£猫😀e\u{301}👩🏽‍💻",
                     "&日本語\u{A0}\u{A0}猫<犬>\"鳥\"", "&" + String(repeating: "日本語😀", count: 1024)]
        for text in texts {
            for mode in modes {
                for attribute in [false, true] {
                    for encoding in [String.Encoding.utf8, .utf16] {
                        check(Array(text.utf8), mode: mode, attribute: attribute, encoding: encoding)
                    }
                }
            }
        }
    }

    func testMalformedAndTruncatedRuns() {
        var seed: UInt64 = 0x6c616b652d666972
        for n in 0..<2048 {
            var bytes: [UInt8] = [38] // Forces the escaping path before any malformed bytes.
            for _ in 0..<(n % 65) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                bytes.append(UInt8(truncatingIfNeeded: seed >> 32))
            }
            for mode in modes {
                for attribute in [false, true] { check(bytes, mode: mode, attribute: attribute) }
            }
        }
    }

    func testEveryLeadByteAtBoundaries() {
        let suffixes: [[UInt8]] = [[], [38], [160], [34, 60], [194, 160], [38, 60, 62], [255, 255, 255]]
        for value in 0...255 {
            for suffix in suffixes {
                for attribute in [false, true] {
                    check([38, UInt8(value)] + suffix, mode: .xhtml, attribute: attribute)
                }
            }
        }
    }

    func testASCIIAndUnchangedPaths() {
        for text in ["", "no escaping", "日本語猫犬", "👩🏽‍💻 café", "&<>'\"", "\u{A0}"] {
            for mode in modes {
                let bytes = Array(text.utf8)
                for attribute in [false, true] { check(bytes, mode: mode, attribute: attribute) }
            }
        }
        let builder = StringBuilder()
        Entities.escape(builder, Array("  日本語\t & \n猫".utf8), OutputSettings(), false, true, true)
        XCTAssertEqual(builder.toString(), "日本語 &amp; 猫")
    }

    func testReplacementCallbacksAndSnapshots() {
        final class RecordingBuilder: StringBuilder {
            var replacements: [[UInt8]] = []
            override func append(_ value: [UInt8]) -> StringBuilder {
                replacements.append(value)
                return super.append(value)
            }
        }
        let builder = RecordingBuilder()
        _ = builder.append("prefix:")
        let snapshot = builder.buffer
        let bytes = Array("&猫犬\u{A0}鳥<魚>\"".utf8)
        Entities.escape(builder, bytes, OutputSettings().escapeMode(.xhtml), true, false, false)
        XCTAssertEqual(String(decoding: snapshot, as: UTF8.self), "prefix:")
        XCTAssertEqual(builder.replacements.map { String(decoding: $0, as: UTF8.self) },
                       ["&amp;", "&#xa0;", "&lt;", "&quot;"])
        XCTAssertEqual(builder.toString(), "prefix:&amp;猫犬&#xa0;鳥&lt;魚>&quot;")

        for useByteSlice in [false, true] {
            let alias = StringBuilder(string: "&猫犬😀<鳥>")
            let source = alias.buffer
            let before = Array(source)
            if useByteSlice {
                Entities.escape(alias, alias.asByteSlice(), OutputSettings(), false, false, false)
            } else {
                Entities.escape(alias, source, OutputSettings(), false, false, false)
            }
            XCTAssertEqual(Array(alias.buffer), before + reference(before, attribute: false, xhtml: false))
            XCTAssertEqual(Array(source), before)
        }
    }

    func testRegeneratedTextAndAttributes() throws {
        let text = "猫犬😀\u{A0}<東京>&京都\""
        let doc = Document("")
        doc.outputSettings().prettyPrint(pretty: false).escapeMode(.xhtml)
        let element = try doc.appendElement("p").text(text).attr("title", text)
        let expectedText = String(decoding: reference(Array(text.utf8), attribute: false, xhtml: true), as: UTF8.self)
        let expectedAttribute = String(decoding: reference(Array(text.utf8), attribute: true, xhtml: true), as: UTF8.self)
        let expected = "<p title=\"\(expectedAttribute)\">\(expectedText)</p>"
        for _ in 0..<4 { XCTAssertEqual(try element.outerHtml(), expected) }
        XCTAssertEqual(try Entities.unescape(expectedText), text)
    }
}
