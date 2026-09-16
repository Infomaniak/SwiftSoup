import XCTest
@testable import SwiftSoup

final class NthSelectorBoundaryTest: XCTestCase {
    private let variants = ["nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type"]

    private func fixture(_ mixed: Bool = false) throws -> Element {
        let tags = mixed ? ["p", "li", "li", "em", "li", "p", "li", "li", "em", "p", "li", "li"]
            : Array(repeating: "li", count: 12)
        let html = tags.enumerated().map { "text<!--gap--><\($1) id='n\($0 + 1)'>x</\($1)>" }.joined()
        let doc = try SwiftSoup.parse("<section id='root'>" + html + "</section>")
        return try XCTUnwrap(doc.select("#root").first())
    }

    private func ids(_ root: Element, _ selector: String) throws -> [String] {
        try root.select("#root > " + selector).array().map { $0.id() }
    }

    private func reject(_ query: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try QueryParser.parse(query), query, file: file, line: line) { error in
            guard case Exception.Error(type: .SelectorParseException, Message: _) = error else {
                return XCTFail("Expected SelectorParseException: \(error)", file: file, line: line)
            }
        }
    }

    func testImplicitNegativeCoefficientAcrossAllVariants() throws {
        let root = try fixture()
        for variant in variants {
            let expected = variant.contains("last") ? ["n10", "n11", "n12"] : ["n1", "n2", "n3"]
            XCTAssertEqual(try ids(root, ":\(variant)(-n+3)"), expected)
        }
    }

    func testCSSWhitespaceAroundOffsetAcrossAllVariants() throws {
        let root = try fixture()
        for variant in variants {
            let expected = try ids(root, ":\(variant)(2n+1)")
            for whitespace in [" ", "\t", "\n", "\r", "\u{000C}", "\r\n\t "] {
                XCTAssertEqual(try ids(root, ":\(variant)(\(whitespace)2n\(whitespace)+\(whitespace)1\(whitespace))"), expected)
                XCTAssertEqual(try ids(root, ":\(variant)(2n\(whitespace)-\(whitespace)1)"), expected)
            }
        }
    }

    func testOrdinarySignsKeywordsAndZeros() throws {
        let root = try fixture()
        let cases: [(String, [Int])] = [
            ("odd", [1, 3, 5, 7, 9, 11]), ("EVEN", [2, 4, 6, 8, 10, 12]),
            ("n", Array(1...12)), ("+n", Array(1...12)), ("-n", []),
            ("-n + 6", Array(1...6)), ("+3N - 2", [1, 4, 7, 10]),
            ("0n+5", [5]), ("+6", [6]), ("-0", []), ("0n", []),
            ("-0n+4", [4]), ("0002n+0001", [1, 3, 5, 7, 9, 11])
        ]
        for (arg, positions) in cases {
            XCTAssertEqual(try ids(root, ":nth-child(\(arg))"), positions.map { "n\($0)" }, arg)
        }
    }

    func testTrailingAndLeadingGarbageAreRejected() {
        for variant in variants {
            for arg in ["2n+1junk", "junk2n+1", "1.5", "1e2", "n1", "n 1", "2n+", "2n--1", "2n+-1", "--n", "n+1n", "oddjunk", "2n of li", "(2n)", "", "+", "-"] {
                reject(":\(variant)(\(arg))")
            }
        }
    }

    func testWhitespaceCannotBeDeletedIndiscriminately() {
        for arg in ["3 n", "+ 2n", "- 2n", "+ n", "- n", "+ 2", "- 2", "3n + -6", "3n - +6", "1 2", "2n + 1 2"] {
            reject(":nth-child(\(arg))")
        }
    }

    func testNonCSSWhitespaceAndUnicodeDigitsAreRejected() {
        for arg in ["٢", "２", "𝟚", "2n+٢", "٢n+1", "2n\u{000B}+1", "2n\u{00A0}+1", "\u{000B}2n", "2n\u{0085}", "\u{2003}odd", "2n+1\u{00A0}", "2n\0+1"] {
            reject(":nth-child(\(arg))")
        }
    }

    func testOutOfRangeIntegersThrowRatherThanTrapOrClamp() {
        let tooLarge = String(Int.max) + "0"
        for variant in variants {
            for arg in [tooLarge, "-" + tooLarge, tooLarge + "n", "-" + tooLarge + "n", "n+" + tooLarge, "n-" + tooLarge, String(repeating: "9", count: 4096)] {
                reject(":\(variant)(\(arg))")
            }
        }
    }

    func testMissingClosingParenthesisIsRejected() {
        for name in variants + ["eq", "lt", "gt"] {
            reject(":\(name)(2")
            reject(":\(name)(")
        }
    }

    func testIndexExtensionsPreserveUnsignedZeroBasedContract() throws {
        let root = try fixture()
        XCTAssertEqual(try ids(root, ":eq(0)"), ["n1"])
        XCTAssertEqual(try ids(root, ":eq(\t0002\r)"), ["n3"])
        XCTAssertEqual(try ids(root, ":lt(2)"), ["n1", "n2"])
        XCTAssertEqual(try ids(root, ":gt(9)"), ["n11", "n12"])
        XCTAssertEqual(try ids(root, ":eq(\(Int.max))"), [])
        XCTAssertEqual(try ids(root, ":lt(\(Int.max))"), (1...12).map { "n\($0)" })
        XCTAssertEqual(try ids(root, ":gt(\(Int.max))"), [])
    }

    func testInvalidIndexExtensionsFailNormally() {
        for name in ["eq", "lt", "gt"] {
            for arg in ["", "-1", "+1", "1.0", "1e2", "1junk", "1 2", "٢", "２", "\u{00A0}1", "1\u{000B}", String(Int.max) + "0"] {
                reject(":\(name)(\(arg))")
            }
        }
    }

    func testSupportedExtremeCoefficientsAndOffsetsAcrossAllVariants() throws {
        let root = try fixture()
        let cases: [(Int, Int, [Int])] = [
            (Int.max, 0, []), (Int.max, 1, [1]), (Int.max, Int.min, []),
            (Int.max, Int.min + 2, [1]), (Int.min, Int.max, []), (Int.min, 1, [1]),
            (Int.min + 2, Int.max, [1]), (1, Int.min, Array(1...12)),
            (2, Int.min, [2, 4, 6, 8, 10, 12]), (3, Int.min, [1, 4, 7, 10]),
            (-1, Int.max, Array(1...12)), (-2, Int.max, [1, 3, 5, 7, 9, 11]),
            (2, Int.max, []), (-2, Int.min, []), (0, Int.min, []), (0, Int.max, [])
        ]
        for variant in variants {
            for (a, b, positions) in cases {
                let query = ":\(variant)(\(a)n\(b >= 0 ? "+" : "")\(b))"
                let expected = positions.map { variant.contains("last") ? 13 - $0 : $0 }.sorted().map { "n\($0)" }
                XCTAssertEqual(try ids(root, query), expected, query)
            }
        }
    }

    func testIntegerBoundaryParsingKeepsExactSignedValues() throws {
        for value in [Int.min, Int.min + 1, -1, 0, 1, Int.max - 1, Int.max] {
            let a = try XCTUnwrap(QueryParser.parse(":nth-child(\(value)n)") as? Evaluator.CssNthEvaluator)
            XCTAssertEqual(a.a, value)
            XCTAssertEqual(a.b, 0)
            let b = try XCTUnwrap(QueryParser.parse(":nth-child(2n\(value >= 0 ? "+" : "")\(value))") as? Evaluator.CssNthEvaluator)
            XCTAssertEqual(b.a, 2)
            XCTAssertEqual(b.b, value)
        }
    }

    func testLargePositiveMultiplicationCannotOverflow() throws {
        let root = try fixture()
        let node = try XCTUnwrap(root.children().first())
        XCTAssertFalse(try Evaluator.IsNthChild(Int.max, 0).matches(root, node))
        XCTAssertFalse(try Evaluator.IsNthChild(Int.min, Int.max).matches(root, node))
    }

    func testSubtractionAndMinimumMagnitudeCannotOverflow() throws {
        let root = try fixture()
        for (index, node) in root.children().array().enumerated() {
            XCTAssertTrue(try Evaluator.IsNthChild(1, Int.min).matches(root, node))
            XCTAssertEqual(try Evaluator.IsNthChild(2, Int.min).matches(root, node), (index + 1).isMultiple(of: 2))
            XCTAssertEqual(try Evaluator.IsNthChild(Int.min, 1).matches(root, node), index == 0)
        }
    }

    func testEntireUnsignedDistanceAtMaximumPosition() throws {
        final class Position: Evaluator.CssNthEvaluator, @unchecked Sendable {
            override func calculatePosition(_ root: Element, _ element: Element) -> Int { Int.max }
        }
        let root = try fixture()
        let node = try XCTUnwrap(root.children().first())
        XCTAssertTrue(try Position(1, Int.min).matches(root, node))
        XCTAssertFalse(try Position(2, Int.min).matches(root, node))
        XCTAssertTrue(try Position(3, Int.min).matches(root, node))
        XCTAssertFalse(try Position(Int.max, Int.min).matches(root, node))
        XCTAssertTrue(try Position(Int.min, Int.max).matches(root, node))
    }

    func testMixedSiblingGeneratedEnumerationOracle() throws {
        let root = try fixture(true)
        let nodes = root.children().array()
        for variant in variants {
            for a in -5...5 {
                for b in -16...16 {
                    let expected = nodes.enumerated().compactMap { index, node -> String? in
                        let family = variant.contains("of-type") ? nodes.filter { $0.tagName() == node.tagName() } : nodes
                        let forward = variant.contains("of-type") ? family.firstIndex { $0 === node }! + 1 : index + 1
                        let position = variant.contains("last") ? family.count + 1 - forward : forward
                        // Independent enumeration: small coefficients avoid overflow;
                        // 0...64 covers every solution in this 12-position fixture.
                        return (0...64).contains { a * $0 + b == position } ? node.id() : nil
                    }
                    let suffix = b >= 0 ? "+\(b)" : "\(b)"
                    let query = ":\(variant)(\(a)n\(suffix))"
                    XCTAssertEqual(try ids(root, query), expected, query)
                }
            }
        }
    }

    func testWarmSelectionAfterMutationsUsesCurrentPositions() throws {
        let root = try fixture(true)
        for round in 0..<24 {
            for variant in variants {
                let query = ":\(variant)(-n + 3)"
                let first = try ids(root, query)
                XCTAssertEqual(try ids(root, query), first)
            }
            let first = try XCTUnwrap(root.children().first())
            try root.appendChild(first)
            try root.prependElement(round.isMultiple(of: 2) ? "li" : "p").attr("id", "added\(round)")
            let nodes = root.children().array()
            for variant in variants {
                let expected = nodes.filter { node in
                    let family = variant.contains("of-type") ? nodes.filter { $0.tagName() == node.tagName() } : nodes
                    let forward = family.firstIndex { $0 === node }! + 1
                    let position = variant.contains("last") ? family.count + 1 - forward : forward
                    return position <= 3
                }.map { $0.id() }
                XCTAssertEqual(try ids(root, ":\(variant)(-n + 3)"), expected)
            }
        }
    }

    func testEvaluatorSerializationPreservesAnBAndExtremeValues() throws {
        let root = try fixture(true)
        for a in [Int.min, -3, -1, 0, 1, 3, Int.max] {
            for b in [Int.min, -5, 0, 1, 5, Int.max] {
                let evaluators: [Evaluator.CssNthEvaluator] = [Evaluator.IsNthChild(a, b), Evaluator.IsNthLastChild(a, b), Evaluator.IsNthOfType(a, b), Evaluator.IsNthLastOfType(a, b)]
                for evaluator in evaluators {
                    let text = evaluator.toString()
                    let parsed = try XCTUnwrap(QueryParser.parse(text) as? Evaluator.CssNthEvaluator)
                    XCTAssertEqual(parsed.a, a)
                    XCTAssertEqual(parsed.b, b)
                    let expected = try root.children().array().filter { try evaluator.matches(root, $0) }.map { $0.id() }
                    XCTAssertEqual(try ids(root, text), expected, text)
                }
            }
        }
    }

    func testRejectedQueriesDoNotPoisonWarmValidQueries() throws {
        let root = try fixture()
        let query = ":nth-child(2n+1)"
        let expected = try ids(root, query)
        for _ in 0..<4 {
            reject(":nth-child(2n+1junk)")
            reject(":nth-child(2n+\(Int.max)0)")
            XCTAssertEqual(try ids(root, query), expected)
        }
    }
}
