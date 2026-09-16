import XCTest
@testable import SwiftSoup

final class DeferredAttributeModelTest: XCTestCase {
    private struct Generator {
        var state: UInt64
        mutating func next(_ limit: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(limit))
        }
    }

    private func makePending(_ key: String, _ value: String, _ variant: Int) -> Attributes.PendingAttribute {
        let bytes = Array(key.utf8)
        let slice = ByteSlice.fromArray(bytes)
        let payload = Array(value.utf8)
        let pendingValue: Attributes.PendingAttrValue
        switch variant % 5 {
        case 0: pendingValue = .none
        case 1: pendingValue = .empty
        case 2: pendingValue = .bytes(payload)
        case 3: pendingValue = .slice(ByteSlice.fromArray(payload))
        default:
            let middle = payload.count / 2
            pendingValue = .slices([
                ByteSlice.fromArray(Array(payload[..<middle])),
                ByteSlice.fromArray(Array(payload[middle...]))
            ], payload.count)
        }
        return Attributes.PendingAttribute(
            nameSlice: variant % 2 == 0 ? slice : nil,
            nameBytes: variant % 2 == 0 ? nil : bytes,
            hasUppercase: Attributes.containsAsciiUppercase(bytes), value: pendingValue
        )
    }

    func testSeededDeferredMapsMatchEagerPublicWritesAcrossReadOrders() throws {
        let keys = ["A", "a", "class", "Class", "id", "id ", " title ", "data-v", "\t", "", "日本", "é", "x", "y", "z"]
        for seed in 0..<256 {
            var random = Generator(state: UInt64(seed + 1))
            var items: [Attributes.PendingAttribute] = []
            let reference = Attributes()
            let length = [0, 1, 3, 4, 5, 16, 65, 129][seed % 8]
            for offset in 0..<length {
                let key = keys[random.next(keys.count)]
                let value = "value-\(offset)-日本&<"
                let variant = random.next(10)
                items.append(makePending(key, value, variant))
                if variant % 5 == 0 {
                    try? reference.put(attribute: BooleanAttribute(key: Array(key.utf8)))
                } else {
                    try? reference.put(key, variant % 5 == 1 ? "" : value)
                }
            }
            let actual = Attributes(pendingAttributes: items)
            for index in 0..<keys.count {
                let key = keys[(index + seed) % keys.count]
                switch index % 4 {
                case 0:
                    XCTAssertEqual(actual.get(key: key), reference.get(key: key), "seed \(seed), \(key)")
                case 1:
                    XCTAssertEqual(actual.hasKey(key: key), reference.hasKey(key: key), "seed \(seed), \(key)")
                case 2:
                    XCTAssertEqual(actual.hasKeyIgnoreCase(key: Array(key.utf8)), reference.hasKeyIgnoreCase(key: Array(key.utf8)), "seed \(seed), \(key)")
                default:
                    if key.isEmpty {
                        XCTAssertThrowsError(try actual.getIgnoreCase(key: key))
                    } else {
                        XCTAssertEqual(try actual.getIgnoreCase(key: key), try reference.getIgnoreCase(key: key), "seed \(seed), \(key)")
                    }
                }
            }
            for syntax in [OutputSettings.Syntax.html, .xml] {
                let settings = OutputSettings().syntax(syntax: syntax)
                let lhs = StringBuilder()
                let rhs = StringBuilder()
                try actual.html(accum: lhs, out: settings)
                try reference.html(accum: rhs, out: settings)
                XCTAssertEqual(lhs.toString(), rhs.toString(), "seed \(seed), \(syntax)")
            }
            XCTAssertEqual(actual.asList().map { $0.getKey() }, reference.asList().map { $0.getKey() }, "seed \(seed)")
            XCTAssertEqual(actual.asList().map { $0.getValue() }, reference.asList().map { $0.getValue() }, "seed \(seed)")
        }
    }

    func testAlternatingDeferredReadsAndWritesMatchEagerMap() throws {
        let actual = Attributes()
        let reference = Attributes()
        for index in 0..<192 {
            let key = ["A", "a", "id", "class", " title ", "data-v", "\t"][index % 7]
            let value = "v\(index)"
            let item = makePending(key, value, 2 + (index % 3))
            actual.appendPending(item)
            try? reference.put(key, value)
            for query in ["A", "a", "id", "class", "title", "data-v"] {
                XCTAssertEqual(actual.get(key: query), reference.get(key: query))
                XCTAssertEqual(try actual.getIgnoreCase(key: query), try reference.getIgnoreCase(key: query))
            }
            if index % 11 == 0 { _ = actual.clone() }
            if index % 19 == 0 {
                try actual.remove(key: "id")
                try reference.remove(key: "id")
            }
            XCTAssertEqual(try actual.html(), try reference.html())
        }
    }

    func testNameBytesTakePrecedenceOverAnObsoleteNameSlice() throws {
        let attributes = Attributes(pendingAttributes: [Attributes.PendingAttribute(
            nameSlice: ByteSlice.fromArray(Array("obsolete".utf8)), nameBytes: Array(" current ".utf8),
            hasUppercase: false, value: .bytes(Array("value".utf8))
        )])
        XCTAssertEqual(try attributes.html(), " current=\"value\"")
        XCTAssertEqual(attributes.get(key: "current"), "value")
        XCTAssertEqual(attributes.asList().map { $0.getKey() }, ["current"])
    }

    func testEveryLookupIsAlsoCheckedAsTheFirstRead() throws {
        let keys = ["A", "a", "id", "class", " title ", "title", "missing", " \t"]
        for seed in 0..<128 {
            var random = Generator(state: UInt64(seed + 1000))
            var items: [Attributes.PendingAttribute] = []
            let reference = Attributes()
            for offset in 0..<(1 + seed % 33) {
                let key = keys[random.next(keys.count - 1)]
                let variant = random.next(10)
                let value = "v\(offset)日本&"
                items.append(makePending(key, value, variant))
                if variant % 5 == 0 {
                    try? reference.put(attribute: BooleanAttribute(key: Array(key.utf8)))
                } else {
                    try? reference.put(key, variant % 5 == 1 ? "" : value)
                }
            }
            for key in keys {
                for operation in 0..<6 {
                    let actual = Attributes(pendingAttributes: items)
                    let bytes = Array(key.utf8)
                    let message = "seed \(seed), first operation \(operation), key \(key)"
                    switch operation {
                    case 0:
                        XCTAssertEqual(actual.get(key: key), reference.get(key: key), message)
                    case 1:
                        XCTAssertEqual(try actual.getIgnoreCase(key: key), try reference.getIgnoreCase(key: key), message)
                    case 2:
                        XCTAssertEqual(actual.hasKey(key: bytes), reference.hasKey(key: bytes), message)
                    case 3:
                        XCTAssertEqual(actual.hasKeyIgnoreCase(key: ArraySlice(bytes)), reference.hasKeyIgnoreCase(key: ArraySlice(bytes)), message)
                    case 4:
                        XCTAssertEqual(try actual.getIgnoreCaseSlice(key: bytes), try reference.getIgnoreCaseSlice(key: bytes), message)
                    default:
                        XCTAssertEqual(actual.valueSliceCaseSensitive(bytes), reference.valueSliceCaseSensitive(bytes), message)
                    }
                }
            }
        }
    }

    func testCanonicalizationRetainsValueSlicesAndDoesNotAlterTheInputSnapshot() throws {
        let first = ByteSlice.fromArray(Array("first".utf8))
        let last = ByteSlice.fromArray(Array("日本語".utf8))
        let key = ByteSlice.fromArray(Array("title".utf8))
        let input = [
            Attributes.PendingAttribute(nameSlice: key, nameBytes: nil, hasUppercase: false, value: .slice(first)),
            Attributes.PendingAttribute(nameSlice: key, nameBytes: nil, hasUppercase: false, value: .slice(last))
        ]
        let attributes = Attributes(pendingAttributes: input)
        XCTAssertEqual(try attributes.getIgnoreCaseSlice(key: Array("title".utf8)), last)
        XCTAssertEqual(attributes.size(), 1)
        let retained = try attributes.getIgnoreCaseSlice(key: Array("title".utf8))
        XCTAssertTrue(retained.storage === last.storage)
        XCTAssertEqual(input.count, 2)
        guard case let .slice(original) = input[0].value else { return XCTFail("Original slice missing") }
        XCTAssertTrue(original.storage === first.storage)
    }
}
