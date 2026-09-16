import XCTest
@testable import SwiftSoup

final class RelativeHasParserTest: XCTestCase {
    func testMixedRelativeSelectorListParsesEachBranchIndependently() throws {
        let doc = try SwiftSoup.parse("""
            <main>
              <section id='first'><b></b></section>
              <section id='second'><i class='hit'></i></section>
              <section id='third'><p></p></section>
            </main>
            """)

        XCTAssertEqual(
            try doc.select("section:has(> p, + section > i.hit)").array().map { $0.id() },
            ["first", "third"]
        )
        XCTAssertEqual(
            try doc.select("section:has(~ section > p, > b)").array().map { $0.id() },
            ["first", "second"]
        )
    }

    func testHasListSplitterPreservesNestedAndEscapedCommas() throws {
        let doc = try SwiftSoup.parse("""
            <main id='nested'>
              <p class='a,b' data-note='x,y'>x,y</p>
            </main>
            """)

        let selectors = [
            #"main:has(> p.a\,b, + aside)"#,
            #"main:has(> p.\61 \2c b, + aside)"#,
            #"main:has(> p[data-note='x,y'], + aside)"#,
            #"main:has(> p:contains(x,y), + aside)"#,
            #"main:has(> p:not(.missing, aside), + aside)"#
        ]
        for selector in selectors {
            XCTAssertEqual(try doc.select(selector).array().map { $0.id() }, ["nested"], selector)
        }
    }

    func testHasRejectsEmptySelectorListBranches() throws {
        for selector in ["main:has(, > p)", "main:has(> p, )", "main:has(> p,, i)"] {
            XCTAssertThrowsError(try QueryParser.parse(selector), selector)
        }
    }
}
