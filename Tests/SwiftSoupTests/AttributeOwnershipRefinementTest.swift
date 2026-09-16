import XCTest
@testable import SwiftSoup

final class AttributeOwnershipRefinementTest: XCTestCase {
    private func firstParagraph(_ doc: Document) throws -> Element {
        var stack: [Node] = [doc]
        while let node = stack.popLast() {
            if let element = node as? Element, element.tagName() == "p" { return element }
            stack.append(contentsOf: node.childNodes.reversed())
        }
        throw NSError(domain: "missing fixture paragraph", code: 1)
    }

    private final class ProjectedAttribute: Attribute {
        override func getKeyUTF8() -> [UInt8] { Array("UPPER".utf8) }
        override func getValueUTF8() -> [UInt8] { Array("visible".utf8) }
    }

    private final class RejectingKeyAttribute: Attribute {
        override func setKey(key: [UInt8]) throws {
            throw NSError(domain: "custom setter rejects changes", code: 1)
        }
    }

    func testDeferredAttributeReadDoesNotDirtyParsedSource() throws {
        let doc = try SwiftSoup.parse("<html><head></head><body><p title='one' CLASS='two' data-v='three'>text</p></body></html>")
        let p = try firstParagraph(doc)
        let attrs = try XCTUnwrap(p.attributes)
        XCTAssertFalse(p.sourceRangeDirty)
        let documentWasDirty = doc.sourceRangeDirty
        XCTAssertGreaterThan(attrs.pendingAttributesCount, 0)
        let version = doc.textMutationVersionToken()
        XCTAssertEqual(attrs.asList().count, 3)
        XCTAssertFalse(p.sourceRangeDirty, "materialization is a read, not a DOM edit")
        XCTAssertEqual(doc.sourceRangeDirty, documentWasDirty)
        XCTAssertEqual(doc.textMutationVersionToken(), version)
    }

    func testMaterializationPreservesAlreadyCleanIndexes() throws {
        let doc = try SwiftSoup.parse("<html><head></head><body><p title='one'>text</p></body></html>")
        let p = try firstParagraph(doc)
        let attrs = try XCTUnwrap(p.attributes)
        // Model indexes previously validated from the deferred representation.
        p.isClassQueryIndexDirty = false
        p.isIdQueryIndexDirty = false
        p.isAttributeQueryIndexDirty = false
        p.isAttributeValueQueryIndexDirty = false
        _ = attrs.asList()
        XCTAssertFalse(p.isClassQueryIndexDirty)
        XCTAssertFalse(p.isIdQueryIndexDirty)
        XCTAssertFalse(p.isAttributeQueryIndexDirty)
        XCTAssertFalse(p.isAttributeValueQueryIndexDirty)
    }

    func testCloneMaterializationDoesNotDirtyOriginal() throws {
        let doc = try SwiftSoup.parse("<html><head></head><body><p title='one'>text</p></body></html>")
        let p = try firstParagraph(doc)
        let documentWasDirty = doc.sourceRangeDirty
        let copied = try XCTUnwrap(p.attributes).clone()
        XCTAssertEqual(doc.sourceRangeDirty, documentWasDirty)
        XCTAssertFalse(p.sourceRangeDirty)
        XCTAssertEqual(copied.get(key: "title"), "one")
    }

    func testAttributeClonePreservesPublicGetterProjection() throws {
        let custom = try ProjectedAttribute(key: Array("stored".utf8), value: Array("raw".utf8))
        let copy = custom.clone()
        XCTAssertEqual(copy.getKey(), "UPPER")
        XCTAssertEqual(copy.getValue(), "visible")
        XCTAssertFalse(copy === custom)
    }

    func testCollectionCloneRecomputesProjectedKeyCase() throws {
        let attrs = Attributes()
        attrs.put(attribute: try ProjectedAttribute(key: Array("stored".utf8), value: Array("raw".utf8)))
        let copy = attrs.clone()
        XCTAssertEqual(copy.get(key: "UPPER"), "visible")
        XCTAssertEqual(try copy.getIgnoreCase(key: "upper"), "visible")
        XCTAssertTrue(copy.hasKeyIgnoreCase(key: "upper"))
    }

    func testValueSetterNoOpChecksStoredValueNotGetterProjection() throws {
        let custom = try ProjectedAttribute(key: Array("stored".utf8), value: Array("raw".utf8))
        let attrs = Attributes()
        attrs.put(attribute: custom)
        XCTAssertEqual(custom.setValue(value: Array("visible".utf8)), Array("visible".utf8))
        XCTAssertEqual(custom.html(), "stored=\"visible\"")
        XCTAssertEqual(attrs.get(key: "stored"), "visible")
    }

    func testLowercaseNormalizationDoesNotInvokeCustomSetter() throws {
        // Normalization has historically updated stored keys rather than calling an open setter.
        let custom = try RejectingKeyAttribute(key: Array("UPPER".utf8), value: Array("v".utf8))
        let a = Attributes()
        let b = Attributes()
        a.put(attribute: custom)
        b.put(attribute: custom)
        XCTAssertTrue(a.hasKey(key: "UPPER"))
        XCTAssertTrue(b.hasKey(key: "UPPER"))
        a.lowercaseAllKeys()
        for attrs in [a, b] {
            XCTAssertEqual(attrs.get(key: "upper"), "v")
            XCTAssertFalse(attrs.hasKey(key: "UPPER"))
            XCTAssertEqual(try attrs.getIgnoreCase(key: "UPPER"), "v")
        }
    }

    func testSharedCollectionDropsDeadSecondaryObserversOnMutation() throws {
        let attrs = Attributes()
        try attrs.put("title", "old")
        let survivor = Element(try Tag.valueOf("p"), "", attrs)
        var owners: [Element] = []
        for _ in 0..<128 { owners.append(Element(try Tag.valueOf("p"), "", attrs)) }
        XCTAssertEqual(attrs.additionalOwnerNodes?.count, 128)
        owners.removeAll()
        try attrs.put("title", "new")
        XCTAssertTrue(attrs.additionalOwnerNodes?.isEmpty ?? true)
        XCTAssertEqual(try survivor.attr("title"), "new")
    }

    func testDeadPrimaryOwnerPromotesSurvivorOnlyOnce() throws {
        let attrs = Attributes()
        try attrs.put("title", "old")
        var first: Element? = Element(try Tag.valueOf("p"), "", attrs)
        let second = Element(try Tag.valueOf("p"), "", attrs)
        weak var expired = first
        first = nil
        XCTAssertNil(expired)
        try attrs.put("title", "new")
        XCTAssertTrue(attrs.ownerNode === second)
        XCTAssertTrue(attrs.additionalOwnerNodes?.isEmpty ?? true)
        for _ in 0..<4 { XCTAssertEqual(try second.select("[title=new]").size(), 1) }
    }

    func testSharedReferenceSurvivesRepeatedRemoveAndReinsert() throws {
        let a = Element(try Tag.valueOf("p"), "")
        let b = Element(try Tag.valueOf("p"), "")
        let shared = try Attribute(key: "class", value: "v0")
        a.getAttributes()!.put(attribute: shared)
        for round in 1...64 {
            let attrs = b.getAttributes()!
            attrs.put(attribute: shared)
            let value = "v\(round)"
            shared.setValue(value: Array(value.utf8))
            for element in [a, b] {
                for _ in 0..<4 { XCTAssertTrue(try element.select("." + value).first() === element) }
            }
            try b.removeAttr("class")
            shared.setValue(value: Array("between".utf8))
            XCTAssertEqual(try b.select(".between").size(), 0)
        }
    }
}
