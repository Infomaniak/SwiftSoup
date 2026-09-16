import XCTest
@testable import SwiftSoup

final class AttributeOwnershipTest: XCTestCase {
    private func attribute(_ attrs: Attributes, _ key: String) throws -> Attribute {
        try XCTUnwrap(attrs.first { $0.getKey() == key })
    }

    private func assertMatches(_ root: Element, _ query: String, _ expected: [Element],
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let evaluator = try QueryParser.parse(query)
        var stack = [root]
        var scanned: [Element] = []
        while let node = stack.popLast() {
            if try evaluator.matches(root, node) { scanned.append(node) }
            stack.append(contentsOf: node.childNodes.reversed().compactMap { $0 as? Element })
        }
        let ids = expected.map(ObjectIdentifier.init)
        XCTAssertEqual(scanned.map(ObjectIdentifier.init), ids, "scan: \(query)", file: file, line: line)
        XCTAssertEqual(try Collector.collect(evaluator, root).array().map(ObjectIdentifier.init), ids,
                       "collector: \(query)", file: file, line: line)
        for _ in 0..<4 {
            XCTAssertEqual(try root.select(query).array().map(ObjectIdentifier.init), ids,
                           "cached selection: \(query)", file: file, line: line)
        }
    }

    func testSharedAttributeValueNotifiesEveryCollection() throws {
        let a = try SwiftSoup.parse("<p></p>")
        let b = try SwiftSoup.parse("<p></p>")
        let pa = try XCTUnwrap(a.select("p").first())
        let pb = try XCTUnwrap(b.select("p").first())
        let shared = try Attribute(key: "class", value: "old")
        pa.getAttributes()!.put(attribute: shared)
        pb.getAttributes()!.put(attribute: shared)
        for (doc, p) in [(a, pa), (b, pb)] { try assertMatches(doc, ".old", [p]) }
        XCTAssertEqual(String(decoding: shared.setValue(value: Array("new".utf8)), as: UTF8.self), "old")
        for (doc, p) in [(a, pa), (b, pb)] {
            try assertMatches(doc, ".old", [])
            try assertMatches(doc, ".new", [p])
        }
    }

    func testAddAllRegistersPreviouslyUnexposedSourceAttributes() throws {
        let a = try SwiftSoup.parse("<p id='old' data-v='first'></p>")
        let b = try SwiftSoup.parse("<p></p>")
        let pa = try XCTUnwrap(a.select("p").first())
        let pb = try XCTUnwrap(b.select("p").first())
        pb.getAttributes()!.addAll(incoming: pa.getAttributes())
        try assertMatches(a, "#old", [pa])
        try assertMatches(b, "#old", [pb])
        let id = try attribute(pb.getAttributes()!, "id")
        id.setValue(value: Array("new".utf8))
        for (doc, p) in [(a, pa), (b, pb)] {
            try assertMatches(doc, "#old", [])
            try assertMatches(doc, "#new", [p])
        }
    }

    func testSharedCollectionNotifiesEveryElement() throws {
        let attrs = Attributes()
        try attrs.put("class", "old")
        let a = Element(try Tag.valueOf("p"), "", attrs)
        let b = Element(try Tag.valueOf("p"), "", attrs)
        for p in [a, b] { try assertMatches(p, ".old", [p]) }
        try attrs.put("class", "new")
        for p in [a, b] {
            try assertMatches(p, ".old", [])
            try assertMatches(p, ".new", [p])
        }
        try attribute(attrs, "class").setKey(key: "title")
        for p in [a, b] { try assertMatches(p, ".new", []) }
    }

    func testDirectValueMutationInvalidatesDynamicAttributeIndex() throws {
        let doc = try SwiftSoup.parse("<p data-custom='before'></p>")
        let p = try XCTUnwrap(doc.select("p").first())
        try assertMatches(doc, "[data-custom=before]", [p])
        let a = try attribute(p.getAttributes()!, "data-custom")
        a.setValue(value: [])
        try assertMatches(doc, "[data-custom=before]", [])
        try assertMatches(doc, "[data-custom='']", [p])
        try assertMatches(doc, "[data-custom~=^$]", [p])
    }

