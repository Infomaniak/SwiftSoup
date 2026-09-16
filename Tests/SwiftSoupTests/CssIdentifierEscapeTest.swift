import XCTest
@testable import SwiftSoup

final class CssIdentifierEscapeTest: XCTestCase {
    private func assertIdentifier(_ input: String, _ expected: String, remainder: String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
        let queue = TokenQueue(input)
        // Compare UTF-8, not Swift's canonically equivalent String equality.
        XCTAssertEqual(Array(expected.utf8), Array(queue.consumeCssIdentifier().utf8), input, file: file, line: line)
        XCTAssertEqual(Array(remainder.utf8), Array(queue.remainder().utf8), input, file: file, line: line)
        XCTAssertTrue(queue.isEmpty(), file: file, line: line)
    }

    func testOneThroughSixHexDigits() {
        for escape in [#"\a"#, #"\0a"#, #"\00a"#, #"\000a"#, #"\0000a"#, #"\00000a"#] {
            assertIdentifier(escape, "\n")
        }
        assertIdentifier(#"\61"#, "a")
        assertIdentifier(#"\4A\4b"#, "JK")
        assertIdentifier(#"\31 23"#, "123")
    }

    func testSixDigitLimitAndGreedyConsumption() {
        assertIdentifier(#"\000061b"#, "ab")
        assertIdentifier(#"\00003123"#, "123")
        assertIdentifier(#"\61b"#, "\u{061B}")
        assertIdentifier(#"\61 b"#, "ab")
        assertIdentifier(#"\ffffff0"#, "\u{FFFD}0")
    }

    func testUnicodeCodePointsAndBoundaries() {
        let cases: [(String, String)] = [
            (#"\7f"#, "\u{7F}"), (#"\80"#, "\u{80}"), (#"\7ff"#, "\u{7FF}"),
            (#"\800"#, "\u{800}"), (#"\d7ff"#, "\u{D7FF}"), (#"\e000"#, "\u{E000}"),
            (#"\ffff"#, "\u{FFFF}"), (#"\10000"#, "\u{10000}"), (#"\10ffff"#, "\u{10FFFF}"),
            (#"\1f600"#, "\u{1F600}"), (#"\65e5\672c"#, "日本")
        ]
        for (input, expected) in cases { assertIdentifier(input, expected) }
    }

    func testInvalidHexCodePointsUseReplacementCharacter() {
        for input in [#"\0"#, #"\000000"#, #"\d800"#, #"\DFFF"#, #"\110000"#, #"\FFFFFF"#] {
            assertIdentifier(input + "z", "\u{FFFD}z")
        }
    }

    func testAllCssWhitespaceTerminatorsIncludingCRLF() {
        for whitespace in [" ", "\t", "\n", "\r", "\u{C}", "\r\n"] {
            assertIdentifier(#"\61"# + whitespace + "b", "ab")
            assertIdentifier(#"\000061"# + whitespace + "b", "ab")
            assertIdentifier(#"\61"# + whitespace + " b", "a", remainder: " b")
        }
    }

    func testOnlyCssWhitespaceTerminatesAnEscape() {
        assertIdentifier(#"\61"# + "\u{A0}b", "a\u{A0}b")
        assertIdentifier(#"\61"# + "\u{2003}b", "a\u{2003}b")
        assertIdentifier(#"\61"# + "\u{B}b", "a", remainder: "\u{B}b")
    }

    func testDecodedPunctuationStaysInTheIdentifier() {
        assertIdentifier(#"x\2e y\23 z\20 q\5c r"#, #"x.y#z q\r"#)
        assertIdentifier(#"\61.class"#, "a", remainder: ".class")
        assertIdentifier(#"\61>p"#, "a", remainder: ">p")
    }

    func testSimpleEscapesAndLiteralBackslashesArePreserved() {
        assertIdentifier(#"quote\$body\/main"#, "quote$body/main")
        assertIdentifier(#"Fz\(xs\)"#, "Fz(xs)")
        assertIdentifier(#"x\\61"#, #"x\61"#)
        assertIdentifier(#"a\ b"#, "a b")
        assertIdentifier(#"\日本"#, "日本")
        assertIdentifier(#"plain-123_name"#, "plain-123_name")
        // This patch does not tighten the existing malformed non-hex escape handling.
        assertIdentifier("a\\", "a")
        assertIdentifier("\\\r\nz", "\r\nz")
        XCTAssertEqual("61", TokenQueue.unescape(#"\61"#))
    }

    func testHexDigitFollowedByCombiningMark() {
        assertIdentifier(#"\61"# + "\u{301}", "a\u{301}")
        assertIdentifier(#"\000061"# + "\u{301}b", "a\u{301}b")
        assertIdentifier(#"\61 "# + "\u{301}b", "a\u{301}b")
    }

    func testConsumptionFromNonzeroQueuePosition() throws {
        let queue = TokenQueue(#"prefix\61.foo"#)
        try queue.consume("prefix")
        XCTAssertEqual("a", queue.consumeCssIdentifier())
        try queue.consume(".")
        XCTAssertEqual("foo", queue.consumeCssIdentifier())
        XCTAssertTrue(queue.isEmpty())
    }

    func testRawEscapePreservesExactlyOneTerminator() {
        for whitespace in [" ", "\t", "\n", "\r", "\u{C}", "\r\n"] {
            let raw = #"\000061"# + whitespace
            let queue = TokenQueue(raw + " b")
            XCTAssertEqual(raw, queue.consumeCssEscapeSequence())
            XCTAssertEqual(" b", queue.remainder())
        }
        let queue = TokenQueue(#"\61"# + "\u{A0}b")
        XCTAssertEqual(#"\61"#, queue.consumeCssEscapeSequence())
        XCTAssertEqual("\u{A0}b", queue.remainder())
    }

    func testRawEscapeDoesNotLosePartialGrapheme() {
        let queue = TokenQueue(#"\000061"# + "\u{301}.next")
        XCTAssertEqual(#"\000061"#, queue.consumeCssEscapeSequence())
        XCTAssertEqual("\u{301}", queue.consumeCssIdentifier())
        XCTAssertEqual(".next", queue.remainder())
    }
}

final class HexEscapedSelectorTest: XCTestCase {
    private func assertSelects(_ doc: Document, _ query: String, _ expected: Element,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        // Exercise uncached/cached public selection and the non-indexed evaluator path.
        for _ in 0..<2 {
            let matches = try doc.select(query)
            XCTAssertEqual(1, matches.size(), query, file: file, line: line)
            XCTAssertTrue(matches.first() === expected, query, file: file, line: line)
        }
        let collected = try Collector.collect(QueryParser.parse(query), doc)
        XCTAssertEqual(1, collected.size(), query, file: file, line: line)
        XCTAssertTrue(collected.first() === expected, query, file: file, line: line)
    }

    func testHexEscapesAcrossIdAndClassSelectorPaths() throws {
        let cases: [(String, String)] = [
            (#"\61"#, "a"), (#"\000061"#, "a"), (#"\31 23"#, "123"),
            (#"\00003123"#, "123"), (#"\61 b"#, "ab"), (#"\000061b"#, "ab"),
            (#"\4A\4b"#, "JK"), (#"\1F600"#, "\u{1F600}"), (#"\65e5\672c"#, "日本"),
            (#"\61"# + "\u{301}", "a\u{301}")
        ]
        for (escaped, value) in cases {
            let doc = try SwiftSoup.parse("<main><p>hit</p><p>miss</p></main>")
            let target = try XCTUnwrap(doc.select("p").first())
            try target.attr("id", value).attr("class", value)
            for marker in ["#", "."] {
                for prefix in ["", "p", "body ", "main > ", "main "] {
                    try assertSelects(doc, prefix + marker + escaped, target)
                }
            }
        }
    }

    func testOldLiteralInterpretationDoesNotSelectWrongElement() throws {
        let doc = try SwiftSoup.parse(#"<p id="a">correct</p><p id="61">digits</p><p id="\61">literal</p>"#)
        let correct = try XCTUnwrap(doc.getElementById("a"))
        for query in [#"#\61"#, #"p#\61"#, #"body #\61"#, #"body > #\61"#] {
            try assertSelects(doc, query, correct)
        }
        // Explicit migration for clients that intended the old literal identifier.
        XCTAssertEqual("digits", try doc.select(#"#\36 1"#).text())
        XCTAssertEqual("literal", try doc.select(#"#\\61"#).text())
    }

    func testEscapeWhitespaceIsNotADescendantCombinator() throws {
        let doc = try SwiftSoup.parse(#"<div id="a"><b>descendant</b></div><p id="ab">identifier</p>"#)
        let identifier = try XCTUnwrap(doc.getElementById("ab"))
        let descendant = try XCTUnwrap(doc.select("b").first())
        for prefix in ["", "body ", "body > "] {
            try assertSelects(doc, prefix + #"#\61 b"#, identifier)
            try assertSelects(doc, prefix + #"#\61  b"#, descendant)
            try assertSelects(doc, prefix + #"#\000061 b"#, identifier)
        }
    }

    func testWhitespaceTerminatorsInCompoundSelectors() throws {
        let doc = try SwiftSoup.parse(#"<main><p id="123" class="123">hit</p></main>"#)
        let target = try XCTUnwrap(doc.select("p").first())
        for whitespace in [" ", "\t", "\n", "\r", "\u{C}", "\r\n"] {
            for prefix in ["#", "p#", "main #", "main > #", "main .", "main > p."] {
                try assertSelects(doc, prefix + #"\31"# + whitespace + "23", target)
            }
        }
    }

    func testSiblingCombinatorsGroupsAndNestedSelectors() throws {
        let doc = try SwiftSoup.parse(#"<main><p>before</p><p id="ab">hit</p></main>"#)
        let target = try XCTUnwrap(doc.getElementById("ab"))
        for query in [#"p + p#\61 b"#, #"p ~ p#\61 b"#, #"#missing, p#\61 b"#,
                      #"main:has(> p#\61 b) > p#\61 b"#, #"main > p:not(:not(#\61 b))"#] {
            try assertSelects(doc, query, target)
        }
    }

    func testEscapedDelimitersRemainLiteralInCompoundSelectors() throws {
        for (hex, literal) in [("2e", "."), ("23", "#"), ("2c", ","), ("3e", ">"), ("2b", "+"),
                               ("7e", "~"), ("5b", "["), ("5d", "]"), ("28", "("), ("29", ")"), ("5c", "\\")] {
            let doc = try SwiftSoup.parse("<main><p>hit</p></main>")
            let target = try XCTUnwrap(doc.select("p").first())
            try target.attr("id", "x" + literal + "y").attr("class", "x" + literal + "y")
            for prefix in ["#", "main > #", "main .", "main > p."] {
                try assertSelects(doc, prefix + "x\\" + hex + " y", target)
            }
        }
    }

    func testReplacementCharacterMatchesInvalidCodePointEscapes() throws {
        let doc = try SwiftSoup.parse("<main><p id='\u{FFFD}' class='\u{FFFD}'>hit</p></main>")
        let target = try XCTUnwrap(doc.select("p").first())
        for escape in [#"\0"#, #"\d800"#, #"\DFFF"#, #"\110000"#, #"\FFFFFF"#] {
            for prefix in ["#", "main > #", "main > p."] {
                try assertSelects(doc, prefix + escape, target)
            }
        }
    }

    func testGeneratedSelectorsStillRoundTrip() throws {
        for value in ["plain", "123", "a$b/c", "Fz(xs)", #"x\61"#, "日本", "e\u{301}", "a b"] {
            let doc = try SwiftSoup.parse("<main><p>hit</p><p>miss</p></main>")
            let target = try XCTUnwrap(doc.select("p").first())
            try target.attr("id", value)
            try assertSelects(doc, target.cssSelector(), target)
        }
    }
}
