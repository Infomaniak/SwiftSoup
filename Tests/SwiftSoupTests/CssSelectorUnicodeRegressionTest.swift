import XCTest
@testable import SwiftSoup

final class CssSelectorUnicodeRegressionTest: XCTestCase {
    private func assertSelects(_ doc: Document, _ query: String, _ target: Element,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        // Warm both the parsed-query and per-root result caches, including promotion.
        for _ in 0..<4 {
            let selected = try doc.select(query)
            XCTAssertEqual(selected.size(), 1, query, file: file, line: line)
            XCTAssertTrue(selected.first() === target, query, file: file, line: line)
        }
        let evaluator = try QueryParser.parse(query)
        let collected = try Collector.collect(evaluator, doc)
        XCTAssertEqual(collected.size(), 1, query, file: file, line: line)
        XCTAssertTrue(collected.first() === target, query, file: file, line: line)
        // Collector also uses indexes. Check the predicate independently on
        // every element so an indexed-lookup bug cannot validate itself.
        let scanned = try doc.getAllElements().array().filter { try evaluator.matches(doc, $0) }
        XCTAssertEqual(scanned.count, 1, query, file: file, line: line)
        XCTAssertTrue(scanned.first === target, query, file: file, line: line)
    }

    func testParserCachePreservesDistinctUnicodeSpellings() throws {
        let originalCache = QueryParser.cache
        defer { QueryParser.cache = originalCache }
        for limit: QueryParser.CacheLimit in [.count(2), .unlimited] {
            QueryParser.cache = QueryParser.DefaultCache(limit: limit)
            for _ in 0..<3 {
                for id in ["cache-é", "cache-e\u{301}", "cache-é"] {
                    let evaluator = try XCTUnwrap(QueryParser.parse("#" + id) as? Evaluator.Id)
                    XCTAssertEqual(evaluator.idBytes, Array(id.utf8))
                }
            }
        }
    }

    func testResultCachePreservesDistinctUnicodeSpellings() throws {
        let cache = SelectorResultCache(capacity: 8)
        let doc = try SwiftSoup.parse("<p>first</p><p>second</p>")
        let targets = try doc.select("p")
        let a = SelectorResultCache.Result(elements: [targets.get(0)], includesOwner: false)
        let b = SelectorResultCache.Result(elements: [targets.get(1)], includesOwner: false)
        for _ in 0..<4 {
            cache.put("#result-é", a)
            cache.put("#result-e\u{301}", b)
            // First insertion is only admitted to the doorkeeper.
        }
        XCTAssertTrue(cache.get("#result-é")?.elements.first === targets.get(0))
        XCTAssertTrue(cache.get("#result-e\u{301}")?.elements.first === targets.get(1))
    }

    func testUnicodeIdsAcrossAllSelectionCaches() throws {
        let doc = try SwiftSoup.parse("<main><p>composed</p><p>decomposed</p></main>")
        let targets = try doc.select("p")
        let ids = ["unicode-id-é", "unicode-id-e\u{301}"]
        for i in 0..<2 { try targets.get(i).attr("id", ids[i]) }
        for prefix in ["#", "p#", "main > #", "main #"] {
            for _ in 0..<3 {
                for i in [0, 1, 0] { try assertSelects(doc, prefix + ids[i], targets.get(i)) }
            }
        }
    }

    func testUnicodeClassesAcrossAllSelectionCaches() throws {
        let doc = try SwiftSoup.parse("<main><p>composed</p><p>decomposed</p></main>")
        let targets = try doc.select("p")
        let names = ["unicode-class-é", "unicode-class-e\u{301}"]
        for i in 0..<2 { try targets.get(i).attr("class", names[i]) }
        for prefix in [".", "p.", "main > .", "main ."] {
            for _ in 0..<3 {
                for i in [1, 0, 1] { try assertSelects(doc, prefix + names[i], targets.get(i)) }
            }
        }
    }

