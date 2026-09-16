import XCTest
@testable import SwiftSoup

final class AttributeHashCodeTest: XCTestCase {
    func testHashCodeWrapsIntegerOverflowInsteadOfTrapping() throws {
        // Find a witness using checked reporting, so this reproduces under any
        // process hash seed without hard-coding a platform-dependent hash value.
        let witness = try XCTUnwrap((0..<1024).lazy.map { ByteSlice.fromArray(Array("key-\($0)".utf8)) }
            .first { $0.hashValue.multipliedReportingOverflow(by: 31).overflow })
        let attribute = try Attribute(keySlice: witness, valueSlice: ByteSlice.fromArray(Array("value".utf8)))
        let expected = (31 &* witness.hashValue) &+ attribute.valueSliceMaterialized().hashValue
        XCTAssertEqual(attribute.hashCode(), expected)
        XCTAssertEqual(attribute.hashCode(), attribute.clone().hashCode())
    }

    func testEqualFragmentedAndContiguousAttributesHaveEqualHashes() throws {
        let first = try Attribute(key: "日本語", value: "one")
        first.appendValueSlice(ByteSlice.fromArray(Array("&two".utf8)))
        let second = try Attribute(key: "日本語", value: "one&two")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.hashCode(), second.hashCode())
        _ = first.getValueUTF8()
        XCTAssertEqual(first.hashCode(), second.hashCode())
        first.setValue(value: Array("changed".utf8))
        second.setValue(value: Array("changed".utf8))
        XCTAssertEqual(first.hashCode(), second.hashCode())
    }

    func testBooleanAndPlainEmptyAttributesRespectEquality() throws {
        let boolean = try BooleanAttribute(key: Array("custom".utf8))
        let plain = try Attribute(key: "custom", value: "")
        XCTAssertEqual(boolean, plain)
        XCTAssertEqual(boolean.hashCode(), plain.hashCode())
    }
}
