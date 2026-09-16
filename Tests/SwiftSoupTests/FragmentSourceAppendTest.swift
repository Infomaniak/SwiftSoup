import Foundation
import XCTest
@testable import SwiftSoup

final class FragmentSourceAppendTest: XCTestCase {
    private func append(_ node: Node, to parent: Element, builder: HtmlTreeBuilder, fast: Bool) throws {
        if fast {
#if BASELINE_APPEND_REFERENCE
            try parent.appendChild(node)
#else
            builder.appendFragmentNode(node, to: parent)
#endif
        } else {
            try parent.appendChild(node)
        }
    }

    private func observe(_ doc: Document) throws -> [String] {
        var nodes: [Node] = []
        var pending: [Node] = [doc]
        while let node = pending.popLast() {
            nodes.append(node)
            pending.append(contentsOf: node.getChildNodes().reversed())
        }
        let positions = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { (ObjectIdentifier($0.element), $0.offset) })
        var values = ["text-version:\(doc.textMutationVersionToken())"]
        for node in nodes {
            let parent = node.parentNode.flatMap { positions[ObjectIdentifier($0)] } ?? -1
            values.append("\(node.nodeName()):\(parent):\(node.siblingIndex):\(node.sourceRangeDirty):\(node.sourceRangeIsComplete):\(node.sourceRange?.start ?? -1):\(node.sourceRange?.end ?? -1)")
            if let element = node as? Element {
                values.append("\(element.isTagQueryIndexDirty):\(element.isClassQueryIndexDirty):\(element.isIdQueryIndexDirty):\(element.isAttributeQueryIndexDirty):\(element.isAttributeValueQueryIndexDirty):\(element.selectorResultCache != nil)")
            }
            XCTAssertTrue(node.ownerDocument() === doc)
            for (index, child) in node.getChildNodes().enumerated() {
                XCTAssertTrue(child.parentNode === node)
                XCTAssertEqual(child.siblingIndex, index)
            }
        }
        values += doc.dirtySourceRoots.values.map {
            $0.value.flatMap { positions[ObjectIdentifier($0)] }.map(String.init) ?? "expired"
        }.sorted()
        values += [try doc.outerHtml(), String(decoding: try doc.outerHtmlUTF8(), as: UTF8.self),
                   String(decoding: try doc.outerHtmlUTF8WithoutSourceReuse(), as: UTF8.self), try doc.text()]
        for query in ["p", "b", "#new", ".new", "[data-x]", "p:contains(追加)"] {
            values.append(try doc.select(query).outerHtml())
        }
        return values
    }

    private func exercise(fast: Bool, seed: Int, warm: Bool, dirty: Bool) throws -> [String] {
        let builder = HtmlTreeBuilder()
        builder.initialiseParse(Array("<main><p>original</p></main>".utf8), [], .noTracking(), .htmlDefault)
        let doc = builder.doc
        doc.outputSettings().prettyPrint(pretty: false)
        let parent = try doc.appendElement("main")
        try parent.append("<p id='old'>original</p>")
        if warm {
            for _ in 0..<4 {
                _ = try doc.select("p")
                _ = try doc.select(".new")
                _ = try parent.select("#new")
                _ = try parent.text()
            }
        }
        doc.dirtySourceRoots.removeAll()
        doc.sourceRangeDirty = seed != 2
        if seed == 1 || seed == 2 { doc.dirtySourceRoots[ObjectIdentifier(doc)] = Weak(doc) }
        if seed == 3 {
            parent.sourceRangeDirty = true
            doc.dirtySourceRoots[ObjectIdentifier(parent)] = Weak(parent)
        }
        parent.sourceRangeDirty = dirty
        let p = try Element(Tag.valueOf("p"), "")
        try p.attr("id", "new").attr("class", "new").attr("data-x", "1")
        try p.appendText("追加")
        let children: [Node] = [p, TextNode("末尾 &", ""), Comment(Array("comment".utf8), []), DataNode(Array("data".utf8), [])]
        for node in children {
            node.sourceRangeDirty = dirty
            node.treeBuilder = builder // insertNode establishes this before appendChild.
            try append(node, to: parent, builder: builder, fast: fast)
        }
        return try observe(doc)
    }

    func testFreshFragmentAppendMatchesPublicInsertionState() throws {
        for seed in 0..<4 {
            for dirty in [false, true] {
                XCTAssertEqual(try exercise(fast: true, seed: seed, warm: false, dirty: dirty),
                               try exercise(fast: false, seed: seed, warm: false, dirty: dirty))
            }
        }
    }

    func testWarmedIndexesAndTextCachesStillInvalidate() throws {
        for seed in 0..<4 {
            XCTAssertEqual(try exercise(fast: true, seed: seed, warm: true, dirty: false),
                           try exercise(fast: false, seed: seed, warm: true, dirty: false))
        }
    }

    func testFragmentContextsMaintainOrderAndOwnershipAfterMutation() throws {
        let cases = [
            ("div", "<p>一 &amp; 二</p><p><b>三</b></p>"),
            ("table", "<tr><td>一</td><td>二</td></tr>"),
            ("tbody", "<tr><td>一</td></tr>"),
            ("select", "<option>一<option>二"),
            ("ruby", "<rb>漢字</rb><rp>(</rp><rt>かんじ</rt><rp>)</rp>"),
            ("div", "<b><i>一</b>二</i><table>三<tr><td>四</td></tr></table>")
        ]
        for (tag, markup) in cases {
            let doc = try SwiftSoup.parse("<main></main>")
            let root = try Element(Tag.valueOf(tag), "")
            try root.attr("id", "target")
            try doc.getElementsByTag("main").first()!.appendChild(root)
            try root.html(markup)
            doc.outputSettings().prettyPrint(pretty: false)
            _ = try observe(doc)
            let before = try doc.outerHtmlUTF8WithoutSourceReuse()
            let clone = doc.copy() as! Document
            clone.outputSettings().prettyPrint(pretty: false)
            XCTAssertEqual(before, try clone.outerHtmlUTF8WithoutSourceReuse())
            _ = try observe(clone)
            try root.append("<span>終わり</span>")
            _ = try observe(doc)
        }
    }

    func testSourceBackedFragmentInsertionDoesNotReturnStaleMarkup() throws {
        let doc = try SwiftSoup.parse("<html><head><title>original</title></head><body><main></main></body></html>")
        doc.outputSettings().prettyPrint(pretty: false)
        let main = try XCTUnwrap(doc.getElementsByTag("main").first())
        try main.html("<p id='new' class='before'>日本&amp;語</p><ruby>漢<rt>かん</rt></ruby>")
        let p = try XCTUnwrap(doc.getElementById("new"))
        for _ in 0..<4 { XCTAssertEqual(try doc.select(".before").size(), 1) }
        try p.attr("class", "after").text("変更後")
        try doc.select("rt").remove()
        let html = String(decoding: try doc.outerHtmlUTF8ReusingSourceOutsideBody(), as: UTF8.self)
        let reparsed = try SwiftSoup.parse(html)
        XCTAssertEqual(try reparsed.getElementById("new")?.text(), "変更後")
        XCTAssertEqual(try reparsed.select(".before, rt").size(), 0)
        XCTAssertEqual(try reparsed.select(".after").size(), 1)
    }
    private func structuralObservation(fast: Bool, seed: Int, nodeDirty: Bool,
                                       parentDirty: Bool, detached: Bool) throws -> [String] {
        let builder = HtmlTreeBuilder()
        builder.initialiseParse(Array("<main><p>value</p></main>".utf8), [], .noTracking(), .htmlDefault)
        let document = builder.doc
        document.outputSettings().prettyPrint(pretty: false)
        let parent = try document.appendElement("main")
        let node = try Element(Tag.valueOf("p"), "")
        if !detached { try parent.appendChild(node) }
        builder.stack = [parent, node]
        document.dirtySourceRoots.removeAll()
        document.sourceRangeDirty = seed != 2
        if seed == 1 || seed == 2 {
            document.dirtySourceRoots[ObjectIdentifier(document)] = Weak(document)
        }
        if seed == 3 { document.dirtySourceRoots[ObjectIdentifier(parent)] = Weak(parent) }
        node.sourceRangeDirty = nodeDirty
        parent.sourceRangeDirty = parentDirty
        builder.beginBulkAppend()
        defer { builder.endBulkAppend() }
        if fast { builder.markStructuralChange(detached ? node : nil) }
        else { node.markSourceDirty(force: true) }
        return try ["node:\(node.sourceRangeDirty)", "parent:\(parent.sourceRangeDirty)"] + observe(document)
    }

    func testStructuralDirtyingMatchesReferenceAcrossCoverageAndExistingFlags() throws {
        for seed in 0..<4 {
            for dirty in [false, true] {
                for parentDirty in [false, true] {
                    for detached in [false, true] {
                        XCTAssertEqual(
                            try structuralObservation(fast: true, seed: seed, nodeDirty: dirty,
                                                      parentDirty: parentDirty, detached: detached),
                            try structuralObservation(fast: false, seed: seed, nodeDirty: dirty,
                                                      parentDirty: parentDirty, detached: detached),
                            "seed=\(seed) nodeDirty=\(dirty) parentDirty=\(parentDirty) detached=\(detached)"
                        )
                    }
                }
            }
        }
    }

    func testStructuralChangeWithEmptyStackIsANoop() throws {
        let builder = HtmlTreeBuilder()
        builder.initialiseParse([], [], .noTracking(), .htmlDefault)
        let document = builder.doc
        let version = document.textMutationVersionToken()
        let dirty = document.sourceRangeDirty
        builder.markStructuralChange()
        XCTAssertEqual(document.textMutationVersionToken(), version)
        XCTAssertEqual(document.sourceRangeDirty, dirty)
        XCTAssertTrue(document.dirtySourceRoots.isEmpty)
        XCTAssertEqual(try document.outerHtml(), "")
    }

    func testPublicManualStackEditsKeepForeignOwnerDispatch() throws {
        final class RedirectedElement: Element {
            var redirectedOwner: Document?
            var ownerLookups = 0
            override func ownerDocument() -> Document? {
                ownerLookups += 1
                return redirectedOwner
            }
        }
        let parser = Parser.htmlParser()
        let document = try parser.parseInput("<p>initial</p>", "")
        let builder = parser.getTreeBuilder()
        let foreign = try SwiftSoup.parse("<main></main>")
        let node = try RedirectedElement(Tag.valueOf("p"), "")
        node.redirectedOwner = foreign
        let parent = try XCTUnwrap(foreign.body())
        try parent.appendChild(node)
        builder.stack = [parent, node]
        document.sourceRangeDirty = true
        document.dirtySourceRoots = [ObjectIdentifier(document): Weak(document)]
        foreign.dirtySourceRoots.removeAll()
        node.sourceRangeDirty = false
        node.ownerLookups = 0
        // This is a public API operation after replacing the public stack.
        try builder.processEndTag("p")
        XCTAssertTrue(node.sourceRangeDirty)
        XCTAssertGreaterThan(node.ownerLookups, 0)
        XCTAssertTrue(foreign.dirtySourceRoots[ObjectIdentifier(node)]?.value === node)
        XCTAssertTrue(document.dirtySourceRoots[ObjectIdentifier(document)]?.value === document)
    }

}
