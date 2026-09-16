import XCTest
@testable import SwiftSoup

final class CssEscapeReviewTest: XCTestCase {
    private func assertQuery(_ doc: Document, _ query: String, _ expected: [Element],
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let ids = expected.map(ObjectIdentifier.init)
        for _ in 0..<4 {
            XCTAssertEqual(try doc.select(query).array().map(ObjectIdentifier.init), ids,
                           query.debugDescription, file: file, line: line)
        }
        let evaluator = try QueryParser.parse(query)
        XCTAssertEqual(try Collector.collect(evaluator, doc).array().map(ObjectIdentifier.init), ids,
                       query.debugDescription, file: file, line: line)
        XCTAssertEqual(try doc.getAllElements().array().filter { try evaluator.matches(doc, $0) }
            .map(ObjectIdentifier.init), ids, query.debugDescription, file: file, line: line)
    }

    func testGeneratedUnicodeWhitespaceIdentifiers() throws {
        for scalar in ["\u{85}", "\u{A0}", "\u{1680}", "\u{2000}", "\u{2003}", "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}"] {
            for id in [scalar, "x" + scalar, scalar + "x"] {
                let doc = try SwiftSoup.parse("<main><p>target</p><p id='x'>plain</p></main>")
                let target = try doc.select("p").get(0)
                try target.attr("id", id)
                try assertQuery(doc, target.cssSelector(), [target])
            }
        }
    }

    func testTrailingSimpleEscapedSpace() throws {
        let doc = try SwiftSoup.parse("<main><p id='x '>target</p><p id='x'>plain</p></main>")
        let target = try doc.select("p").get(0)
        for query in ["#x\\ ", "p#x\\ ", "main > #x\\ ", "p#x\\   "] {
            try assertQuery(doc, query, [target])
        }
    }

    func testBalancedBackslashParity() throws {
        let doc = try SwiftSoup.parse("<main><p>target</p><p>other</p></main>")
        let target = try doc.select("p").get(0)
        for id in ["x\\", "x\\\\", "x\\)", "x\\(", "x)", "x("] {
            try target.attr("id", id)
            let q = try target.cssSelector()
            try assertQuery(doc, "p:not(:not(" + q + "))", [target])
            try assertQuery(doc, "main > p:not(:not(" + q + "))", [target])
            try assertQuery(doc, "main:has(> " + q + ")", [try doc.select("main").get(0)])
        }
    }

    func testNestedCombiningDelimiters() throws {
        let doc = try SwiftSoup.parse("<main><p>target</p><p>other</p></main>")
        let target = try doc.select("p").get(0)
        for id in [")\u{301}", "(\u{301}", "'\u{301}", "\"\u{301}", "\\\u{301}", "]\u{301}", "[\u{301}"] {
            try target.attr("id", id)
            let q = try target.cssSelector()
            try assertQuery(doc, "p:not(:not(" + q + "))", [target])
            try assertQuery(doc, "main > p:not(:not(" + q + "))", [target])
        }
    }

    func testEscapedClassWhitespaceNeverMatchesAClassList() throws {
        for whitespace in [" ", "\t", "\n", "\r", "\u{C}"] {
            for name in ["a" + whitespace + "b", whitespace + "a", "a" + whitespace] {
                let doc = try SwiftSoup.parse("<main><p>target</p><p>other</p></main>")
                let target = try doc.select("p").get(0)
                try target.attr("class", name)
                XCTAssertFalse(target.hasClass(name))
                XCTAssertFalse(target.hasClass(Array(name.utf8)))
                let encoded = name.unicodeScalars.map { "\\" + String($0.value, radix: 16) + " " }.joined()
                for prefix in [".", "p.", "main > ."] {
                    try assertQuery(doc, prefix + encoded, [])
                }
                try assertQuery(doc, "p:not(." + encoded + ")", try doc.select("p").array())
                try assertQuery(doc, "main:has(." + encoded + ")", [])
            }
        }
    }

    func testPaddingDoesNotStripUnicodeIdentifierContent() throws {
        for scalar in ["\u{A0}", "\u{2003}", "\u{2028}", "\u{3000}"] {
            let doc = try SwiftSoup.parse("<main><p>target</p><p id='x'>plain</p></main>")
            let target = try doc.select("p").get(0)
            try target.attr("id", "x" + scalar).attr("class", "x" + scalar)
            for query in ["#x" + scalar, ".x" + scalar, "main > #x" + scalar] {
                for pad in [" ", "\t", "\r\n", "\u{C}"] {
                    try assertQuery(doc, pad + query + pad, [target])
                }
            }
        }
    }

