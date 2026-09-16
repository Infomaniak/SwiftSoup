import XCTest
@testable import SwiftSoup

final class SelectorCacheSnapshotTest: XCTestCase {
    func testDescendantCacheFollowsMovedAncestor() throws {
        let destination = try SwiftSoup.parse("<aside></aside>")
        let root: Element
        let text: TextNode
        weak var releasedDocument: Document?
        do {
            let original = try SwiftSoup.parse("<main><section><p>before</p></section></main>")
            releasedDocument = original
            let moved = try XCTUnwrap(original.select("main").first())
            root = try XCTUnwrap(moved.select("section").first())
            let paragraph = try XCTUnwrap(root.select("p").first())
            text = try XCTUnwrap(paragraph.childNode(0) as? TextNode)
            // Give the source a nonzero version before warming its cache.
            text.text("before")
            for _ in 0..<4 { XCTAssertEqual(try root.select("p:contains(before)").size(), 1) }
            XCTAssertNotNil(root.cachedSelectorResult("p:contains(before)"))
            try XCTUnwrap(destination.body()).appendChild(moved)
        }
        XCTAssertNil(releasedDocument)
        // Force an equal version across different roots, independently of how
        // many correct invalidations append/adoption performs.
        destination.textMutationVersion = root.selectorResultTextVersion &- 1
        text.text("after")
        XCTAssertEqual(root.selectorResultTextVersion, destination.textMutationVersion)
        XCTAssertEqual(try root.select("p:contains(before)").size(), 0)
        XCTAssertEqual(try root.select("p:contains(after)").size(), 1)
    }

    func testDescendantCacheInvalidatesWhenStandaloneRootIsAdopted() throws {
        let moved = try Element(Tag.valueOf("main"), "")
        try moved.append("<section><p>before</p></section>")
        let root = try XCTUnwrap(moved.select("section").first())
        let paragraph = try XCTUnwrap(root.select("p").first())
        let text = try XCTUnwrap(paragraph.childNode(0) as? TextNode)
        let destination = Document("")
        for _ in 0..<4 { XCTAssertEqual(try root.select("p:contains(before)").size(), 1) }
        XCTAssertNotNil(root.cachedSelectorResult("p:contains(before)"))
        try destination.appendChild(moved)
        // Force an equal version across different roots, independently of how
        // many correct invalidations append/adoption performs.
        destination.textMutationVersion = root.selectorResultTextVersion &- 1
        text.text("after")
        XCTAssertEqual(root.selectorResultTextVersion, destination.textMutationVersion)
        XCTAssertEqual(try root.select("p:contains(before)").size(), 0)
        XCTAssertEqual(try root.select("p:contains(after)").size(), 1)
    }

    func testSelfMatchingRootCanBeReleased() throws {
        weak var observed: Element?
        do {
            let root = try Element(Tag.valueOf("div"), "")
            observed = root
            let child = try root.appendElement("p")
            for _ in 0..<4 {
                let all = try root.select("*").array()
                XCTAssertEqual(all.map(ObjectIdentifier.init), [root, child].map(ObjectIdentifier.init))
                XCTAssertTrue(try root.select("div").first() === root)
            }
        }
        XCTAssertNil(observed)
    }

    func testWildcardDocumentCanBeReleased() throws {
        weak var observed: Document?
        do {
            let doc = try SwiftSoup.parse("<p>one</p>")
            observed = doc
            for _ in 0..<4 { XCTAssertTrue(try doc.select("*").first() === doc) }
        }
        XCTAssertNil(observed)
    }

    func testMutatingAdmittedMissDoesNotChangeLaterResults() throws {
        let doc = try SwiftSoup.parse("<p>one</p><span>two</span>")
        _ = try doc.select("p")
        let admitted = try doc.select("p")
        let paragraph = try XCTUnwrap(admitted.first())
        let span = try XCTUnwrap(doc.getElementsByTag("span").first())
        admitted.add(span)
        let later = try doc.select("p")
        XCTAssertEqual(later.size(), 1)
        XCTAssertTrue(later.first() === paragraph)
        XCTAssertEqual(admitted.size(), 2)
    }

