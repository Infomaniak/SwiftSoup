import XCTest
@testable import SwiftSoup

final class ParsedEvaluatorMutationTest: XCTestCase {
    override func tearDown() {
        QueryParser.cache = QueryParser.DefaultCache()
        super.tearDown()
    }

    func testEditingReturnedOrDoesNotChangeTheOriginalQuery() throws {
        QueryParser.cache = QueryParser.DefaultCache()
        let query = "p.audit-one, span.audit-one"
        let doc = try SwiftSoup.parse("<p class='audit-one'>yes</p><em>no</em>")
        let editable = try XCTUnwrap(QueryParser.parse(query) as? CombiningEvaluator.Or)
        editable.add(Evaluator.Tag("em"))
        XCTAssertEqual(try doc.select(editable).size(), 2)
        XCTAssertEqual(try doc.select(query).size(), 1)
        XCTAssertFalse(try QueryParser.parse(query).matches(doc, XCTUnwrap(doc.select("em").first())))
    }

    func testNestedMutableQueryDoesNotAlterWarmCssEvaluator() throws {
        QueryParser.cache = QueryParser.DefaultCache()
        let inner = "p.cache-inner, i.cache-inner"
        let query = "section:not(" + inner + ")"
        let doc = try SwiftSoup.parse("<section><em>no</em></section>")
        XCTAssertEqual(try doc.select(query).size(), 1)
        let editable = try XCTUnwrap(QueryParser.parse(inner) as? CombiningEvaluator.Or)
        editable.add(Evaluator.Tag("section"))
        // A fresh document avoids merely re-reading a cached result collection.
        let second = try SwiftSoup.parse("<section><em>no</em></section>")
        XCTAssertEqual(try second.select(query).size(), 1)
    }

    func testDefaultCacheSeparatesBothInsertedAndReturnedDisjunctions() throws {
        let cache = QueryParser.DefaultCache()
        let inserted = CombiningEvaluator.Or([Evaluator.Tag("p")])
        cache.set("test-cache", inserted)
        inserted.add(Evaluator.Tag("em"))
        let retrieved = try XCTUnwrap(cache.get("test-cache") as? CombiningEvaluator.Or)
        retrieved.add(Evaluator.Tag("aside"))
        let doc = try SwiftSoup.parse("<p></p><em></em><aside></aside>")
        XCTAssertEqual(try doc.select(XCTUnwrap(cache.get("test-cache"))).array().map { $0.tagName() }, ["p"])
    }

    func testCachedHasCopiesRetainChildScope() throws {
        let query = "section:has(> p, i)"
        let doc = try SwiftSoup.parse("<section id='a'></section><section id='b'><i></i></section><section id='c'><p></p></section>")
        for _ in 0..<4 {
            let evaluator = try QueryParser.parse(query)
            XCTAssertEqual(try CssSelector.select(evaluator, doc).array().map { $0.id() }, ["b", "c"])
        }
    }

    func testMutableNestedOrReturnedInsideNotIsIndependent() throws {
        QueryParser.cache = QueryParser.DefaultCache()
        let query = ":not(p.or-nested, i.or-nested)"
        let parsed = try XCTUnwrap(QueryParser.parse(query) as? StructuralEvaluator.Not)
        let nested = try XCTUnwrap(parsed.evaluator as? CombiningEvaluator.Or)
        nested.add(Evaluator.Tag("em"))
        let doc = try SwiftSoup.parse("<em>yes</em>")
        let em = try XCTUnwrap(doc.select("em").first())
        XCTAssertFalse(try parsed.matches(doc, em))
        XCTAssertTrue(try QueryParser.parse(query).matches(doc, em))
    }
}
