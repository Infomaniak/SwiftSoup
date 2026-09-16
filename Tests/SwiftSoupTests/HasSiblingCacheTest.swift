import XCTest
@testable import SwiftSoup

final class HasSiblingCacheTest: XCTestCase {
    func testSubtreeResultsTrackAttributesOutsideTheSelectionRoot() throws {
        let doc = try SwiftSoup.parse("<main><section id='a'></section><section id='b'><i></i></section></main>")
        let a = try XCTUnwrap(doc.getElementById("a"))
        let b = try XCTUnwrap(doc.getElementById("b"))
        let i = try XCTUnwrap(b.select("i").first())
        for query in ["section:has(+ .hit)", "section:has(+ section > .hit)"] {
            try b.removeAttr("class")
            try i.removeAttr("class")
            for _ in 0..<3 { XCTAssertTrue(try a.select(query).isEmpty(), query) }
            try b.addClass("hit")
            try i.addClass("hit")
            XCTAssertEqual(try a.select(query).array().map { $0.id() }, ["a"], query)
            try b.removeClass("hit")
            try i.removeClass("hit")
            XCTAssertTrue(try a.select(query).isEmpty(), query)
        }
    }

    func testSiblingMutationInvalidatesNestedHasAndNot() throws {
        let doc = try SwiftSoup.parse("<main><section id='a'><b></b></section><section id='b'></section></main>")
        let a = try XCTUnwrap(doc.getElementById("a"))
        let b = try XCTUnwrap(doc.getElementById("b"))
        let query = "section:not(:has(~ .hit))"
        for _ in 0..<3 { XCTAssertEqual(try a.select(query).size(), 1) }
        try b.addClass("hit")
        XCTAssertTrue(try a.select(query).isEmpty())
        try b.removeClass("hit")
        XCTAssertEqual(try a.select(query).size(), 1)
    }
}
