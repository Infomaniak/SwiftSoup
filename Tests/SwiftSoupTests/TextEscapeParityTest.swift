import XCTest
import Foundation
@testable import SwiftSoup

final class TextEscapeParityTest: XCTestCase {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    // Independent byte oracle: a backslash quotes exactly the next byte. UTF-8
    // continuation bytes pass through unchanged; a terminal backslash is dropped.
    private func reference(_ input: String) -> [UInt8] {
        let source = bytes(input)
        var result: [UInt8] = []
        var i = 0
        while i < source.count {
            if source[i] == 92 { i += 1 }
            if i < source.count { result.append(source[i]); i += 1 }
        }
        return result
    }

    func testConsecutiveBackslashesAreConsumedInPairs() {
        for count in 0...128 {
            let input = String(repeating: "\\", count: count) + "x"
            let expected = String(repeating: "\\", count: count / 2) + "x"
            XCTAssertEqual(bytes(TokenQueue.unescape(input)), bytes(expected), "run \(count)")
        }
    }

    func testTerminalOddEscapeRetainsExistingDropBehavior() {
        for count in 0...128 {
            let input = "head" + String(repeating: "\\", count: count)
            XCTAssertEqual(bytes(TokenQueue.unescape(input)), bytes("head" + String(repeating: "\\", count: count / 2)))
        }
    }

    func testEscapesOperateOnScalarsWithinGraphemes() {
        for text in ["\u{301}", "\u{600}", "👩🏽‍💻", "🇯🇵", "\r\n", "日本", "\0", "\u{10FFFF}"] {
            let input = text.unicodeScalars.map { "\\" + String($0) }.joined()
            XCTAssertEqual(bytes(TokenQueue.unescape(input)), bytes(text))
        }
        XCTAssertEqual(bytes(TokenQueue.unescape("\u{600}\\x")), bytes("\u{600}x"))
    }

    func testNoEscapeAndSimpleLegacySpellingsStayUnchanged() {
        for input in ["", "日本語", "e\u{301}", "👩🏽‍💻", "a\0b", "\r\n"] {
            XCTAssertEqual(bytes(TokenQueue.unescape(input)), bytes(input))
        }
        XCTAssertEqual(TokenQueue.unescape(#"one \(two\) \\ three"#), "one (two) \\ three")
        // This API quotes text, not CSS hex identifiers; do not change its grammar.
        XCTAssertEqual(TokenQueue.unescape(#"\31 \20 "#), "31 20 ")
    }

    func testContainsAndOwnTextFindLiteralBackslashRuns() throws {
        for count in 1...12 {
            let target = "prefix" + String(repeating: "\\", count: count) + "(日本)"
            let escaped = target.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
            let doc = try SwiftSoup.parse("<main><p id='target'></p><p id='other'>unrelated</p></main>")
            try doc.select("#target").first()!.text(target)
            for predicate in ["contains", "containsOwn"] {
                for prefix in ["", "main > ", "#absent, "] {
                    XCTAssertEqual(try doc.select(prefix + "p:\(predicate)(\(escaped))").array().map { $0.id() }, ["target"], "run \(count)")
                }
            }
        }
    }

    func testContainsDataFindsLiteralBackslashRuns() throws {
        for count in 1...12 {
            let target = "prefix" + String(repeating: "\\", count: count) + "日本"
            let escaped = target.replacingOccurrences(of: "\\", with: "\\\\")
            let doc = try SwiftSoup.parse("<main><script id='target'></script><script id='other'></script></main>")
            let script = try XCTUnwrap(doc.select("#target").first())
            try script.appendChild(DataNode(Array(target.utf8), []))
            for prefix in ["", "main > "] {
                XCTAssertEqual(try doc.select(prefix + "script:containsData(\(escaped))").array().map { $0.id() }, ["target"])
            }
        }
    }

    func testRegexArgumentsAreNotTextUnescaped() throws {
        let doc = try SwiftSoup.parse("<main><p id='target'></p><p id='other'>other</p></main>")
        let target = "prefix\\\\日本"
        try doc.select("#target").first()!.text(target)
        let regex = "^" + NSRegularExpression.escapedPattern(for: target) + "$"
        for predicate in ["matches", "matchesOwn"] {
            for prefix in ["", "main > "] {
                XCTAssertEqual(try doc.select(prefix + "p:\(predicate)(\(regex))").array().map { $0.id() }, ["target"])
            }
        }
    }

    func testGeneratedEscapesMatchIndependentByteOracle() {
        let atoms = ["x", "日本", "\u{301}", "\u{600}", "👩🏽‍💻", "\r\n", "\0", "(", ")", "\\", #"\31 "#]
        for seed in 0..<1024 {
            let input = atoms[seed % atoms.count] + String(repeating: "\\", count: seed % 13)
                + atoms[(seed * 7 + 3) % atoms.count] + String(repeating: "\\", count: (seed / 13) % 7)
            XCTAssertEqual(bytes(TokenQueue.unescape(input)), reference(input), "seed \(seed)")
        }
    }
}
