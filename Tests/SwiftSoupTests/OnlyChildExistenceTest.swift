import XCTest
@testable import SwiftSoup

private final class OnlyChildTrace {
    var events: [String] = []
}

private final class OnlyChildProjectedElements: Elements {
    let trace: OnlyChildTrace
    var view: [Element] = []
    init(_ trace: OnlyChildTrace) { self.trace = trace; super.init() }
    override func array() -> [Element] {
        trace.events.append("array")
        return view
    }
}

private final class OnlyChildProjectedParent: Element {
    var projection: OnlyChildProjectedElements!
    override func children() -> Elements {
        projection.trace.events.append("children")
        return projection
    }
}

private final class OnlyChildParentProbe: Element {
    let trace = OnlyChildTrace()
    var responses: [Element?] = []
    var reads = 0
    override func parent() -> Element? {
        trace.events.append("parent:\(reads)")
        let index = min(reads, max(0, responses.count - 1))
        reads += 1
        return responses.isEmpty ? nil : responses[index]
    }
}

final class OnlyChildExistenceTest: XCTestCase {
    private let evaluator = Evaluator.IsOnlyChild()
    private func make(_ tag: String = "section") throws -> Element {
        try Element(Tag.valueOf(tag), "")
    }

    func testMixedSiblingsAgainstIndependentMembershipModel() throws {
        for width in [0, 1, 2, 3, 8, 32, 64, 257] {
            for mixed in [false, true] {
                let parent = try make()
                var elements: [Element] = []
                for i in 0..<width {
                    if mixed {
                        try parent.appendChild(TextNode("日\(i)", ""))
                        try parent.appendChild(Comment([120], []))
                        try parent.appendChild(DataNode([100], []))
                    }
                    let child = try make(i.isMultiple(of: 2) ? "p" : "em")
                    try parent.appendChild(child)
                    elements.append(child)
                }
                for child in elements {
                    XCTAssertEqual(try evaluator.matches(parent, child), elements.count == 1)
                }
            }
        }
    }

    func testDetachedDocumentAndFormPoliciesAreUnchanged() throws {
        let detached = try make()
        XCTAssertFalse(try evaluator.matches(detached, detached))
        let document = Document("")
        try document.appendChild(detached)
        XCTAssertFalse(try evaluator.matches(document, detached))
        let form = try FormElement(Tag.valueOf("form"), [])
        try form.appendChild(detached)
        XCTAssertTrue(try evaluator.matches(form, detached))
        // Matching the supplied root is permitted when it has an ordinary parent.
        XCTAssertTrue(try evaluator.matches(detached, detached))
        try form.appendChild(make("input"))
        XCTAssertFalse(try evaluator.matches(form, detached))
    }

    func testProjectedChildrenAndArrayAndDuplicateSelfArePreserved() throws {
        let trace = OnlyChildTrace()
        let parent = try OnlyChildProjectedParent(Tag.valueOf("main"), "")
        parent.projection = OnlyChildProjectedElements(trace)
        let child = try make("p"), other = try make("p")
        try parent.appendChild(child)
        try parent.appendChild(other)
        for (view, expected) in [([], true), ([child], true),
                                 ([child, child], true), ([other], false),
                                 ([other, child], false)] {
            parent.projection.view = view
            trace.events = []
            XCTAssertEqual(try evaluator.matches(parent, child), expected)
            XCTAssertEqual(trace.events, ["children", "array"])
        }
    }

    func testStatefulParentDispatchAndStoredParentGateArePreserved() throws {
        let one = try make(), many = try make()
        try many.appendChild(make())
        let child = try OnlyChildParentProbe(Tag.valueOf("p"), "")
        // A projected parent without a stored owner still produces an empty
        // siblingElements() result, regardless of that projected parent's children.
        child.responses = [many]
        XCTAssertTrue(try evaluator.matches(one, child))
        XCTAssertEqual(child.reads, 1)
        try one.appendChild(child)
        for (responses, expected, reads) in [
            ([one, many] as [Element?], false, 2),
            ([many, one], true, 2),
            ([one, nil], true, 2),
            ([nil, many], false, 1),
            ([Document(""), one], false, 1)
        ] {
            child.responses = responses
            child.reads = 0
            child.trace.events = []
            XCTAssertEqual(try evaluator.matches(one, child), expected)
            XCTAssertEqual(child.reads, reads)
            XCTAssertEqual(child.trace.events, (0..<reads).map { "parent:\($0)" })
        }
    }

    func testStaleIndicesAndMissingMembershipRemainIdentityBased() throws {
        let parent = try make(), child = try make()
        try parent.appendChild(child)
        for stale in [Int.min, -1, 0, 9, Int.max] {
            child.setSiblingIndex(stale)
            XCTAssertTrue(try evaluator.matches(parent, child))
        }
        child.setSiblingIndex(0)
        let absent = try make()
        absent.parentNode = parent
        XCTAssertFalse(try evaluator.matches(parent, absent))
        parent.empty()
        XCTAssertTrue(try evaluator.matches(parent, absent))
        absent.parentNode = nil
    }

    func testSeededMutationAndWarmedPublicQueries() throws {
        let document = try SwiftSoup.parse("<main><section><p>日</p></section><aside></aside></main>")
        let root = try XCTUnwrap(document.select("main").first())
        let left = try XCTUnwrap(document.select("section").first())
        let right = try XCTUnwrap(document.select("aside").first())
        for i in 0..<128 {
            let parents = [left, right]
            let target = parents[i % 2]
            if i % 5 == 0 { target.empty() }
            else if i % 3 == 0, let child = parents[1-i%2].children().last() {
                try target.appendChild(child)
            } else { try target.appendChild(make(i % 2 == 0 ? "p" : "em")) }
            // Independent structural oracle, not siblingElements() or this evaluator.
            var expected: [Element] = []
            for parent in [root, left, right] {
                let children = parent.getChildNodes().compactMap { $0 as? Element }
                if children.count == 1 { expected.append(children[0]) }
            }
            let expectedIDs = Set(expected.map(ObjectIdentifier.init))
            for _ in 0..<3 {
                let actual = try root.select(":only-child").array()
                XCTAssertEqual(Set(actual.filter { $0 !== root }.map(ObjectIdentifier.init)), expectedIDs)
                for parent in [left, right] {
                    let children = parent.getChildNodes().compactMap { $0 as? Element }
                    for child in children {
                        XCTAssertEqual(try evaluator.matches(root, child), children.count == 1)
                    }
                }
            }
        }
    }

    func testDeepCopiesAndReadsDoNotMutateSource() throws {
        let document = try SwiftSoup.parse("<main><section>t<p>日</p><!--c--></section><aside><i>a</i><b>b</b></aside></main>")
        let copy = document.copy() as! Document
        for doc in [document, copy] {
            let before = try doc.outerHtml().utf8.map { $0 }
            let all = try doc.select("*").array()
            for _ in 0..<16 {
                for element in all { _ = try evaluator.matches(doc, element) }
            }
            XCTAssertEqual(try doc.outerHtml().utf8.map { $0 }, before)
        }
    }
}
