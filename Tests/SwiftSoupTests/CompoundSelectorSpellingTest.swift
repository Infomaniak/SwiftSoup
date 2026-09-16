import XCTest
@testable import SwiftSoup

final class CompoundSelectorSpellingTest: XCTestCase {
    private let numeric = ["nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type", "eq", "lt", "gt"]

    private func fixture() throws -> Document {
        try SwiftSoup.parse("<main><ol>" + (1...6).map {
            "<li id='n\($0)' class='item' data-note='x) y]'>item \($0)</li>"
        }.joined() + "</ol><p id='after'>after</p></main>")
    }

    private func reject(_ query: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try QueryParser.parse(query), query, file: file, line: line) { error in
            guard case Exception.Error(type: .SelectorParseException, Message: _) = error else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        }
    }

    func testUnclosedNumericArgumentsAreRejectedAfterEveryCombinator() {
        for name in numeric {
            let argument = name.hasPrefix("nth") ? "2n + 1" : "1"
            for prefix in ["", "ol ", "ol > ", "p + ", "p ~ ", "p, ", "main > ol > "] {
                reject(prefix + "li:\(name)(\(argument)")
            }
        }
    }

    func testNestedPartialFunctionsCannotRepairNumericArguments() {
        for name in numeric {
            // Legacy partial :has/:not parsing may consume to EOF, but an
            // incomplete inner numeric argument must still reach its validator.
            for query in ["ol:has(> li:\(name)(1",
                          "li:not(ol > li:\(name)(1",
                          "main:has(ol:has(> li:\(name)(1"] {
                reject(query)
            }
        }
    }

    func testUnclosedNumericArgumentsThrowThroughPublicSelections() throws {
        let doc = try fixture()
        for query in ["ol > li:eq(1", "main li:nth-child(2n+1", "p, li:nth-last-child(1"] {
            XCTAssertThrowsError(try doc.select(query))
            XCTAssertThrowsError(try CssSelector.select(query, [doc]))
            XCTAssertThrowsError(try Elements([doc]).select(query))
            XCTAssertThrowsError(try Elements([doc]).not(query))
        }
    }

    func testClosedNumericArgumentsKeepIdentityAndOrder() throws {
        let doc = try fixture()
        for name in numeric {
            for arg in ["0", "1", "2", "6"] {
                let simple = "li:\(name)(\(arg))"
                let expected = try doc.select(simple).array().map(ObjectIdentifier.init)
                for prefix in ["ol ", "ol > ", "main > ol > ", "#absent, "] {
                    XCTAssertEqual(try doc.select(prefix + simple).array().map(ObjectIdentifier.init), expected)
                }
            }
        }
    }

    func testMalformedAttemptsDoNotAlterWarmResultsOrDOM() throws {
        let doc = try fixture()
        let valid = "ol > li:nth-child(-n + 3)"
        let expected = try doc.select(valid).array().map(ObjectIdentifier.init)
        let html = try doc.outerHtml()
        for _ in 0..<8 {
            XCTAssertThrowsError(try doc.select(String(valid.dropLast())))
            XCTAssertEqual(try doc.select(valid).array().map(ObjectIdentifier.init), expected)
            XCTAssertEqual(try doc.outerHtml(), html)
        }
        try doc.select("ol").first()!.prependElement("li").attr("id", "new")
        XCTAssertEqual(try doc.select(valid).array().map { $0.id() }, ["new", "n1", "n2"])
    }

    func testRawCompoundExtractionNeverInventsDelimiters() {
        for input in ["li:nth-child(2n+1", "li:eq(1", "li[data-x", "li:has(span", "li:not(.x", "li:contains(\"item", "li:matches(item\\", "li:not(:not(.x)"] {
            let queue = TokenQueue(input)
            XCTAssertEqual(Array(queue.consumeCssSubQuery().utf8), Array(input.utf8), input)
            XCTAssertTrue(queue.isEmpty())
        }
    }

    func testRawExtractionStopsAtActualCombinatorOnly() {
        for suffix in [" > p", "+p", "~p", ",p", "\t p", "\u{000C}p"] {
            let input = #"li[data-note='x) y]']:not([data-note="z)"])"#
            let queue = TokenQueue(input + suffix)
            XCTAssertEqual(Array(queue.consumeCssSubQuery().utf8), Array(input.utf8))
            XCTAssertEqual(Array(queue.remainder().utf8), Array(suffix.utf8))
        }
    }

    func testQuotedUnclosedAndEscapedTerminatorsStayByteExact() {
        for input in [#"li[title="tail]"#, #"li:contains('tail)"#,
                      #"li:contains(a\)"#, #"li:contains(a\\)"#,
                      #"li:not([data-x="a]b"]"#, #"li:matches(a\)b)"#] {
            let queue = TokenQueue(input)
            XCTAssertEqual(Array(queue.consumeCssSubQuery().utf8), Array(input.utf8), input)
            XCTAssertTrue(queue.isEmpty())
        }
    }

    func testUnicodeAroundDelimiterDoesNotDropScalars() {
        for marker in ["\u{301}", "\u{600}", "👩🏽‍💻", "日本", "\r\n"] {
            for closed in [false, true] {
                let input = "li:contains(" + marker + "text" + marker + (closed ? ")" : "")
                let suffix = closed ? " > p" : ""
                let queue = TokenQueue(input + suffix)
                XCTAssertEqual(Array(queue.consumeCssSubQuery().utf8), Array(input.utf8))
                XCTAssertEqual(Array(queue.remainder().utf8), Array(suffix.utf8))
            }
        }
    }

    func testHexEscapesRemainWholeBeforeAndWithinBalancedSyntax() {
        for input in [#".a\20 b:nth-child(2n+1"#, #".a\20 b:nth-child(2n+1)"#,
                      #"li:not(.a\29 b)"#, #"li:not(.a\29 b"#] {
            let queue = TokenQueue(input)
            XCTAssertEqual(Array(queue.consumeCssSubQuery().utf8), Array(input.utf8))
            XCTAssertTrue(queue.isEmpty())
        }
    }

    func testPublicBalancedScannerKeepsPartialResultContract() {
        for (source, expected) in [("(one(two", "one(two"), ("(one(two)", "one(two)"),
                                   ("('unterminated)", "'unterminated)"), ("(tail\\", "tail\\")] {
            let queue = TokenQueue(source)
            XCTAssertEqual(Array(queue.chompBalanced("(", ")").utf8), Array(expected.utf8))
            XCTAssertTrue(queue.isEmpty())
        }
        let open: Character = "👩‍💻", close: Character = "👨‍💻"
        let queue = TokenQueue("\(open)one\(open)two\(close)\(close)tail")
        XCTAssertEqual(queue.chompBalanced(open, close), "one\(open)two\(close)")
        XCTAssertEqual(queue.remainder(), "tail")
    }

    func testLegacyPartialNonnumericSelectorsAreNotMadeStrict() throws {
        let doc = try fixture()
        for query in ["li[data-note", "li:contains(item", "li:not(.missing", "ol:has(li"] {
            let simple = try doc.select(query).array().map(ObjectIdentifier.init)
            XCTAssertEqual(try doc.select("main " + query).array().map(ObjectIdentifier.init), simple)
        }
    }

    func testMissingOuterCloserDoesNotInvalidateClosedInnerNumericArgument() throws {
        let doc = try fixture()
        for query in ["ol:has(> li:eq(1)", "ol:has(li:nth-child(2n+1)", "li:not(:nth-child(2n+1)"] {
            let simple = try doc.select(query).array().map(ObjectIdentifier.init)
            XCTAssertEqual(try doc.select("main " + query).array().map(ObjectIdentifier.init), simple)
        }
    }

    func testPartialLiteralContentIsNotChangedByCompoundSplitting() throws {
        let doc = try SwiftSoup.parse("<main><p>\"item</p><p>\"item)</p><p>tail)</p><p>tail</p></main>")
        for expression in [#":contains("item"#, #":contains(tail\"#, #":contains(tail\)"#] {
            let simple = try doc.select("p" + expression).array().map(ObjectIdentifier.init)
            let compound = try doc.select("main > p" + expression).array().map(ObjectIdentifier.init)
            XCTAssertEqual(compound, simple, expression)
        }
    }

    func testGeneratedNestedSpellingPreservesEveryByte() {
        let atoms = ["日本", "e\u{301}", "\u{600}", "👩🏽‍💻", #"\29 "#, #""a)b]""#]
        for seed in 0..<128 {
            let depth = 1 + seed % 8
            let full = "li" + String(repeating: ":not(", count: depth) + "." + atoms[seed % atoms.count] + String(repeating: ")", count: depth)
            for removed in 0...depth {
                let input = String(full.dropLast(removed))
                let queue = TokenQueue(input)
                XCTAssertEqual(Array(queue.consumeCssSubQuery().utf8), Array(input.utf8), "seed \(seed), removed \(removed)")
                XCTAssertTrue(queue.isEmpty())
            }
        }
    }
}
