import XCTest
@testable import SwiftSoup

private final class PositionProjectedElements: Elements {
    var view: [Element] = []
    var arrayReads = 0
    override func array() -> [Element] {
        arrayReads += 1
        return view
    }
}

private final class PositionProjectedParent: Element {
    let projection = PositionProjectedElements()
    var childrenReads = 0
    override func children() -> Elements {
        childrenReads += 1
        return projection
    }
}

private final class PositionParentProbe: Element {
    var responses: [Element?] = []
    var parentReads = 0
    override func parent() -> Element? {
        let i = min(parentReads, max(0, responses.count - 1))
        parentReads += 1
        return responses.isEmpty ? nil : responses[i]
    }
}

final class ElementSiblingPositionTest: XCTestCase {
    private func check(_ parent: Element, file: StaticString = #filePath, line: UInt = #line) throws {
        // Independent reference: the public filtered view, not siblingIndex.
        let expected = parent.children().array()
        for (index, element) in expected.enumerated() {
            XCTAssertEqual(try element.elementSiblingIndex(), index, file: file, line: line)
        }
    }

    func testMixedNodePositionsAcrossWidths() throws {
        for width in [0, 1, 2, 3, 8, 32, 64, 255] {
            let parent = try Element(Tag.valueOf("main"), "")
            for i in 0..<width {
                try parent.appendChild(TextNode("text\(i)", ""))
                try parent.appendChild(Comment(Array("comment".utf8), []))
                try parent.appendChild(Element(Tag.valueOf(i % 2 == 0 ? "p" : "span"), ""))
            }
            try parent.appendChild(TextNode("tail", ""))
            try check(parent)
        }
    }

    func testStalePublicSiblingIndexDoesNotChangePosition() throws {
        let document = try SwiftSoup.parse("<main>text<p>a</p><!--gap--><i>b</i>text<p>c</p></main>")
        let parent = try XCTUnwrap(document.select("main").first())
        for element in parent.children() {
            let original = element.siblingIndex
            for stale in [Int.min, -1, 0, 1, 99, Int.max] {
                element.setSiblingIndex(stale)
                try check(parent)
            }
            element.setSiblingIndex(original)
        }
    }

    func testDetachedAndMissingMembershipKeepZero() throws {
        let element = try Element(Tag.valueOf("i"), "")
        XCTAssertEqual(try element.elementSiblingIndex(), 0)
        let parent = try Element(Tag.valueOf("main"), "")
        try parent.append("<p>one</p><p>two</p>")
        element.parentNode = parent
        XCTAssertEqual(try element.elementSiblingIndex(), 0)
        let raw = Node([])
        element.parentNode = raw
        XCTAssertEqual(try element.elementSiblingIndex(), 0)
        withExtendedLifetime((parent, raw)) {}
    }

    func testDocumentAndFormParents() throws {
        let document = Document("")
        try document.appendChild(Comment(Array("before".utf8), []))
        try document.appendChild(Element(Tag.valueOf("html"), ""))
        try document.appendChild(Element(Tag.valueOf("extra"), ""))
        try check(document)
        let form = try FormElement(Tag.valueOf("form"), [])
        try form.append("text<input><span>x</span><!--gap--><input>")
        try check(form)
    }

    func testCustomChildrenAndArrayProjectionAreRespected() throws {
        let parent = try PositionProjectedParent(Tag.valueOf("main"), "")
        let first = try Element(Tag.valueOf("p"), "")
        let second = try Element(Tag.valueOf("p"), "")
        try parent.appendChild(first)
        try parent.appendChild(second)
        parent.projection.view = [second, first]
        XCTAssertEqual(try first.elementSiblingIndex(), 1)
        XCTAssertEqual(try second.elementSiblingIndex(), 0)
        XCTAssertEqual(parent.childrenReads, 2)
        XCTAssertEqual(parent.projection.arrayReads, 2)
        parent.projection.view = [second]
        XCTAssertEqual(try first.elementSiblingIndex(), 0)
    }

    func testParentOverrideCallCountAndNilSecondResult() throws {
        let parent = try Element(Tag.valueOf("main"), "")
        let child = try PositionParentProbe(Tag.valueOf("p"), "")
        child.responses = [nil, parent]
        XCTAssertEqual(try child.elementSiblingIndex(), 0)
        XCTAssertEqual(child.parentReads, 1)
        child.parentReads = 0
        child.responses = [parent, nil]
        XCTAssertThrowsError(try child.elementSiblingIndex()) { error in
            guard case Exception.Error(let type, let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(type, .IllegalArgumentException)
            XCTAssertEqual(message, "Object must not be null")
        }
        XCTAssertEqual(child.parentReads, 2)
    }

    func testParentOverrideCanRedirectSecondRead() throws {
        let first = try Element(Tag.valueOf("div"), "")
        let second = try Element(Tag.valueOf("main"), "")
        let child = try PositionParentProbe(Tag.valueOf("p"), "")
        try second.appendChild(Element(Tag.valueOf("i"), ""))
        try second.appendChild(child)
        child.parentReads = 0
        child.responses = [first, second]
        XCTAssertEqual(try child.elementSiblingIndex(), 1)
        XCTAssertEqual(child.parentReads, 2)
    }

    func testMutationAndDeepCopyPositions() throws {
        let document = try SwiftSoup.parse("<main><p>a</p>t<p>b</p><!--c--><p>c</p></main><aside><b>d</b></aside>")
        let main = try XCTUnwrap(document.select("main").first())
        let aside = try XCTUnwrap(document.select("aside").first())
        for iteration in 0..<96 {
            if iteration % 3 == 0, let last = main.children().last() {
                try main.prependChild(last)
            } else if iteration % 3 == 1 {
                try main.appendChild(Element(Tag.valueOf("em"), ""))
            } else if let first = main.children().first() {
                try aside.appendChild(first)
            }
            try check(main)
            try check(aside)
        }
        let copy = document.copy() as! Document
        for parent in try copy.select("main, aside") { try check(parent) }
    }

    func testPositionalSelectorsBeforeAndAfterMutation() throws {
        let document = try SwiftSoup.parse("<main>t<p>A</p><!--gap--><p>B</p><span>C</span>t<p>D</p></main>")
        let root = try XCTUnwrap(document.select("main").first())
        for _ in 0..<8 {
            let children = root.children().array()
            for (query, predicate) in [
                (":first-child", { (i: Int) in i == 0 }),
                (":nth-child(2n)", { (i: Int) in (i + 1) % 2 == 0 }),
                (":nth-last-child(2)", { (i: Int) in i == children.count - 2 })
            ] {
                let expected = children.enumerated().filter { predicate($0.offset) }.map(\.element)
                for _ in 0..<3 {
                    let actual = try root.select(query).array().filter { $0 !== root }
                    XCTAssertEqual(actual.map(ObjectIdentifier.init), expected.map(ObjectIdentifier.init))
                }
            }
            try root.prependChild(children.last!)
        }
    }
}
