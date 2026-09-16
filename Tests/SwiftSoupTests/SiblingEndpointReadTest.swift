import XCTest
@testable import SwiftSoup

final class SiblingEndpointReadTest: XCTestCase {
    private func check(_ parent: Element, receivers: [Element]? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let family = parent.children().array()
        for node in receivers ?? family {
            XCTAssertTrue(node.firstElementSibling() === (family.count > 1 ? family.first : nil), file: file, line: line)
            XCTAssertTrue(node.lastElementSibling() === (family.count > 1 ? family.last : nil), file: file, line: line)
        }
    }

    func testMixedFamiliesAtEverySmallWidthAndLegacySingletonNil() throws {
        for count in 0...48 {
            let parent = try Element(Tag.valueOf("section"), "")
            try parent.appendChild(TextNode("start", ""))
            for _ in 0..<count {
                try parent.appendChild(Comment(Array("c".utf8), []))
                try parent.appendElement("p")
                try parent.appendChild(DataNode(Array("data".utf8), []))
            }
            try parent.appendChild(TextNode("end", ""))
            check(parent)
        }
        let detached = try Element(Tag.valueOf("p"), "")
        XCTAssertNil(detached.firstElementSibling()); XCTAssertNil(detached.lastElementSibling())
    }

    func testDocumentAndFormElementParents() throws {
        let doc = Document("")
        try doc.appendElement("p"); try doc.appendElement("span"); check(doc)
        let form = try FormElement(Tag.valueOf("form"), "", Attributes())
        try form.appendElement("input"); try form.appendChild(Comment(Array("gap".utf8), [])); try form.appendElement("button")
        check(form)
    }

    private final class Log { var events: [String] = [] }
    private final class View: Elements {
        let log: Log
        init(_ values: [Element], _ log: Log) { self.log = log; super.init(values) }
        override func array() -> [Element] { log.events.append("array"); return super.array() }
    }
    private final class Parent: Element, @unchecked Sendable {
        var view: Elements?
        var log: Log?
        override func children() -> Elements { log?.events.append("children"); return view ?? super.children() }
    }
    private final class Receiver: Element, @unchecked Sendable {
        var visible: Element?
        var log: Log?
        override func parent() -> Element? { log?.events.append("parent"); return visible }
    }

    func testCustomParentChildrenArrayProjectionAndExactCallbackOrder() throws {
        let log = Log(), parent = try Parent(Tag.valueOf("section"), "")
        let a = try Element(Tag.valueOf("p"), ""), b = try Element(Tag.valueOf("b"), "")
        let receiver = try Receiver(Tag.valueOf("i"), "")
        parent.log = log; parent.view = View([b,a],log)
        receiver.log = log; receiver.visible = parent
        XCTAssertTrue(receiver.firstElementSibling() === b)
        XCTAssertEqual(log.events,["parent","children","array"])
        log.events=[]
        XCTAssertTrue(receiver.lastElementSibling() === a)
        XCTAssertEqual(log.events,["parent","children","array"])
        for values in [[],[a],[a,a]] {
            parent.view=View(values,log)
            XCTAssertTrue(receiver.firstElementSibling() === (values.count>1 ? a:nil))
            XCTAssertTrue(receiver.lastElementSibling() === (values.count>1 ? a:nil))
        }
    }

    func testRedirectedParentWithoutStoredMembershipAndNilProjection() throws {
        let projected = try Element(Tag.valueOf("section"), "")
        try projected.appendElement("p"); try projected.appendElement("b")
        let receiver = try Receiver(Tag.valueOf("i"), "")
        receiver.visible=projected
        check(projected,receivers:[receiver])
        receiver.visible=nil
        XCTAssertNil(receiver.firstElementSibling()); XCTAssertNil(receiver.lastElementSibling())
    }

    func testStaleSiblingIndicesDoNotChangeEndpointReads() throws {
        let parent = try Element(Tag.valueOf("section"), "")
        try parent.append("t<p>a</p><!--b--><b>b</b><em>c</em>t")
        let nodes=parent.children().array()
        for node in nodes {
            let saved=node.siblingIndex
            for bad in [Int.min,-1,0,1,Int.max] { node.setSiblingIndex(bad); check(parent) }
            node.setSiblingIndex(saved)
        }
    }

    func testBuiltInDuplicateMembershipRetainsCountRatherThanDistinctness() throws {
        let parent = try Element(Tag.valueOf("section"), "")
        let a=try parent.appendElement("p")
        parent.childNodes=[a,a]
        XCTAssertTrue(a.firstElementSibling() === a); XCTAssertTrue(a.lastElementSibling() === a)
        parent.childNodes=[a]
        XCTAssertNil(a.firstElementSibling()); XCTAssertNil(a.lastElementSibling())
    }

    func testMutationRoundsClonesAndSourceState() throws {
        let doc=try SwiftSoup.parse("<main><p>a</p>t<b>b</b><!--c--><p>c</p></main><aside><em>x</em></aside>")
        let main=try XCTUnwrap(doc.select("main").first()), aside=try XCTUnwrap(doc.select("aside").first())
        let output=try doc.outerHtml(), token=doc.textMutationVersionToken()
        for _ in 0..<4 { check(main); check(aside) }
        XCTAssertEqual(try doc.outerHtml(),output); XCTAssertEqual(doc.textMutationVersionToken(),token)
        var state: UInt64=0x74371
        for round in 0..<192 {
            state=state &* 6364136223846793005 &+ 1
            let source=(state&1)==0 ? main:aside, target=source===main ? aside:main
            if let last=source.children().last() { try target.prependChild(last) }
            if round%4==0 { try source.appendElement("span") }
            if round%7==0 { try target.appendChild(Comment(Array("gap".utf8), [])) }
            check(main); check(aside)
        }
        let copy=doc.copy() as! Document
        for parent in try copy.select("main,aside") { check(parent) }
    }
}
