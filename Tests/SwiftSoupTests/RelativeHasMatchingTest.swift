import XCTest
@testable import SwiftSoup

final class RelativeHasMatchingTest: XCTestCase {
    private func assertPaths(_ root: Element, _ query: String, _ expected: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        for _ in 0..<3 {
            let eval = try QueryParser.parse(query)
            XCTAssertEqual(try root.select(query).array().map { $0.id() }, expected, query, file: file, line: line)
            XCTAssertEqual(try Collector.collect(eval, root).array().map { $0.id() }, expected, query, file: file, line: line)
            XCTAssertEqual(try CssSelector.select(eval, root).array().map { $0.id() }, expected, query, file: file, line: line)
        }
    }

    func testAdjacentGeneralAndChainedSiblings() throws {
        let doc = try SwiftSoup.parse("<main><p id='a'></p>text<!--gap--><aside></aside><p id='b'></p><p id='c'></p></main>")
        try assertPaths(doc, "p:has(+ p)", ["b"])
        try assertPaths(doc, "p:has(~ #b)", ["a"])
        try assertPaths(doc, "p:has(+ aside + p)", ["a"])
        try assertPaths(doc, "p:has(+ p + p)", [])
        try assertPaths(doc, "p:not(:has(~ p))", ["c"])
        let b = try XCTUnwrap(doc.getElementById("b"))
        try assertPaths(b, "p:has(+ p)", ["b"])
        try b.remove()
        try assertPaths(b, "p:has(+ p)", [])
    }

    func testSiblingDescendantsAndNestedHas() throws {
        let doc = try SwiftSoup.parse("<main><section id='a'></section><section id='b'><div><i></i></div></section><section id='c'><p></p></section></main>")
        try assertPaths(doc, "section:has(+ section i)", ["a"])
        try assertPaths(doc, "section:has(~ section > p)", ["a", "b"])
        try assertPaths(doc, "section:has(+ section:has(> div))", ["a"])
        try assertPaths(doc, "section:has(+ section > i)", [])
        try assertPaths(doc, "section:has(> p, + section > div)", ["a", "c"])
    }

    func testCacheCopiesPreserveSiblingSearchWithMutableInnerGraph() throws {
        QueryParser.cache = QueryParser.DefaultCache()
        defer { QueryParser.cache = QueryParser.DefaultCache() }
        let doc = try SwiftSoup.parse("<main><section id='a'></section><section id='b'><i></i></section></main>")
        try assertPaths(doc, "section:has(+ section:not(.absent, .missing) > i)", ["a"])
    }

    func testOrdinaryHasRetainsCurrentCandidateScope() throws {
        let doc = try SwiftSoup.parse("<div id='a'><p></p></div>")
        try assertPaths(doc, "div:has(> p)", ["a"])
        try assertPaths(doc, "div:has(body p)", [])
    }
}
