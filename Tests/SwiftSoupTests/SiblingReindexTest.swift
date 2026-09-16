import XCTest
@testable import SwiftSoup

final class SiblingReindexTest: XCTestCase {
    func testEveryValidSuffixWithRetainedArraySnapshot() throws {
        for count in [0, 1, 2, 15, 16, 17, 128] {
            let root = try Element(Tag.valueOf("main"), "")
            for index in 0..<count {
                try root.appendChild(index % 2 == 0 ? TextNode("text", "") : Element(Tag.valueOf("p"), ""))
            }
            let snapshot = root.getChildNodes()
            for start in 0...count {
                for child in snapshot { child.setSiblingIndex(Int.max) }
                root.reindexChildren(start)
                XCTAssertEqual(root.childNodeSize(), count)
                for index in 0..<count {
                    XCTAssertTrue(root.childNode(index) === snapshot[index])
                    XCTAssertTrue(snapshot[index].getParentNode() === root)
                    XCTAssertEqual(snapshot[index].siblingIndex, index < start ? Int.max : index)
                }
            }
            root.reindexChildren(0)
        }
    }

    func testReindexDoesNotInvalidateWarmedReadState() throws {
        let doc = try SwiftSoup.parse("<main>text<p id='a'>one</p><!--gap--><p id='b'>two</p>tail</main>")
        doc.outputSettings().prettyPrint(pretty: false)
        let root = try XCTUnwrap(doc.getElementsByTag("main").first())
        for _ in 0..<4 { _ = try doc.select("p"); _ = try doc.text() }
        let before = try doc.outerHtmlUTF8()
        let version = root.textMutationVersionToken()
        let tagsDirty = doc.isTagQueryIndexDirty
        let children = root.getChildNodes()
        for child in children { child.setSiblingIndex(100) }
        root.reindexChildren(0)
        XCTAssertEqual(try doc.outerHtmlUTF8(), before)
        XCTAssertEqual(root.textMutationVersionToken(), version)
        XCTAssertEqual(doc.isTagQueryIndexDirty, tagsDirty)
        XCTAssertEqual(try doc.select("p").array().map { try $0.attr("id") }, ["a", "b"])
        for (index, child) in children.enumerated() { XCTAssertEqual(child.siblingIndex, index) }
    }

    func testRepeatedMovesRemovalsAndInsertionsMatchReferenceOrder() throws {
        let root = try Element(Tag.valueOf("main"), "")
        let other = try Element(Tag.valueOf("aside"), "")
        var expected: [Node] = []
        for index in 0..<64 {
            let child = TextNode("\(index)", "")
            try root.appendChild(child)
            expected.append(child)
        }
        for round in 0..<80 {
            let moved = expected.removeLast()
            try root.insertChildren(0, [moved])
            expected.insert(moved, at: 0)
            if round % 3 == 0 {
                let middle = expected.remove(at: expected.count / 2)
                try other.appendChild(middle)
                try root.appendChild(middle)
                expected.append(middle)
            }
            let snapshot = root.getChildNodes()
            for (index, child) in expected.enumerated() {
                XCTAssertTrue(snapshot[index] === child)
                XCTAssertTrue(child.parent() === root)
                XCTAssertEqual(child.siblingIndex, index)
                if index > 0 { XCTAssertTrue(child.previousSibling() === expected[index - 1]) }
                if index + 1 < expected.count { XCTAssertTrue(child.nextSibling() === expected[index + 1]) }
            }
        }
    }

    func testInsertionPreservesOwnerLookupObservationOrder() throws {
        final class ObservingDocument: Document {
            var observedRoot: Element?
            var counts: [Int] = []
            override func ownerDocument() -> Document? {
                if let observedRoot { counts.append(observedRoot.childNodeSize()) }
                return self
            }
        }
        let document = ObservingDocument("")
        let root = try document.appendElement("main")
        document.observedRoot = root
        let tag = try Tag.valueOf("p")
        let children = (0..<3).map { _ in Element(tag, "") }
        document.counts.removeAll()
        try root.insertChildren(0, children)
        // Reindexing must not batch or reorder the surrounding mutation callbacks.
        XCTAssertEqual(document.counts, [1, 2, 3, 3])
        for (index, child) in children.enumerated() {
            XCTAssertEqual(child.siblingIndex, index)
            XCTAssertTrue(child.parent() === root)
        }
    }

    func testDeepCopyReindexesWithoutChangingSource() throws {
        let original = try SwiftSoup.parse("<main><p><b>one</b></p><p>two</p></main>")
        let copy = original.copy() as! Document
        let source = try XCTUnwrap(original.getElementsByTag("main").first())
        let destination = try XCTUnwrap(copy.getElementsByTag("main").first())
        try destination.insertChildren(0, [TextNode("new", "")])
        XCTAssertEqual(source.childNodeSize(), 2)
        XCTAssertEqual(destination.childNodeSize(), 3)
        XCTAssertEqual(source.childNode(1).siblingIndex, 1)
        XCTAssertEqual(destination.childNode(2).siblingIndex, 2)
        XCTAssertTrue(destination.childNode(1).childNode(0).ownerDocument() === copy)
        XCTAssertTrue(source.childNode(0).childNode(0).ownerDocument() === original)
    }
}
