import XCTest
import SwiftSoup

final class OrderedSetInsertionTest: XCTestCase {
    private final class Item: Hashable {
        let key: Int
        let payload: String
        init(_ key: Int, _ payload: String = "original") { self.key = key; self.payload = payload }
        static func == (lhs: Item, rhs: Item) -> Bool { lhs.key == rhs.key }
        func hash(into hasher: inout Hasher) { hasher.combine(0) }
    }

    private func check(_ set: OrderedSet<Int>, _ expected: [Int],
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Array(set), expected, file: file, line: line)
        XCTAssertEqual(set.count, expected.count, file: file, line: line)
        for (i, value) in expected.enumerated() {
            XCTAssertEqual(set.index(of: value), i, file: file, line: line)
        }
    }

    func testEveryGapAndExistingValueAtSmallWidths() {
        for width in 0...48 {
            for gap in 0...width {
                for value in -1..<width {
                    let set = OrderedSet(sequence: Array(0..<width))
                    var expected = Array(0..<width)
                    if value == -1 { expected.insert(value, at: gap) }
                    set.insert(value, at: gap)
                    check(set, expected)
                }
            }
        }
    }

    func testEqualIncomingReferenceDoesNotReplaceExistingRepresentative() {
        let original = Item(7)
        let set = OrderedSet(sequence: [Item(0), original, Item(9)])
        weak var incoming: Item?
        do {
            let duplicate = Item(7, "duplicate")
            incoming = duplicate
            for gap in 0...set.count { set.insert(duplicate, at: gap) }
        }
        XCTAssertNil(incoming)
        XCTAssertTrue(set[1] === original)
        XCTAssertEqual(set.map(\.key), [0, 7, 9])
        set.remove(original)
        XCTAssertNil(set.index(of: original))
    }

    func testCollisionsAndSavedIteratorsPreserveReferences() {
        let original = (0..<64).map { Item($0) }
        let set = OrderedSet(sequence: original)
        var iterator = set.makeIterator()
        var expected = original
        for i in 64..<160 {
            let item = Item(i)
            let gap = (i * 13) % (expected.count + 1)
            set.insert(item, at: gap)
            expected.insert(item, at: gap)
            XCTAssertEqual(set.map(ObjectIdentifier.init), expected.map(ObjectIdentifier.init))
            for (index, value) in expected.enumerated() { XCTAssertEqual(set.index(of: value), index) }
        }
        for item in original { XCTAssertTrue(iterator.next() === item) }
        XCTAssertNil(iterator.next())
    }

    func testSeededInsertRemoveMoveAndReplaceAgainstArrayModel() {
        let set = OrderedSet<Int>()
        var expected: [Int] = []
        var seed: UInt64 = 0x778_2026
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1
            return Int((seed >> 32) % UInt64(n))
        }
        for _ in 0..<2048 {
            let value = next(96)
            switch next(4) {
            case 0, 1:
                let gap = next(expected.count + 1)
                set.insert(value, at: gap)
                if !expected.contains(value) { expected.insert(value, at: gap) }
            case 2:
                set.remove(value)
                expected.removeAll { $0 == value }
            default:
                if !expected.isEmpty {
                    let gap = next(expected.count)
                    set.moveObject(value, toIndex: gap)
                    if let old = expected.firstIndex(of: value) {
                        let stored = expected.remove(at: old)
                        expected.insert(stored, at: gap)
                    }
                }
            }
            check(set, expected)
        }
    }

    func testSequenceInsertionAndSubscriptUpdatesAfterSingleInsertion() {
        let set = OrderedSet(sequence: [1, 2, 3])
        set.insert(4, at: 1)
        set.insert([5, 4, 6, 5], at: 2)
        check(set, [1, 4, 5, 6, 2, 3])
        set[2] = 3
        check(set, [1, 4, 6, 2, 3])
        set[1] = 8
        check(set, [1, 8, 6, 2, 3])
        set.moveObject(at: 0, to: 4)
        check(set, [8, 6, 2, 3, 1])
        set.remove(set)
        set.insert(10, at: 0)
        check(set, [10])
    }

    func testDOMIdentitySurvivesInsertionAndTagMutation() throws {
        let nodes = try (0..<80).map { _ in try Element(Tag.valueOf("p"), "") }
        let set = OrderedSet<Element>()
        for element in nodes { set.insert(element, at: set.count / 2) }
        XCTAssertEqual(set.count, 80)
        for (i, element) in set.enumerated() {
            try element.tagName(i % 2 == 0 ? "span" : "div")
            XCTAssertEqual(set.index(of: element), i)
        }
        for element in nodes { set.remove(element) }
        XCTAssertTrue(set.isEmpty)
    }
}
