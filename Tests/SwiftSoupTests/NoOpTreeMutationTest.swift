import XCTest
@testable import SwiftSoup

final class NoOpTreeMutationTest: XCTestCase {
    private func fixture(empty: Bool = false) throws -> (Document, Element) {
        let html = "<html><head></head><body><DIV id = 'target' data-x='keep'>" +
            (empty ? "" : "<SPAN title = 'nested'>payload</SPAN>") + "</DIV></body></html>"
        let doc = try SwiftSoup.parse(html)
        return (doc, try XCTUnwrap(doc.getElementById("target")))
    }

    private func check(_ doc: Document, _ target: Element, _ operation: () throws -> Void,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        for query in ["#target", "div:empty", "div:contains(payload)", "span:first-child", "[data-x=keep]"] {
            for _ in 0..<3 { _ = try doc.select(query) }
        }
        let before = try doc.outerHtmlUTF8()
        let children = target.getChildNodes()
        let version = doc.textMutationVersionToken()
        let flags = [doc.sourceRangeDirty, target.sourceRangeDirty]
        try operation()
        XCTAssertEqual(try doc.outerHtmlUTF8(), before, file: file, line: line)
        XCTAssertEqual(doc.textMutationVersionToken(), version, file: file, line: line)
        XCTAssertEqual([doc.sourceRangeDirty, target.sourceRangeDirty], flags, file: file, line: line)
        XCTAssertEqual(target.getChildNodes().map(ObjectIdentifier.init), children.map(ObjectIdentifier.init), file: file, line: line)
        for (index, child) in children.enumerated() {
            XCTAssertTrue(child.parent() === target, file: file, line: line)
            XCTAssertEqual(child.siblingIndex, index, file: file, line: line)
        }
    }

    func testEmptyArrayAppendIsARepresentationPreservingNoOp() throws {
        let (doc, target) = try fixture()
        try check(doc, target) { try target.addChildren([Node]()) }
    }

    func testEmptyVariadicAppendIsARepresentationPreservingNoOp() throws {
        let (doc, target) = try fixture()
        try check(doc, target) { try target.addChildren() }
    }

    func testEmptyIndexedInsertPreservesAllValidGaps() throws {
        for gap in 0...1 {
            let (doc, target) = try fixture()
            try check(doc, target) { try target.addChildren(gap, [Node]()) }
        }
    }

    func testElementEmptyInsertPreservesNegativeIndexSemantics() throws {
        for gap in [-2, -1, 0, 1] {
            let (doc, target) = try fixture()
            try check(doc, target) { try target.insertChildren(gap, []) }
        }
    }

    func testEmptyHTMLAppendAndPrependLeaveSourceUntouched() throws {
        for prepend in [false, true] {
            let (doc, target) = try fixture()
            try check(doc, target) {
                if prepend { try target.prepend("") } else { try target.append("") }
            }
        }
    }

    func testEmptySiblingHTMLLeavesSourceUntouched() throws {
        for before in [false, true] {
            let (doc, target) = try fixture()
            try check(doc, target) {
                if before { try target.before("") } else { try target.after("") }
            }
        }
    }

    func testEmptyOnAnAlreadyEmptyElementIsANoOp() throws {
        let (doc, target) = try fixture(empty: true)
        try check(doc, target) { target.empty() }
    }

    func testInvalidEmptyInsertionStillThrowsBeforeMutation() throws {
        let (doc, target) = try fixture()
        try check(doc, target) {
            for index in [Int.min, -3, 2, Int.max] { XCTAssertThrowsError(try target.insertChildren(index, [])) }
            for index in [Int.min, -1, 2, Int.max] { XCTAssertThrowsError(try target.addChildren(index, [Node]())) }
        }
    }

    func testEmptyTextIsARealNodeAndStillInvalidates() throws {
        let (doc, target) = try fixture(empty: true)
        _ = try doc.select("div:empty")
        let version = doc.textMutationVersionToken()
        try target.appendText("")
        XCTAssertEqual(target.childNodeSize(), 1)
        XCTAssertTrue(target.getChildNodes()[0] is TextNode)
        XCTAssertNotEqual(doc.textMutationVersionToken(), version)
        target.empty()
        XCTAssertEqual(target.childNodeSize(), 0)
    }

    func testRepeatedNoOpsThenRealMutationRefreshesWarmedSelectors() throws {
        let (doc, target) = try fixture(empty: true)
        for _ in 0..<64 {
            XCTAssertTrue(try doc.select("#target:empty").first() === target)
            try check(doc, target) {
                try target.addChildren([Node]())
                try target.insertChildren(-1, [])
                target.empty()
            }
        }
        try target.appendText("payload")
        XCTAssertEqual(try doc.select("#target:empty").size(), 0)
        XCTAssertTrue(try doc.select("#target:contains(payload)").first() === target)
        XCTAssertEqual(target.childNodeSize(), 1)
    }
}