    func testRenameInvalidatesBothKeyIndexes() throws {
        let attrs = Attributes()
        for i in 0..<12 { try attrs.put("k\(i)", "v\(i)") }
        let a = try attribute(attrs, "k0")
        XCTAssertEqual(attrs.get(key: "k0"), "v0")
        XCTAssertEqual(try attrs.getIgnoreCase(key: "K0"), "v0")
        try a.setKey(key: "RENAMED")
        XCTAssertFalse(attrs.hasKey(key: "k0"))
        XCTAssertFalse(attrs.hasKeyIgnoreCase(key: "K0"))
        XCTAssertEqual(attrs.get(key: "RENAMED"), "v0")
        XCTAssertEqual(try attrs.getIgnoreCase(key: "renamed"), "v0")
        XCTAssertTrue(attrs.hasKeyIgnoreCase(key: ArraySlice(Array("renamed".utf8))))
    }

    func testRenameIntoAndOutOfIdAndClass() throws {
        let doc = try SwiftSoup.parse("<p title='x'></p>")
        let p = try XCTUnwrap(doc.select("p").first())
        let a = try attribute(p.getAttributes()!, "title")
        try assertMatches(doc, "#x", [])
        try assertMatches(doc, ".x", [])
        try a.setKey(key: "ID")
        try assertMatches(doc, "#x", [p])
        try a.setKey(key: "CLASS")
        try assertMatches(doc, "#x", [])
        try assertMatches(doc, ".x", [p])
        try a.setKey(key: "title")
        try assertMatches(doc, ".x", [])
    }

    func testAsListMutationRemainsLive() throws {
        let doc = try SwiftSoup.parse("<p class='before'></p>")
        let p = try XCTUnwrap(doc.select("p").first())
        let saved = p.getAttributes()!.asList()
        try assertMatches(doc, ".before", [p])
        saved[0].setValue(value: Array("after".utf8))
        try assertMatches(doc, ".before", [])
        try assertMatches(doc, ".after", [p])
    }

    func testSavedIteratorDoesNotMutateReplacementAttribute() throws {
        let doc = try SwiftSoup.parse("<p class='before'></p>")
        let p = try XCTUnwrap(doc.select("p").first())
        let iterator = p.getAttributes()!.makeIterator()
        try p.attr("class", "replacement")
        let old = try XCTUnwrap(iterator.next())
        try assertMatches(doc, ".replacement", [p])
        XCTAssertFalse(doc.isClassQueryIndexDirty)
        old.setValue(value: Array("stale".utf8))
        XCTAssertFalse(doc.isClassQueryIndexDirty, "removed references must not invalidate their former owners")
        try assertMatches(doc, ".replacement", [p])
        try assertMatches(doc, ".stale", [])
    }

    func testRemoveAllDetachesOnlyRemovedOwners() throws {
        let doc = try SwiftSoup.parse("<p class='x' id='a'></p>")
        let p = try XCTUnwrap(doc.select("p").first())
        let attrs = p.getAttributes()!
        let a = try attribute(attrs, "class")
        let other = Attributes()
        other.put(attribute: a)
        attrs.removeAll(keys: [Array("class".utf8)])
        try assertMatches(doc, ".x", [])
        a.setValue(value: Array("y".utf8))
        XCTAssertEqual(other.get(key: "class"), "y")
        XCTAssertFalse(doc.isClassQueryIndexDirty)
        try assertMatches(doc, ".y", [])
    }

    func testCompactCallbackMutationIsObservedWithoutReturnedNewValue() throws {
        let doc = try SwiftSoup.parse("<p class='old'></p>")
        let p = try XCTUnwrap(doc.select("p").first())
        try assertMatches(doc, ".old", [p])
        p.getAttributes()!.compactAndMutate { a in
            a.setValue(value: Array("new".utf8))
            return AttributeMutation(keep: true)
        }
        try assertMatches(doc, ".old", [])
        try assertMatches(doc, ".new", [p])
    }

    func testCompactCallbackCanRetainLiveAttribute() throws {
        let doc = try SwiftSoup.parse("<p class='old'></p>")
        let p = try XCTUnwrap(doc.select("p").first())
        var saved: Attribute?
        p.getAttributes()!.compactAndMutate { a in
            saved = a
            return AttributeMutation(keep: true)
        }
        try assertMatches(doc, ".old", [p])
        saved?.setValue(value: Array("new".utf8))
        try assertMatches(doc, ".old", [])
        try assertMatches(doc, ".new", [p])
    }

