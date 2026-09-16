import XCTest
@testable import SwiftSoup

final class CssCollectorRefinementTest: XCTestCase {
    private func assertQuery(_ doc: Document, _ query: String, _ expected: [String],
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let evaluator = try QueryParser.parse(query)
        let scanned = try doc.getAllElements().array().filter { try evaluator.matches(doc, $0) }.map { $0.id() }
        XCTAssertEqual(scanned, expected, "scan: \(query)", file: file, line: line)
        XCTAssertEqual(try Collector.collect(evaluator, doc).array().map { $0.id() }, expected,
                       "collector: \(query)", file: file, line: line)
        for _ in 0..<4 {
            XCTAssertEqual(try doc.select(query).array().map { $0.id() }, expected,
                           "public: \(query)", file: file, line: line)
        }
    }

    func testAttributePresenceSeedRetainsValuePredicates() throws {
        let doc = try SwiftSoup.parse("<main><p id='hit' data-value='prefix-middle-suffix'></p><p id='miss' data-value='other'></p><p id='missing'></p></main>")
        for selector in ["[data-value^=prefix]", "[data-value$=suffix]", "[data-value*=middle]"] {
            for suffix in [":not(#absent)", #":not(#\61 bsent)"#, "[id]"] {
                try assertQuery(doc, selector + suffix, ["hit"])
            }
        }
    }

