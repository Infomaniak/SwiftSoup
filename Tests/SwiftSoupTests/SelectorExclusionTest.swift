import XCTest
@testable import SwiftSoup

final class SelectorExclusionTest: XCTestCase {
    private func nodes(_ count: Int) throws -> [Element] {
        try (0..<count).map { _ in try Element(Tag.valueOf("p"), "") }
    }

    private func assertSame(_ actual: [Element], _ expected: [Element],
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.map(ObjectIdentifier.init), expected.map(ObjectIdentifier.init), file: file, line: line)
    }

    private func check(_ input: [Element], _ excluded: [Element],
                       file: StaticString = #filePath, line: UInt = #line) {
        // Independent reference: compare identities, never use a Set or selector cache.
        let expected = input.filter { element in !excluded.contains { $0 === element } }
        assertSame(CssSelector.filterOut(input, excluded).array(), expected, file: file, line: line)
    }

    func testEmptySmallAndThresholdBoundaries() throws {
        let pool = try nodes(160)
        for n in [0, 1, 8, 32, 63, 64, 65, 128] {
            for m in [0, 1, 8, 32, 63, 64, 65, 128] {
                check(Array(pool.prefix(n)), Array(pool.suffix(m)))
                check(Array(pool.prefix(n)), Array(pool.prefix(m)))
            }
        }
    }

    func testDuplicateReferencesRemainInInputOrder() throws {
        let pool = try nodes(96)
        let input = (0..<512).map { pool[($0 * 13) % pool.count] }
        let excluded = (0..<256).map { pool[($0 * 2) % pool.count] }
        let result = CssSelector.filterOut(input, excluded).array()
        assertSame(result, input.filter { element in !excluded.contains { $0 === element } })
        XCTAssertGreaterThan(result.count, Set(result.map(ObjectIdentifier.init)).count)
    }

    func testStructurallyEqualNodesAndClonesAreNotExcluded() throws {
        let document = try SwiftSoup.parse("<main>" + String(repeating: "<p>日本語</p>", count: 80) + "</main>")
        let input = try document.select("p").array()
        let clones = input.map { $0.copy() as! Element }
        assertSame(CssSelector.filterOut(input, clones).array(), input)
        check(input + clones, Array(input.reversed()))
    }

    func testSeededExclusionsMatchIndependentReference() throws {
        let pool = try nodes(192)
        var state: UInt64 = 0x9e37_2026
        func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(n))
        }
        for _ in 0..<512 {
            let input = (0..<next(320)).map { _ in pool[next(pool.count)] }
            let excluded = (0..<next(320)).map { _ in pool[next(pool.count)] }
            check(input, excluded)
        }
    }

    func testResultIsIndependentAndDoesNotRetainExcludedNodes() throws {
        let input = try nodes(128)
        weak var excludedNode: Element?
        var result: Elements?
        do {
            let excluded = try nodes(128)
            excludedNode = excluded.first
            result = CssSelector.filterOut(input, excluded)
        }
        XCTAssertNil(excludedNode)
        result!.add(input[0])
        XCTAssertEqual(input.count, 128)
        XCTAssertEqual(result!.count, 129)
        assertSame(CssSelector.filterOut(input, []).array(), input)
    }

    func testPublicStringAndEvaluatorPathsWithOverlappingRoots() throws {
        let document = try SwiftSoup.parse("<main>" + (0..<96).map { i in
            "<section class='\(i % 3 == 0 ? "drop" : "keep")'><p class='drop'>日本語 \(i)</p><span>text</span></section>"
        }.joined() + "</main>")
        let sections = try document.select("section").array()
        let paragraphs = try document.select("p").array()
        let input = sections + paragraphs + sections.reversed()
        let before = try document.outerHtml()
        let expected = input.filter { element in paragraphs.contains { $0 === element } == false && sections.enumerated().contains { $0.offset % 3 == 0 && $0.element === element } == false }
        let list = Elements(input)
        assertSame(try list.not(".drop").array(), expected)
        assertSame(try list.not(Evaluator.Class("drop")).array(), expected)
        assertSame(list.array(), input)
        XCTAssertEqual(try document.outerHtml(), before)
    }

    func testWarmedSelectionsAfterClassChangesReparentingAndRemoval() throws {
        let document = try SwiftSoup.parse("<main>" + (0..<128).map { i in
            "<p class='\(i % 2 == 0 ? "drop" : "keep")'>\(i)</p>"
        }.joined() + "</main>")
        let input = try document.select("p").array()
        let list = Elements(input + input)
        for round in 0..<16 {
            let element = input[round]
            try element.attr("class", round % 2 == 0 ? "keep" : "drop")
            if round % 3 == 0 { try element.remove() }
            if round % 4 == 0 { try document.body()!.appendChild(element) }
            let expected = list.array().filter { !$0.hasClass("drop") }
            for _ in 0..<3 { assertSame(try list.not(".drop").array(), expected) }
        }
    }

    func testErrorsAndCustomEqualsRemainUnchanged() throws {
        final class EqualLookingElement: Element {
            override func equals(_ other: Node) -> Bool { true }
        }
        let input = try (0..<80).map { _ in try EqualLookingElement(Tag.valueOf("p"), "") as Element }
        let other = try (0..<80).map { _ in try EqualLookingElement(Tag.valueOf("p"), "") as Element }
        assertSame(CssSelector.filterOut(input, other).array(), input)
        check(input, input)
        XCTAssertThrowsError(try Elements(input).not("["))
        enum Failure: Error { case expected }
        final class Throwing: Evaluator, @unchecked Sendable {
            override func matches(_ root: Element, _ element: Element) throws -> Bool { throw Failure.expected }
        }
        XCTAssertThrowsError(try Elements(input).not(Throwing()))
    }
}
