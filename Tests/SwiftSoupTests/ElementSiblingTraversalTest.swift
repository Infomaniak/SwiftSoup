import XCTest
@testable import SwiftSoup

private final class ReorderedChildrenElement: Element {
    override func children() -> Elements {
        return Elements(Array(super.children().array().reversed()))
    }
}

private final class RedirectedParentElement: Element {
    weak var visibleParent: Element?
    override func parent() -> Element? { visibleParent }
}

final class ElementSiblingTraversalTest: XCTestCase {
    private func assertSiblings(_ parent: Element, file: StaticString = #filePath, line: UInt = #line) throws {
        let elements = parent.children().array()
        for (index, element) in elements.enumerated() {
            let previous = try element.previousElementSibling()
            let next = try element.nextElementSibling()
            if index == 0 { XCTAssertNil(previous, file: file, line: line) }
            else { XCTAssertTrue(previous === elements[index - 1], file: file, line: line) }
            if index + 1 == elements.count { XCTAssertNil(next, file: file, line: line) }
            else { XCTAssertTrue(next === elements[index + 1], file: file, line: line) }
        }
    }

    func testMixedNodesBothDirectionsAndDetachedElement() throws {
        let doc = try SwiftSoup.parse("<main>start<!--before--><p>one</p>between<!--gap--><span>two</span>text<p>three</p><!--end-->last</main>")
        let root = try XCTUnwrap(doc.getElementsByTag("main").first())
        try assertSiblings(root)
        let detached = try XCTUnwrap(root.children().first())
        try detached.remove()
        XCTAssertNil(try detached.previousElementSibling())
        XCTAssertNil(try detached.nextElementSibling())
        try assertSiblings(root)
    }

    func testPubliclyChangedSiblingIndexFallsBackToIdentitySearch() throws {
        let doc = try SwiftSoup.parse("<main>text<p>a</p><!--gap--><span>b</span><p>c</p>tail</main>")
        let root = try XCTUnwrap(doc.getElementsByTag("main").first())
        for element in root.children() {
            let realIndex = element.siblingIndex
            for stale in [Int.min, -1, 0, 1, 2, Int.max] {
                element.setSiblingIndex(stale)
                try assertSiblings(root)
            }
            element.setSiblingIndex(realIndex)
        }
    }

    func testReorderingInsertionReplacementAndCrossParentMove() throws {
        let doc = try SwiftSoup.parse("<main><p>a</p>gap<p>b</p><!--c--><p>c</p></main><aside><span>x</span></aside>")
        let root = try XCTUnwrap(doc.getElementsByTag("main").first())
        let aside = try XCTUnwrap(doc.getElementsByTag("aside").first())
        let first = try XCTUnwrap(root.children().first())
        let last = try XCTUnwrap(root.children().last())
        try root.prependChild(last)
        try assertSiblings(root)
        try first.before("text<em>new</em><!--comment-->")
        try assertSiblings(root)
        try first.after("<strong>after</strong>")
        try assertSiblings(root)
        try aside.appendChild(first)
        try assertSiblings(root)
        try assertSiblings(aside)
        let replaced = try XCTUnwrap(root.children().first())
        try replaced.replaceWith(Element(Tag.valueOf("em"), ""))
        try assertSiblings(root)
        let clone = root.copy() as! Element
        try assertSiblings(clone)
    }

    func testAdjacentGeneralAndLastChildSelectorsSkipNonElements() throws {
        let doc = try SwiftSoup.parse("<main>t<p id='a'></p><!--gap-->t<p id='b'></p><span id='c'></span>t<p id='d'></p>tail<!--end--></main>")
        let root = try XCTUnwrap(doc.getElementsByTag("main").first())
        func ids(_ query: String) throws -> [String] {
            try Collector.collect(QueryParser.parse(query), root).map { try $0.attr("id") }
        }
        XCTAssertEqual(try ids("p + p"), ["b"])
        XCTAssertEqual(try ids("p ~ p"), ["b", "d"])
        XCTAssertEqual(try ids("span + p"), ["d"])
        XCTAssertEqual(try ids("p:last-child"), ["d"])
        XCTAssertEqual(try ids("q ~ p"), [])
    }

    func testCustomChildrenAndParentOverridesPreserveSiblingView() throws {
        let parent = try ReorderedChildrenElement(Tag.valueOf("main"), "")
        try parent.append("<p>a</p>text<span>b</span><!--gap--><em>c</em>")
        try assertSiblings(parent)

        let redirected = try RedirectedParentElement(Tag.valueOf("span"), "")
        let actualParent = try Element(Tag.valueOf("div"), "")
        try actualParent.appendChild(redirected)
        // A parent override returning nil used to throw, not silently detach.
        XCTAssertThrowsError(try redirected.nextElementSibling())
        XCTAssertThrowsError(try redirected.previousElementSibling())
        redirected.visibleParent = parent
        // The overridden parent does not contain this node.
        XCTAssertThrowsError(try redirected.nextElementSibling())
        XCTAssertThrowsError(try redirected.previousElementSibling())
        redirected.visibleParent = actualParent
        XCTAssertNil(try redirected.nextElementSibling())
        XCTAssertNil(try redirected.previousElementSibling())
    }

    func testInvalidParentOrMissingMembershipStillThrows() throws {
        let element = try Element(Tag.valueOf("span"), "")
        let rawParent = Node([])
        element.parentNode = rawParent
        try withExtendedLifetime(rawParent) {
            XCTAssertThrowsError(try element.nextElementSibling())
            XCTAssertThrowsError(try element.previousElementSibling())
        }
        let parent = try Element(Tag.valueOf("div"), "")
        element.parentNode = parent
        try withExtendedLifetime(parent) {
            XCTAssertThrowsError(try element.nextElementSibling())
            XCTAssertThrowsError(try element.previousElementSibling())
        }
        element.parentNode = nil
        XCTAssertNil(try element.nextElementSibling())
        XCTAssertNil(try element.previousElementSibling())
    }
}
