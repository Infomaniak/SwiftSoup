import XCTest
@testable import SwiftSoup

final class SelectorCacheLifetimeTest: XCTestCase {
    private func element() throws -> Element {
        Element(try Tag.valueOf("span"), [])
    }

    func testLRUMapClearReleasesLinkedValues() throws {
        let cache = SelectorResultCache.LRUMap(capacity: 4)
        weak var first: Element?
        weak var second: Element?
        do {
            let a = try element()
            let b = try element()
            first = a
            second = b
            _ = cache.set("a", Elements([a]))
            _ = cache.set("b", Elements([b]))
        }
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        cache.clear()
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertNil(cache.get("a"))
    }

    func testLRUMapDestructionReleasesLinkedValues() throws {
        weak var first: Element?
        weak var second: Element?
        do {
            let cache = SelectorResultCache.LRUMap(capacity: 4)
            let a = try element()
            let b = try element()
            first = a
            second = b
            _ = cache.set("a", Elements([a]))
            _ = cache.set("b", Elements([b]))
            XCTAssertTrue(cache.get("a")?.first() === a)
        }
        XCTAssertNil(first)
        XCTAssertNil(second)
    }

    func testDocumentReleaseFreesCachedDescendants() throws {
        weak var document: Document?
        weak var paragraph: Element?
        weak var span: Element?
        do {
            let doc = try SwiftSoup.parse("<html><head></head><body><p>one</p><span>two</span></body></html>")
            document = doc
            paragraph = doc.body()?.child(0)
            span = doc.body()?.child(1)
            for _ in 0..<4 {
                XCTAssertEqual(try doc.select("p").size(), 1)
                XCTAssertEqual(try doc.select("span").size(), 1)
            }
        }
        XCTAssertNil(document)
        XCTAssertNil(paragraph)
        XCTAssertNil(span)
    }

    func testLRUMapOrderingAndReuseAfterClear() throws {
        let cache = SelectorResultCache.LRUMap(capacity: 2)
        let a = Elements([try element()])
        let b = Elements([try element()])
        let c = Elements([try element()])
        _ = cache.set("a", a)
        _ = cache.set("b", b)
        XCTAssertTrue(cache.get("a") === a)
        XCTAssertEqual(cache.set("c", c)?.key, "b")
        XCTAssertNil(cache.get("b"))
        XCTAssertTrue(cache.get("a") === a)
        cache.clear()
        cache.clear()
        _ = cache.set("b", b)
        _ = cache.set("c", c)
        XCTAssertEqual(cache.set("a", a)?.key, "b")
        XCTAssertTrue(cache.get("c") === c)
    }
}