    func testAttributePresenceSeedRetainsRegexPredicate() throws {
        let doc = try SwiftSoup.parse("<main><p id='hit' data-value='item42'></p><p id='miss' data-value='other'></p><p id='missing'></p></main>")
        for suffix in [":not(#absent)", #":not(#\61 bsent)"#, "[id]"] {
            try assertQuery(doc, #"[data-value~=^item\d+$]"# + suffix, ["hit"])
        }
    }

    func testBareIdPunctuationUsesTheSameParserAsCompoundQueries() throws {
        for id in ["x]", "x(", "x)", "x'", "x\"", "x/", "x=", "x$", "x@", "x!", "x;", "x\u{B}"] {
            let doc = try SwiftSoup.parse("<p></p>")
            let target = try XCTUnwrap(doc.select("p").first())
            try target.attr("id", id)
            XCTAssertThrowsError(try QueryParser.parse("#" + id), id.debugDescription)
            XCTAssertThrowsError(try doc.select("#" + id), id.debugDescription)
            XCTAssertThrowsError(try CssSelector.select("#" + id, [doc, target]), id.debugDescription)
            XCTAssertTrue(try doc.select(target.cssSelector()).first() === target)
        }
    }

    func testSinglePredicateAndRetainsItsAttributeValueCheck() throws {
        let doc = try SwiftSoup.parse("<p id='hit' class='present' data-value='item42'></p><p id='miss' data-value='other'></p><p id='missing'></p>")
        for query in ["[data-value^=item]", "[data-value$=42]", "[data-value*=tem4]", #"[data-value~=^item\d+$]"#] {
            let predicate = try QueryParser.parse(query)
            let combined = CombiningEvaluator.And([predicate])
            XCTAssertEqual(try Collector.collect(combined, doc).array().map { $0.id() }, ["hit"], query)
        }
        for query in ["#hit", ".present", "[data-value]", "[data-value=item42]", "p"] {
            let predicate = try QueryParser.parse(query)
            let scanned = try doc.getAllElements().array().filter { try predicate.matches(doc, $0) }.map(ObjectIdentifier.init)
            XCTAssertEqual(try Collector.collect(CombiningEvaluator.And([predicate]), doc).array().map(ObjectIdentifier.init), scanned, query)
        }
    }

    func testAttributePresenceSeedDoesNotHideVirtualAbsoluteAttributes() throws {
        let doc = try SwiftSoup.parse("<a id='hit' href='/item42'></a><a id='miss' href='/other'></a><a id='missing'></a>", "https://example.com")
        for query in ["[abs:href^=https://example.com/item]", "[abs:href$=42]", "[abs:href*=item]", #"[abs:href~=item\d+$]"#] {
            try assertQuery(doc, query, ["hit"])
            try assertQuery(doc, query + ":not(#absent)", ["hit"])
            let predicate = try QueryParser.parse(query)
            XCTAssertEqual(try Collector.collect(CombiningEvaluator.And([predicate]), doc).array().map { $0.id() }, ["hit"], query)
        }
    }

    func testAttributePresenceSeedTracksMutationsAfterCachePromotion() throws {
        let doc = try SwiftSoup.parse("<p id='first' data-value='item42'></p><p id='second' data-value='other'></p><p id='missing'></p>")
        let first = try XCTUnwrap(doc.getElementById("first"))
        let second = try XCTUnwrap(doc.getElementById("second"))
        let queries = ["[data-value^=item]:not(#absent)", #"[data-value~=^item\d+$]:not(#\61 bsent)"#]
        for query in queries { try assertQuery(doc, query, ["first"]) }
        try first.attr("data-value", "other")
        try second.attr("data-value", "item99")
        for query in queries { try assertQuery(doc, query, ["second"]) }
        try second.removeAttr("data-value")
        for query in queries { try assertQuery(doc, query, []) }
    }

    func testAttributeNegationRetainsElementsWithoutTheAttribute() throws {
        let doc = try SwiftSoup.parse("<main><p id='hit' data-value='item42'></p><p id='miss' data-value='other'></p><p id='missing'></p></main>")
        try assertQuery(doc, "p[data-value!=item42]", ["miss", "missing"])
        try assertQuery(doc, "p:not([data-value^=item]:not(#absent))", ["miss", "missing"])
        try assertQuery(doc, "main:has([data-value^=item]:not(#hit))", [])
    }

    func testAttributePresenceSeedRespectsEachRootAndDeduplicatesOverlaps() throws {
        let doc = try SwiftSoup.parse("<main><section id='left'><p id='a' data-value='item42'></p><p id='b' data-value='other'></p></section><section id='right'><p id='c' data-value='item99'></p></section></main>")
        let left = try XCTUnwrap(doc.getElementById("left"))
        let right = try XCTUnwrap(doc.getElementById("right"))
        for query in ["[data-value^=item]:not(#absent)", #"[data-value~=^item\d+$]:not(#\61 bsent)"#] {
            for _ in 0..<4 {
                XCTAssertEqual(try left.select(query).array().map { $0.id() }, ["a"])
                XCTAssertEqual(try right.select(query).array().map { $0.id() }, ["c"])
                XCTAssertEqual(try CssSelector.select(query, [left, right, left]).array().map { $0.id() }, ["a", "c"])
                XCTAssertEqual(try CssSelector.select(query, [doc, left]).array().map { $0.id() }, ["a", "c"])
            }
        }
    }


    func testVirtualAttributePresenceUsesResolvedUrlsAndTracksBaseChanges() throws {
        let doc = try SwiftSoup.parse("<a id='hit' href='/item42'></a><a id='absolute' href='https://example.com/other'></a><a id='missing'></a>")
        try assertQuery(doc, "[abs:href]", ["absolute"])
        XCTAssertEqual(doc.getElementsByAttributeNormalized(Array("abs:href".utf8)).array().map { $0.id() }, ["absolute"])
        try doc.setBaseUri("https://example.com")
        for query in ["[abs:href]", "[abs:href]:not(#absent)", "[abs:href^=https][abs:href]"] {
            try assertQuery(doc, query, ["hit", "absolute"])
        }
        try assertQuery(doc, "[abs:href]:not(#absolute)", ["hit"])
        XCTAssertEqual(try doc.getElementsByAttribute("abs:href").array().map { $0.id() }, ["hit", "absolute"])
        try doc.setBaseUri("")
        try assertQuery(doc, "[abs:href]", ["absolute"])
    }


    func testSubtreeBaseUriChangesInvalidateAncestorAndDescendantResults() throws {
        let doc = try SwiftSoup.parse("<main><section id='left'><div><a id='a' href='/item42'></a></div></section><section id='right'><a id='b' href='/other'></a></section></main>", "https://old.example")
        let left = try XCTUnwrap(doc.getElementById("left"))
        let inner = try XCTUnwrap(left.select("div").first())
        let newQuery = "[abs:href^=https://new.example]"
        let oldQuery = "[abs:href^=https://old.example]"
        for _ in 0..<4 {
            try assertQuery(doc, newQuery, [])
            try assertQuery(doc, oldQuery, ["a", "b"])
            XCTAssertTrue(try left.select(newQuery).isEmpty())
            XCTAssertTrue(try inner.select(newQuery).isEmpty())
        }
        _ = doc.getElementsByAttributeNormalized(Array("href".utf8))
        XCTAssertFalse(doc.isAttributeQueryIndexDirty)
        let textVersion = doc.textMutationVersionToken()
        try left.setBaseUri(Array("https://new.example".utf8))
        XCTAssertFalse(doc.isAttributeQueryIndexDirty)
        XCTAssertEqual(doc.textMutationVersionToken(), textVersion)
        try assertQuery(doc, newQuery, ["a"])
        try assertQuery(doc, oldQuery, ["b"])
        try assertQuery(doc, "section:has(" + newQuery + ")", ["left"])
        for _ in 0..<4 {
            XCTAssertEqual(try left.select(newQuery).array().map { $0.id() }, ["a"])
            XCTAssertEqual(try inner.select(newQuery).array().map { $0.id() }, ["a"])
            XCTAssertTrue(try inner.select(oldQuery).isEmpty())
        }
    }

}
