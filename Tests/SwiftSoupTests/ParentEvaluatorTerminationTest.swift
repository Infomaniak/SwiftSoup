import XCTest
@testable import SwiftSoup

final class ParentEvaluatorTerminationTest: XCTestCase {
    private final class Recorder: Evaluator, @unchecked Sendable {
        var seen: [Element] = []
        var result: (Element) throws -> Bool = { _ in false }
        override func matches(_ root: Element, _ element: Element) throws -> Bool {
            seen.append(element)
            return try result(element)
        }
    }

    func testDetachedElementAndForeignRootTerminate() throws {
        let foreign = try Element(Tag.valueOf("aside"), "")
        let detached = try Element(Tag.valueOf("p"), "")
        let recorder = Recorder()
        XCTAssertFalse(StructuralEvaluator.Parent(recorder).matches(foreign, detached))
        XCTAssertTrue(recorder.seen.isEmpty)
    }

    func testForeignDocumentMissVisitsEachExistingAncestorOnce() throws {
        let doc = try SwiftSoup.parse("<article><section><p>x</p></section></article>")
        let leaf = try XCTUnwrap(doc.select("p").first())
        let foreign = Document("")
        let recorder = Recorder()
        XCTAssertFalse(StructuralEvaluator.Parent(recorder).matches(foreign, leaf))
        XCTAssertEqual(recorder.seen.map { $0.tagName() }, ["section", "article", "body", "html", "#root"])
    }

    func testRootStillIncludedAndAncestorsAboveItAreNotVisited() throws {
        let doc = try SwiftSoup.parse("<article><section><p>x</p></section></article>")
        let root = try XCTUnwrap(doc.select("section").first())
        let leaf = root.child(0)
        let recorder = Recorder()
        XCTAssertFalse(StructuralEvaluator.Parent(recorder).matches(root, leaf))
        XCTAssertEqual(recorder.seen.map(ObjectIdentifier.init), [ObjectIdentifier(root)])
        recorder.seen.removeAll()
        recorder.result = { $0 === root }
        XCTAssertTrue(StructuralEvaluator.Parent(recorder).matches(root, leaf))
        recorder.seen.removeAll()
        XCTAssertFalse(StructuralEvaluator.Parent(recorder).matches(root, root))
        XCTAssertTrue(recorder.seen.isEmpty)
    }

    func testForeignRootDoesNotSuppressAnExistingAncestorMatch() throws {
        let doc = try SwiftSoup.parse("<article><section><p>x</p></section></article>")
        let leaf = try XCTUnwrap(doc.select("p").first())
        let recorder = Recorder()
        recorder.result = { $0.tagName() == "article" }
        XCTAssertTrue(StructuralEvaluator.Parent(recorder).matches(Document(""), leaf))
        XCTAssertEqual(recorder.seen.map { $0.tagName() }, ["section", "article"])
    }

    func testThrowingPredicatesStillContinueAndTerminate() throws {
        enum Probe: Error { case failure }
        let doc = try SwiftSoup.parse("<section><p>x</p></section>")
        let leaf = try XCTUnwrap(doc.select("p").first())
        let recorder = Recorder()
        recorder.result = { _ in throw Probe.failure }
        XCTAssertFalse(StructuralEvaluator.Parent(recorder).matches(Document(""), leaf))
        XCTAssertEqual(recorder.seen.map { $0.tagName() }, ["section", "body", "html", "#root"])
    }

    func testPredicateDetachmentDuringWalkTerminates() throws {
        let doc = try SwiftSoup.parse("<section><p>x</p></section>")
        let leaf = try XCTUnwrap(doc.select("p").first())
        let recorder = Recorder()
        recorder.result = { element in try element.remove(); return false }
        XCTAssertFalse(StructuralEvaluator.Parent(recorder).matches(doc, leaf))
        XCTAssertEqual(recorder.seen.count, 1)
        XCTAssertNil(leaf.parent()?.parent())
    }

    func testPublicParsedDescendantEvaluatorWithForeignScopeTerminates() throws {
        let foreign = Document("")
        let leaf = try Element(Tag.valueOf("p"), "")
        XCTAssertFalse(try QueryParser.parse("article p").matches(foreign, leaf))
        let root = try Element(Tag.valueOf("article"), "")
        try root.appendChild(leaf)
        XCTAssertTrue(try QueryParser.parse("article p").matches(foreign, leaf))
        try leaf.remove()
        XCTAssertFalse(try QueryParser.parse("article p").matches(foreign, leaf))
    }

    func testCustomParentProjectionAndCallbackOrder() throws {
        final class Projected: Element, @unchecked Sendable {
            var projected: Element?
            var reads = 0
            override func parent() -> Element? { reads += 1; return projected }
        }
        let first = Projected(try Tag.valueOf("first"), "")
        let second = Projected(try Tag.valueOf("second"), "")
        let leaf = Projected(try Tag.valueOf("p"), "")
        leaf.projected = first; first.projected = second
        let recorder = Recorder()
        XCTAssertFalse(StructuralEvaluator.Parent(recorder).matches(Document(""), leaf))
        XCTAssertEqual(recorder.seen.map { $0.tagName() }, ["first", "second"])
        XCTAssertEqual([leaf.reads, first.reads, second.reads], [1, 1, 1])
    }
    func testGeneratedChainsAgainstIndependentIndexModel() throws {
        for depth in 1...32 {
            let chain = try (0..<depth).map { try Element(Tag.valueOf("t\($0 % 3)"), "") }
            for i in 1..<depth { try chain[i - 1].appendChild(chain[i]) }
            let foreign = Document("")
            for rootIndex in -1..<depth {
                let root: Element = rootIndex < 0 ? foreign : chain[rootIndex]
                for tag in 0...3 {
                    var expected = false
                    if rootIndex != depth - 1, depth > 1 {
                        for i in stride(from: depth - 2, through: 0, by: -1) {
                            if i % 3 == tag { expected = true; break }
                            if i == rootIndex { break }
                        }
                    }
                    let eval = StructuralEvaluator.Parent(Evaluator.Tag("t\(tag)"))
                    XCTAssertEqual(eval.matches(root, chain[depth - 1]), expected)
                }
            }
        }
    }

}