    func testGeneratedIdentifiersPreserveMultiScalarGraphemes() throws {
        for id in ["a\u{20DD}", "b\u{20DD}", "c\u{20DD}", "d\u{20DD}", "e\u{20DD}",
                   "f\u{20DD}", "1\u{20E3}", "e\u{301}", "é", "日本", "👩‍💻", "\\\u{301}", "-", "-1", "123", "\u{301}a", "\u{20DD}", "\u{200D}", "🏽"] {
            let doc = try SwiftSoup.parse("<main><p>hit</p><p>miss</p></main>")
            let target = try XCTUnwrap(doc.select("p").first())
            try target.attr("id", id)
            let query = try target.cssSelector()
            XCTAssertEqual(Array(TokenQueue(String(decoding: query.utf8.dropFirst(), as: UTF8.self)).consumeCssIdentifier().utf8), Array(id.utf8), query)
            try assertSelects(doc, query, target)
        }
    }

    func testGeneratedIdentifiersPreserveAsciiControlsAndSpaces() throws {
        for codePoint in Array(UInt32(1)...UInt32(0x20)) + [0x7F] {
            let scalar = try XCTUnwrap(UnicodeScalar(codePoint))
            for id in ["x" + String(scalar) + "a", String(scalar) + "a", "x" + String(scalar)] {
                let doc = try SwiftSoup.parse("<main><p>hit</p><p>miss</p></main>")
                let target = try XCTUnwrap(doc.select("p").first())
                try target.attr("id", id)
                try assertSelects(doc, target.cssSelector(), target)
            }
        }
    }

    func testGeneratedClassesPreserveMultiScalarGraphemes() throws {
        for name in ["a\u{20DD}", "b\u{20DD}", "1\u{20E3}", "e\u{301}", "👩‍💻", "\\\u{301}", "\u{301}a", "\u{20DD}", "\u{200D}", "🏽"] {
            let doc = try SwiftSoup.parse("<main><p>hit</p><p>miss</p></main>")
            let target = try XCTUnwrap(doc.select("p").first())
            try target.attr("class", name)
            try assertSelects(doc, target.cssSelector(), target)
        }
    }

    func testBareHasDoesNotReuseAnOuterRootForRelativeSelectors() throws {
        let doc = try SwiftSoup.parse("<main><section><p id='leaf'></p></section></main>")
        let target = try XCTUnwrap(doc.select("section").first())
        for query in [":has(> p)", #":has(> p#\6c eaf)"#, ":has(> p):not(main)"] {
            try assertSelects(doc, query, target)
        }
        XCTAssertTrue(try doc.select("section:has(main p)").isEmpty())
    }

    func testHasChildSelectorsAreRelativeToCandidate() throws {
        let doc = try SwiftSoup.parse("<main><section id='direct'><p class='ab'></p></section><section id='nested'><div><p class='ab'></p></div></section></main>")
        let target = try XCTUnwrap(doc.getElementById("direct"))
        for query in ["section:has(> p.ab)", #"section:has(> p.\61 b)"#, #"main > section:not(:not(:has(> p.\61 b)))"#] {
            try assertSelects(doc, query, target)
        }
        XCTAssertEqual(try doc.select("section:has(p.ab)").size(), 2)
    }

    func testDecodedClassWhitespaceIsNotTrimmed() throws {
        let doc = try SwiftSoup.parse("<main><p class='ab'>plain</p><p>unicode</p></main>")
        let target = try doc.select("p").get(1)
        for (escape, scalar) in [(#"\a0 "#, "\u{A0}"), (#"\2003 "#, "\u{2003}")] {
            for (identifier, encoded) in [(scalar + "ab", escape + "ab"), ("ab" + scalar, "ab" + escape)] {
                try target.attr("class", identifier)
                for prefix in [".", "p.", "main > ."] {
                    try assertSelects(doc, prefix + encoded, target)
                }
            }
        }
        // An escaped CSS space is identifier content, not removable query padding.
        for query in [#".\20 ab"#, #".ab\20 "#, #"main > .\20 ab"#] {
            XCTAssertTrue(try doc.select(query).isEmpty(), query)
        }
    }
}