    func testMutatingCacheHitDoesNotPoisonResultsOrRetainOwner() throws {
        weak var observed: Document?
        do {
            let doc = try SwiftSoup.parse("<p>one</p><span>two</span>")
            observed = doc
            for _ in 0..<4 { _ = try doc.select("p") }
            let returned = try doc.select("p")
            let paragraph = try XCTUnwrap(returned.first())
            returned.add(0, doc)
            let later = try doc.select("p")
            XCTAssertEqual(later.size(), 1)
            XCTAssertTrue(later.first() === paragraph)
            XCTAssertEqual(returned.size(), 2)
        }
        XCTAssertNil(observed)
    }

    func testSnapshotsPreserveLiveNodeIdentityAndRetainedCollections() throws {
        let doc = try SwiftSoup.parse("<p>one</p><p>two</p>")
        for _ in 0..<4 { _ = try doc.select("p") }
        let first = try doc.select("p")
        let second = try doc.select("p")
        XCTAssertFalse(first === second)
        XCTAssertEqual(first.array().map(ObjectIdentifier.init), second.array().map(ObjectIdentifier.init))
        let paragraph = try XCTUnwrap(first.first())
        try paragraph.text("changed")
        XCTAssertEqual(try second.first()?.text(), "changed")
        try paragraph.remove()
        XCTAssertEqual(first.size(), 2)
        XCTAssertEqual(second.size(), 2)
        XCTAssertEqual(try doc.select("p").size(), 1)
    }

    func testCustomCollectionIsNotReplacedWithPlainCachedElements() throws {
        let root = try Element(Tag.valueOf("div"), "")
        let result = CustomElements([try root.appendElement("p")])
        for _ in 0..<4 { root.storeSelectorResult("custom", result) }
        XCTAssertNil(root.cachedSelectorResult("custom"))
        XCTAssertEqual(result.arrayReads, 0)
    }

    func testSelfMatchingCacheHitsHaveIndependentContainers() throws {
        let root = try Element(Tag.valueOf("div"), "")
        let child = try root.appendElement("p")
        for _ in 0..<4 { _ = try root.select("*") }
        let first = try XCTUnwrap(root.cachedSelectorResult("*"))
        let second = try XCTUnwrap(root.cachedSelectorResult("*"))
        XCTAssertFalse(first === second)
        XCTAssertEqual(first.array().map(ObjectIdentifier.init), [root, child].map(ObjectIdentifier.init))
        let extra = try Element(Tag.valueOf("span"), "")
        first.add(extra)
        XCTAssertEqual(second.size(), 2)
        XCTAssertEqual(try root.select("*").size(), 2)
        XCTAssertEqual(first.size(), 3)
    }

    func testOwnerOnlyResultsRemainCachedAndInvalidateOnMutation() throws {
        let root = try Element(Tag.valueOf("div"), "")
        for _ in 0..<4 { _ = try root.select("div") }
        let result = try XCTUnwrap(root.cachedSelectorResult("div"))
        XCTAssertEqual(result.size(), 1)
        XCTAssertTrue(result.first() === root)
        try root.tagName("section")
        XCTAssertNil(root.cachedSelectorResult("div"))
        XCTAssertEqual(try root.select("div").size(), 0)
        XCTAssertTrue(result.first() === root)
    }

    func testNonstandardOwnerPlacementIsNotRetainedByCache() throws {
        weak var observed: Element?
        do {
            let root = try Element(Tag.valueOf("div"), "")
            observed = root
            let child = try root.appendElement("p")
            for elements in [[child, root], [root, child, root]] {
                for _ in 0..<4 { root.storeSelectorResult("nonstandard", Elements(elements)) }
                XCTAssertNil(root.cachedSelectorResult("nonstandard"))
            }
        }
        XCTAssertNil(observed)
    }

    private final class CustomElements: Elements {
        var arrayReads = 0
        override func array() -> [Element] {
            arrayReads += 1
            return super.array()
        }
    }
}