    func testCompactValueMutationNotifiesSharedOwners() throws {
        let doc = try SwiftSoup.parse("<p class='old'></p><b></b>")
        let p = try XCTUnwrap(doc.select("p").first())
        let b = try XCTUnwrap(doc.select("b").first())
        b.getAttributes()!.addAll(incoming: p.getAttributes())
        try assertMatches(b, ".old", [b])
        p.getAttributes()!.compactAndMutate { _ in AttributeMutation(keep: true, newValue: Array("new".utf8)) }
        try assertMatches(b, ".old", [])
        try assertMatches(b, ".new", [b])
    }

    func testLowercaseAllKeysNotifiesSharedCollectionKeyCache() throws {
        let a = Attributes()
        try a.put("UPPER", "v")
        let b = Attributes()
        b.addAll(incoming: a)
        XCTAssertTrue(b.hasKey(key: "UPPER"))
        XCTAssertFalse(b.hasKey(key: "upper"))
        a.lowercaseAllKeys()
        XCTAssertFalse(b.hasKey(key: "UPPER"))
        XCTAssertEqual(b.get(key: "upper"), "v")
    }

    func testCloneAndCopyIsolateAttributeObjects() throws {
        let original = Attributes()
        try original.put("class", "old")
        for copy in [original.clone(), original.copy() as! Attributes] {
            let a = try attribute(original, "class")
            let b = try attribute(copy, "class")
            XCTAssertFalse(a === b)
            b.setValue(value: Array("new".utf8))
            try b.setKey(key: "ID")
            XCTAssertEqual(original.get(key: "class"), "old")
            XCTAssertFalse(original.hasKeyIgnoreCase(key: "id"))
        }
    }

    func testElementCloneMutationDoesNotLeakToOriginal() throws {
        let doc = try SwiftSoup.parse("<p class='old' data-v='before'></p>")
        let copy = doc.copy() as! Document
        let original = try XCTUnwrap(doc.select("p").first())
        let cloned = try XCTUnwrap(copy.select("p").first())
        try assertMatches(doc, ".old", [original])
        try assertMatches(copy, ".old", [cloned])
        try attribute(cloned.getAttributes()!, "class").setValue(value: Array("new".utf8))
        try assertMatches(doc, ".old", [original])
        try assertMatches(doc, ".new", [])
        try assertMatches(copy, ".new", [cloned])
    }

    func testBooleanCloneRetainsImplicitBooleanSerialization() throws {
        let a = try BooleanAttribute(key: Array("custom-flag".utf8))
        let b = a.clone()
        XCTAssertTrue(b is BooleanAttribute)
        XCTAssertEqual(a.html(), b.html())
        let attrs = Attributes()
        attrs.put(attribute: a)
        XCTAssertEqual(try attrs.html(), try attrs.clone().html())
    }

    func testCloneWithDeferredValueSlicesIsIndependent() throws {
        let attrs = Attributes()
        let a = try Attribute(key: "data-v", value: "one")
        attrs.put(attribute: a)
        a.appendValueSlice(ByteSlice.fromArray(Array("two".utf8)))
        let copy = attrs.clone()
        let b = try attribute(copy, "data-v")
        b.appendValueSlice(ByteSlice.fromArray(Array("three".utf8)))
        XCTAssertEqual(a.getValue(), "onetwo")
        XCTAssertEqual(b.getValue(), "onetwothree")
    }

    func testOwnerReferencesDoNotRetainDOMOrCollections() throws {
        var saved: Attribute?
        weak var weakDoc: Document?
        weak var weakAttrs: Attributes?
        do {
            let doc = try SwiftSoup.parse("<p class='old'></p>")
            let p = try XCTUnwrap(doc.select("p").first())
            let attrs = p.getAttributes()!
            weakDoc = doc
            weakAttrs = attrs
            saved = try attribute(attrs, "class")
            try assertMatches(doc, ".old", [p])
        }
        XCTAssertNil(weakDoc)
        XCTAssertNil(weakAttrs)
        saved?.setValue(value: Array("safe".utf8))
        XCTAssertEqual(saved?.getValue(), "safe")
    }

