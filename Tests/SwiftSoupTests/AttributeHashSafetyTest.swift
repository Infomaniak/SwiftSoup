import XCTest
@testable import SwiftSoup

final class AttributeHashSafetyTest: XCTestCase {
    func testHashMixingWrapsRatherThanTrappingOnOverflow() throws {
        // Select against this process's randomized hash seed, not a fixed hash value.
        let attribute = try XCTUnwrap((0..<256).lazy.compactMap { index -> Attribute? in
            let candidate = try? Attribute(key: "key-\(index)", value: "value")
            guard let candidate,
                  candidate.keySlice.hashValue.multipliedReportingOverflow(by: 31).overflow else { return nil }
            return candidate
        }.first)
        let expected = (attribute.keySlice.hashValue &* 31) &+ attribute.valueSliceMaterialized().hashValue
        XCTAssertEqual(attribute.hashCode(), expected)
    }

    func testEqualAndClonedAttributesHaveEqualHashesAfterEdits() throws {
        let first = try Attribute(key: "data-x", value: "日本語")
        let second = first.clone()
        XCTAssertEqual(first.hashCode(), second.hashCode())
        first.setValue(value: Array("changed".utf8))
        second.setValue(value: Array("changed".utf8))
        try first.setKey(key: "renamed")
        try second.setKey(key: "renamed")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.hashCode(), second.hashCode())
    }

    func testFragmentedValueHashingDoesNotNotifyOwners() throws {
        let doc = try SwiftSoup.parse("<p data-v='a'></p>")
        let p = try XCTUnwrap(doc.body()?.child(0))
        let attribute = try XCTUnwrap(p.getAttributes()?.asList().first)
        attribute.appendValueSlice(ByteSlice.fromArray(Array("日本語".utf8)))
        let expected = try Attribute(key: "data-v", value: "a日本語")
        let version = doc.textMutationVersion
        let dirty = p.sourceRangeDirty
        XCTAssertEqual(attribute.hashCode(), expected.hashCode())
        XCTAssertEqual(doc.textMutationVersion, version)
        XCTAssertEqual(p.sourceRangeDirty, dirty)
    }
}
