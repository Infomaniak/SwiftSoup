import XCTest
@testable import SwiftSoup

private final class ChildReadTrace {
    var events: [String] = []
}

private final class ChildReadProjection: Elements {
    let trace: ChildReadTrace
    var answer: Element
    init(_ answer: Element, _ trace: ChildReadTrace) {
        self.answer = answer
        self.trace = trace
        super.init()
    }
    override func get(_ index: Int) -> Element {
        trace.events.append("get:\(index)")
        return answer
    }
    override func array() -> [Element] {
        trace.events.append("array")
        return []
    }
}

private final class ChildReadParent: Element {
    var projection: ChildReadProjection!
    override func children() -> Elements {
        projection.trace.events.append("children")
        return projection
    }
}

private final class ChildReadNodeView: Element {
    var reads = 0
    override func getChildNodes() -> [Node] {
        reads += 1
        return []
    }
}

final class ChildIndexedReadTest: XCTestCase {
    private func make(_ tag: String = "section") throws -> Element {
        try Element(Tag.valueOf(tag), "")
    }

    private func verify(_ parent: Element, _ expected: [Element],
                        file: StaticString = #filePath, line: UInt = #line) {
        for (index, child) in expected.enumerated() {
            XCTAssertTrue(parent.child(index) === child, file: file, line: line)
        }
    }

    func testMixedNodeListsAgainstExplicitModel() throws {
        for width in [0, 1, 2, 3, 8, 32, 64, 257] {
            let parent = try make()
            var expected: [Element] = []
            for i in 0..<width {
                try parent.appendChild(TextNode("日\(i)", ""))
                try parent.appendChild(Comment("gap".utf8.map { $0 }, []))
                try parent.appendChild(DataNode(Array("data".utf8), []))
                let child = try make(i.isMultiple(of: 2) ? "p" : "em")
                expected.append(child)
                try parent.appendChild(child)
            }
            try parent.appendChild(TextNode("tail", ""))
            verify(parent, expected)
        }
    }

    func testDocumentAndFormAndDeepCopy() throws {
        let document = Document("")
        let form = try FormElement(Tag.valueOf("form"), [])
        for parent in [document as Element, form] {
            let children = try (0..<9).map { try make($0.isMultiple(of: 2) ? "input" : "p") }
            for child in children {
                try parent.appendChild(Comment([120], []))
                try parent.appendChild(child)
            }
            verify(parent, children)
            let clone = parent.copy() as! Element
            let copied = clone.children().array()
            verify(clone, copied)
            XCTAssertEqual(copied.count, children.count)
            for i in children.indices { XCTAssertFalse(copied[i] === children[i]) }
        }
    }

    func testCustomChildrenAndGetKeepExactDispatchAndInvalidIndices() throws {
        let trace = ChildReadTrace()
        let parent = try ChildReadParent(Tag.valueOf("main"), "")
        let physical = try make("p")
        let projected = try make("aside")
        try parent.appendChild(physical)
        parent.projection = ChildReadProjection(projected, trace)
        // A custom get() can define these indices: do not precondition them early.
        for index in [Int.min, -1, 0, 1, Int.max] {
            trace.events = []
            XCTAssertTrue(parent.child(index) === projected)
            XCTAssertEqual(trace.events, ["children", "get:\(index)"])
        }
        parent.projection.answer = physical
        XCTAssertTrue(parent.child(0) === physical)
    }

    func testPublicNodeViewDoesNotReplaceChildrenContract() throws {
        let parent = try ChildReadNodeView(Tag.valueOf("main"), "")
        let child = try make()
        try parent.appendChild(child)
        XCTAssertTrue(parent.child(0) === child)
        XCTAssertEqual(parent.reads, 0)
    }

    func testStaleSiblingIndexesAreNotUsed() throws {
        let parent = try make()
        let expected = try (0..<12).map { _ in try make() }
        for child in expected { try parent.appendChild(child) }
        for stale in [Int.min, -1, 0, 99, Int.max] {
            for child in expected { child.setSiblingIndex(stale) }
            verify(parent, expected)
        }
        // Restore public indexes before any later structural operation.
        for (i, child) in expected.enumerated() { child.setSiblingIndex(i) }
    }

    func testSeededMovesRemovalsAndEmpty() throws {
        let left = try make("main"), right = try make("aside")
        var lists: [[Element]] = [[], []]
        var seed: UInt64 = 0xC411D
        for i in 0..<384 {
            seed = seed &* 6364136223846793005 &+ 1
            let side = Int(seed % 2), parent = side == 0 ? left : right
            if i % 7 == 0 {
                parent.empty()
                lists[side].removeAll()
            } else if !lists[1-side].isEmpty && i % 3 == 0 {
                let child = lists[1-side].removeFirst()
                try parent.prependChild(child)
                lists[side].insert(child, at: 0)
            } else {
                let child = try make(i.isMultiple(of: 2) ? "p" : "b")
                try parent.appendChild(TextNode("t", ""))
                try parent.appendChild(child)
                lists[side].append(child)
            }
            verify(left, lists[0])
            verify(right, lists[1])
        }
    }

    func testReadsKeepSourceAndWarmedSelection() throws {
        let document = try SwiftSoup.parse("<main>x<p id='a'>日</p><!--c--><p id='b'>語</p></main>")
        let parent = try XCTUnwrap(document.select("main").first())
        let expected = parent.children().array()
        let html = try document.outerHtml().utf8.map { $0 }
        let selected = try parent.select("p").array().map(ObjectIdentifier.init)
        for _ in 0..<64 {
            verify(parent, expected)
            XCTAssertEqual(try parent.select("p").array().map(ObjectIdentifier.init), selected)
            XCTAssertEqual(try document.outerHtml().utf8.map { $0 }, html)
        }
        try parent.child(0).attr("id", "changed")
        XCTAssertTrue(try document.select("#changed").first() === expected[0])
        XCTAssertEqual(try document.select("#a").size(), 0)
    }
}