    func testRetainedCollectionDoesNotRetainOwningElements() throws {
        let attrs = Attributes()
        try attrs.put("class", "old")
        weak var first: Element?
        weak var second: Element?
        do {
            let a = Element(try Tag.valueOf("p"), "", attrs)
            let b = Element(try Tag.valueOf("b"), "", attrs)
            first = a; second = b
            try assertMatches(a, ".old", [a])
            try assertMatches(b, ".old", [b])
        }
        XCTAssertNil(first)
        XCTAssertNil(second)
        try attrs.put("class", "new")
        XCTAssertEqual(attrs.get(key: "class"), "new")
    }

    func testInvalidKeyMutationIsAtomic() throws {
        let attrs = Attributes()
        try attrs.put("valid", "v")
        let a = try attribute(attrs, "valid")
        for key in ["", " ", "\t\r\n"] {
            XCTAssertThrowsError(try a.setKey(key: key))
            XCTAssertEqual(a.getKey(), "valid")
            XCTAssertEqual(attrs.get(key: "valid"), "v")
            XCTAssertThrowsError(try Attribute(key: key, value: "v"))
        }
    }

    func testCaseVariantAttributeIndexesUseFirstMatchingValue() throws {
        let doc = try SwiftSoup.parse("<p></p>")
        let p = try XCTUnwrap(doc.select("p").first())
        let attrs = p.getAttributes()!
        try attrs.put("HREF", "first")
        try attrs.put("href", "second")
        XCTAssertEqual(try p.attr("href"), "first")
        try assertMatches(doc, "[href]", [p])
        try assertMatches(doc, "[href=first]", [p])
        try assertMatches(doc, "[href=second]", [])
        try attrs.remove(key: "HREF")
        try assertMatches(doc, "[href=first]", [])
        try assertMatches(doc, "[href=second]", [p])
    }

    func testRenameCollisionPreservesFirstMatchAtEveryIndexSize() throws {
        for padding in [0, 5, 20] {
            let doc = try SwiftSoup.parse("<p data-a='first' data-b='second'></p>")
            let p = try XCTUnwrap(doc.select("p").first())
            let attrs = p.getAttributes()!
            for i in 0..<padding { try attrs.put("padding-\(i)", "v") }
            let second = try attribute(attrs, "data-b")
            try second.setKey(key: "data-a")
            XCTAssertEqual(attrs.get(key: "data-a"), "first")
            XCTAssertEqual(try attrs.getIgnoreCase(key: "DATA-A"), "first")
            try assertMatches(doc, "[data-a]", [p])
            try assertMatches(doc, "[data-a=first]", [p])
            try assertMatches(doc, "[data-a=second]", [])
        }
    }

    func testReparentedOwnerInvalidatesDestinationNotOldTree() throws {
        let a = try SwiftSoup.parse("<p class='old'></p>")
        let b = try SwiftSoup.parse("<main></main>")
        let p = try XCTUnwrap(a.select("p").first())
        let saved = try attribute(p.getAttributes()!, "class")
        try b.body()!.appendChild(p)
        try assertMatches(a, ".old", [])
        try assertMatches(b, ".old", [p])
        saved.setValue(value: Array("new".utf8))
        XCTAssertFalse(a.isClassQueryIndexDirty)
        try assertMatches(b, ".old", [])
        try assertMatches(b, ".new", [p])
    }

    func testManySharedOwnersAndRemovalOrders() throws {
        let shared = try Attribute(key: "class", value: "old")
        let owners = try (0..<24).map { _ -> Element in
            let p = Element(try Tag.valueOf("p"), "")
            p.getAttributes()!.put(attribute: shared)
            return p
        }
        for p in owners { try assertMatches(p, ".old", [p]) }
        for (i, p) in owners.enumerated() where i % 3 == 0 { try p.removeAttr("class") }
        shared.setValue(value: Array("new".utf8))
        for (i, p) in owners.enumerated() {
            try assertMatches(p, ".old", [])
            try assertMatches(p, ".new", i % 3 == 0 ? [] : [p])
        }
    }
}
