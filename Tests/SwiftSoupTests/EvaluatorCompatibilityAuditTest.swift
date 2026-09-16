import XCTest
@testable import SwiftSoup

final class EvaluatorCompatibilityAuditTest: XCTestCase {
    private enum Failure: Error { case deliberate }
    private final class Throwing: Evaluator, @unchecked Sendable {
        override func matches(_ root: Element, _ element: Element) throws -> Bool { throw Failure.deliberate }
    }
    private final class MatchOrThrow: Evaluator, @unchecked Sendable {
        override func matches(_ root: Element, _ element: Element) throws -> Bool {
            if element.tagName() == "p" { return true }
            throw Failure.deliberate
        }
    }
    private final class NeverTag: Evaluator.Tag, @unchecked Sendable {
        override func matches(_ root: Element, _ element: Element) throws -> Bool { false }
    }
    private final class NeverRoot: StructuralEvaluator.Root, @unchecked Sendable {
        override func matches(_ root: Element, _ element: Element) -> Bool { false }
    }
    private final class NeverHas: StructuralEvaluator.Has, @unchecked Sendable {
        override func matches(_ root: Element, _ element: Element) throws -> Bool { false }
    }
    private final class MissingAttributeMatcher: Evaluator.AttributeKeyPair, @unchecked Sendable {
        override func matches(_ root: Element, _ element: Element) throws -> Bool { element.tagName() == "p" }
    }

    func testThrowingAndPredicatesKeepEstablishedCompositeSemantics() throws {
        let doc = try SwiftSoup.parse("<p>one</p><p>two</p><i>three</i>")
        let and = CombiningEvaluator.And([Evaluator.Tag("p"), Throwing()])
        let expected = try doc.getAllElements().array().filter { and.matches(doc, $0) }
        XCTAssertEqual(try Collector.collect(and, doc).array().map(ObjectIdentifier.init), expected.map(ObjectIdentifier.init))
        XCTAssertEqual(try CssSelector.select(and, doc).array().map(ObjectIdentifier.init), expected.map(ObjectIdentifier.init))
    }

    func testHasSkipsIndividualFailuresButKeepsOtherMatches() throws {
        let doc = try SwiftSoup.parse("<main><section><p>x</p></section><aside></aside></main>")
        for nested in [Throwing(), MatchOrThrow()] as [Evaluator] {
            let has = StructuralEvaluator.Has(nested)
            let expected = try doc.getAllElements().array().filter { try has.matches(doc, $0) }
            XCTAssertEqual(try Collector.collect(has, doc).array().map(ObjectIdentifier.init), expected.map(ObjectIdentifier.init))
            XCTAssertEqual(try CssSelector.select(has, doc).array().map(ObjectIdentifier.init), expected.map(ObjectIdentifier.init))
        }
    }

    // These superclass extension points are available to same-module/testable
    // subclasses; the base classes are not open to normal external imports.
    func testSameModuleEvaluatorOverridesAreNotReplacedByIndexes() throws {
        let doc = try SwiftSoup.parse("<p>one</p>")
        let cases: [Evaluator] = [NeverTag("p"), NeverRoot(), NeverHas(Evaluator.Tag("p")),
                                  CombiningEvaluator.And([NeverTag("p"), Evaluator.AllElements()])]
        for evaluator in cases {
            XCTAssertEqual(try Collector.collect(evaluator, doc).size(), 0)
            XCTAssertEqual(try CssSelector.select(evaluator, doc).size(), 0)
        }
        let missing = try MissingAttributeMatcher("data-x", "value")
        let composite = CombiningEvaluator.And([missing])
        XCTAssertEqual(try Collector.collect(composite, doc).size(), 1)
        XCTAssertEqual(try CssSelector.select(composite, doc).size(), 1)
    }
}