    func testBalancedQuotesOnlyCloseWithTheirOwnDelimiter() {
        for (input, expected) in [(#"("a'b)c")tail"#, #""a'b)c""#), (#"('a"b)c')tail"#, #"'a"b)c'"#)] {
            let queue = TokenQueue(input)
            XCTAssertEqual(Array(queue.chompBalanced("(", ")").utf8), Array(expected.utf8))
            XCTAssertEqual(queue.remainder(), "tail")
        }
    }

    func testGeneratedIdsRoundTripAcrossAllNonzeroAsciiScalars() throws {
        for codePoint in UInt32(1)...UInt32(127) {
            let scalar = String(try XCTUnwrap(UnicodeScalar(codePoint)))
            for identifier in [scalar, "x" + scalar, scalar + "x"] {
                let doc = try SwiftSoup.parse("<main><p>target</p><p>other</p></main>")
                let target = try doc.select("p").get(0)
                try target.attr("id", identifier)
                let query = try target.cssSelector()
                try assertQuery(doc, query, [target])
                try assertQuery(doc, "main > " + query, [target])
                try assertQuery(doc, "p:not(:not(" + query + "))", [target])
            }
        }
    }

    func testGeneratedClassesRoundTripAcrossAsciiNonSeparators() throws {
        let separators: Set<UInt32> = [0x09, 0x0A, 0x0C, 0x0D, 0x20]
        for codePoint in UInt32(1)...UInt32(127) where !separators.contains(codePoint) {
            let scalar = String(try XCTUnwrap(UnicodeScalar(codePoint)))
            for identifier in [scalar, "x" + scalar, scalar + "x"] {
                let doc = try SwiftSoup.parse("<main><p>target</p><p>other</p></main>")
                let target = try doc.select("p").get(0)
                try target.attr("class", identifier)
                // ID serialization gives an independent spelling of the same
                // identifier without going through classNames() tokenization.
                let dummy = try Element(Tag.valueOf("p"), "")
                try dummy.attr("id", identifier)
                let classQuery = "." + String(try dummy.cssSelector().dropFirst())
                try assertQuery(doc, classQuery, [target])
                try assertQuery(doc, target.cssSelector(), [target])
                XCTAssertTrue(target.hasClass(identifier))
                XCTAssertEqual(Array(try target.classNamesUTF8()), [Array(identifier.utf8)])
            }
        }
    }
    func testNestedIdentifiersBeforeClosingDelimiterWithPrependCharacters() throws {
        for codePoint: UInt32 in [0x0600, 0x06DD, 0x070F, 0x08E2, 0x110BD, 0x110CD] {
            let scalar = String(try XCTUnwrap(UnicodeScalar(codePoint)))
            for identifier in [scalar, "x" + scalar] {
                let doc = try SwiftSoup.parse("<main><p>target</p><p>other</p></main>")
                let target = try doc.select("p").get(0)
                try target.attr("id", identifier).attr("class", identifier)
                for prefix in ["#", "."] {
                    let query = prefix + identifier
                    try assertQuery(doc, "p:not(:not(" + query + "))", [target])
                    try assertQuery(doc, "main:has(> " + query + ") > p", try doc.select("p").array())
                }
            }
        }
    }

    func testBalancedScannerPreservesScalarBoundariesAndPublicDelimiters() throws {
        let queue = TokenQueue("prefix(\u{301}text\u{600})\u{301}tail")
        try queue.consume("prefix")
        XCTAssertEqual(Array(queue.chompBalanced("(", ")").utf8), Array("\u{301}text\u{600}".utf8))
        XCTAssertEqual(Array(queue.remainder().utf8), Array("\u{301}tail".utf8))

        let open: Character = "👩‍💻"
        let close: Character = "👨‍💻"
        let payload = "one " + String(open) + "two" + String(close)
        let custom = TokenQueue(String(open) + payload + String(close) + "tail")
        XCTAssertEqual(custom.chompBalanced(open, close), payload)
        XCTAssertEqual(custom.remainder(), "tail")
    }

    func testQueryPaddingRespectsBackslashParityAndHexTerminators() throws {
        let doc = try SwiftSoup.parse("<main><p></p><p></p><p></p></main>")
        let targets = try doc.select("p").array()
        try targets[0].attr("id", "x ")
        try targets[1].attr("id", "x\\")
        try targets[2].attr("id", "x\\ ")
        for (query, index) in [("#x\\ ", 0), ("#x\\   ", 0), (#"#x\20 "#, 0),
                               ("#x\\\\ ", 1), ("#x\\\\   ", 1), ("#x\\\\\\ ", 2)] {
            for prefix in ["", "main > "] {
                let padded = "\t" + prefix + query + " \r\n"
                try assertQuery(doc, padded, [targets[index]])
                let evaluator = try QueryParser.parse(padded)
                XCTAssertTrue(try evaluator.matches(doc, targets[index]))
                XCTAssertTrue(try CssSelector.select(padded, [doc]).first() === targets[index])
            }
        }
    }

    func testVerticalTabRemainsPartOfClassTokensAfterMutation() throws {
        let doc = try SwiftSoup.parse("<main><p class='before'></p><p class='x'></p></main>")
        let target = try doc.select("p").get(0)
        let root = try doc.select("main").get(0)
        try assertQuery(doc, ".before", [target])
        let cases = [("\u{B}", ["\u{B}"]), (" \t\u{B} \n", ["\u{B}"]),
                     ("a\u{B}x", ["a\u{B}x"]), ("first a\u{B}x last", ["first", "a\u{B}x", "last"])]
        for (classList, tokens) in cases {
            try target.attr("class", classList)
            XCTAssertEqual(try target.className(), tokens.joined(separator: " "))
            XCTAssertEqual(try target.classNameUTF8(), Array(tokens.joined(separator: " ").utf8))
            XCTAssertEqual(Array(try target.classNames()), tokens)
            XCTAssertEqual(Array(try target.classNamesUTF8()), tokens.map { Array($0.utf8) })
            XCTAssertEqual(try target.unorderedClassNamesUTF8().map(Array.init), tokens.map { Array($0.utf8) })
            for token in tokens {
                let encoded = token.unicodeScalars.map { "\\" + String($0.value, radix: 16) + " " }.joined()
                try assertQuery(doc, "." + encoded, [target])
                XCTAssertTrue(try root.select("." + encoded).first() === target)
                XCTAssertTrue(target.hasClass(token))
            }
            try assertQuery(doc, ".before", [])
        }
        try target.removeAttr("class")
        try assertQuery(doc, #".a\b x"#, [])
    }

    func testCompoundBoundariesDoNotConsumeAdjacentPrependCharacters() throws {
        for codePoint: UInt32 in [0x0600, 0x06DD, 0x070F, 0x08E2, 0x110BD, 0x110CD] {
            let identifier = String(try XCTUnwrap(UnicodeScalar(codePoint)))
            let doc = try SwiftSoup.parse("<main><p><span></span></p><p></p></main>")
            let target = try doc.select("p").get(0)
            let sibling = try doc.select("p").get(1)
            let child = try doc.select("span").get(0)
            try target.attr("id", identifier).attr("class", identifier)
            for prefix in ["#", "."] {
                let query = prefix + identifier
                for separator in [" ", "\t", "\r\n", "\u{C}"] {
                    try assertQuery(doc, "main>" + query + separator + "span", [child])
                }
                try assertQuery(doc, "main>" + query + ">span", [child])
                try assertQuery(doc, "#missing, main>" + query + ">span", [child])
                try assertQuery(doc, "main>" + query + "+p", [sibling])
                try assertQuery(doc, "main>" + query + "~p", [sibling])
            }
        }
    }

    func testLiteralIdLookupDoesNotStripWhitespace() throws {
        let doc = try SwiftSoup.parse("<main><p id='x'></p><p></p></main>")
        let plain = try doc.select("p").get(0)
        let target = try doc.select("p").get(1)
        for whitespace in [" ", "\t", "\n", "\r", "\u{B}", "\u{C}", "\u{A0}"] {
            for identifier in [whitespace, whitespace + "x", "x" + whitespace] {
                try target.attr("id", identifier)
                XCTAssertTrue(try doc.getElementById(identifier) === target, identifier.debugDescription)
                XCTAssertTrue(try doc.getElementById("x") === plain)
                XCTAssertNil(try doc.getElementById(" " + identifier + " "))
                try assertQuery(doc, target.cssSelector(), [target])
            }
        }
    }

    func testEveryCssWhitespaceCombinatorBypassesTheBareIdFastPath() throws {
        for whitespace in [" ", "\t", "\n", "\r", "\u{C}"] {
            let doc = try SwiftSoup.parse("<main id='parent'><span></span></main><p></p>")
            let child = try doc.select("span").get(0)
            let distractor = try doc.select("p").get(0)
            try distractor.attr("id", "parent" + whitespace + "span")
            try assertQuery(doc, "#parent" + whitespace + "span", [child])
            try assertQuery(doc, distractor.cssSelector(), [distractor])
        }
    }

    func testParsedClassTokensUseTheSameWhitespaceRulesAsMutatedAttributes() throws {
        for whitespace in [" ", "\t", "\n", "\r", "\u{C}"] {
            let identifier = "a\u{B}x"
            let doc = try SwiftSoup.parse("<p class='" + whitespace + identifier + whitespace + "y" + whitespace + "'></p>")
            let target = try doc.select("p").get(0)
            XCTAssertEqual(Array(try target.classNamesUTF8()), [Array(identifier.utf8), Array("y".utf8)])
            XCTAssertTrue(try doc.getElementsByClass(identifier).first() === target)
            XCTAssertTrue(try doc.getElementsByClass("y").first() === target)
            XCTAssertTrue(try doc.getElementsByClass("a").isEmpty())
            try assertQuery(doc, #".a\b x"#, [target])
            XCTAssertTrue(target.hasClass(identifier))
            XCTAssertFalse(target.hasClass("a"))
        }
    }

}
