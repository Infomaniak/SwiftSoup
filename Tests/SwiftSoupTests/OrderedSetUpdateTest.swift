import XCTest
import SwiftSoup

final class OrderedSetUpdateTest: XCTestCase {
    private final class Item: Hashable {
        let key: Int
        let value: String
        init(_ key: Int, _ value: String) { self.key = key; self.value = value }
        static func == (lhs: Item, rhs: Item) -> Bool { lhs.key == rhs.key }
        func hash(into hasher: inout Hasher) { hasher.combine(0) } // Deliberate collisions.
    }

    private func assertContents(_ set: OrderedSet<Int>, _ expected: [Int],
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Array(set), expected, file: file, line: line)
        XCTAssertEqual(set.count, expected.count, file: file, line: line)
        for (index, value) in expected.enumerated() {
            XCTAssertEqual(set.index(of: value), index, file: file, line: line)
        }
    }

    func testDuplicateAppendKeepsPositions() {
        let set = OrderedSet(sequence: [1, 2, 3, 4])
        set.append(contentsOf: [4, 2, 1, 3, 2, 4])
        assertContents(set, [1, 2, 3, 4])
        set.append(5)
        assertContents(set, [1, 2, 3, 4, 5])
    }

    func testEqualIncomingInstanceReplacesBothStoredRepresentatives() {
        let set = OrderedSet<Item>()
        weak var old: Item?
        do {
            let original = Item(1, "old")
            old = original
            set.append(original)
        }
        let incoming = Item(1, "new")
        set.append(incoming)
        XCTAssertNil(old)
        XCTAssertEqual(set.count, 1)
        XCTAssertTrue(set[0] === incoming)
        XCTAssertEqual(set.index(of: Item(1, "lookup")), 0)
        set.remove(Item(1, "remove"))
        XCTAssertTrue(set.isEmpty)
    }

    func testCollidingKeysKeepOrderAndLatestValue() {
        let set = OrderedSet<Item>()
        for i in 0..<32 { set.append(Item(i, "old")) }
        for i in (0..<32).reversed() { set.append(Item(i, "new")) }
        XCTAssertEqual(set.map(\.key), Array(0..<32))
        XCTAssertTrue(set.allSatisfy { $0.value == "new" })
        for i in stride(from: 0, to: 32, by: 2) { set.remove(Item(i, "remove")) }
        XCTAssertEqual(set.map(\.key), Array(stride(from: 1, to: 32, by: 2)))
        for (index, item) in set.enumerated() { XCTAssertEqual(set.index(of: item), index) }
    }

    func testRemovalOnlyShiftsFollowingPositions() {
        let set = OrderedSet(sequence: [0, 1, 2, 3, 4, 5])
        set.remove(0)
        assertContents(set, [1, 2, 3, 4, 5])
        set.remove(3)
        assertContents(set, [1, 2, 4, 5])
        set.remove(5)
        set.remove(99)
        assertContents(set, [1, 2, 4])
        set.remove(set)
        assertContents(set, [])
        set.append(7)
        assertContents(set, [7])
    }

    func testIteratorSnapshotSurvivesUpdates() {
        let old = Item(1, "old")
        let set = OrderedSet(sequence: [old, Item(2, "second")])
        var iterator = set.makeIterator()
        let replacement = Item(1, "replacement")
        set.append(replacement)
        set.remove(Item(2, "lookup"))
        XCTAssertTrue(iterator.next() === old)
        XCTAssertEqual(iterator.next()?.key, 2)
        XCTAssertNil(iterator.next())
        XCTAssertTrue(set.first === replacement)
    }

    func testMixedUpdatesMatchArrayReference() {
        let set = OrderedSet<Int>()
        var expected: [Int] = []
        var state: UInt64 = 90207
        func next(_ upperBound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(upperBound))
        }
        for _ in 0..<1000 {
            let value = next(40)
            switch next(6) {
            case 0:
                set.append(value)
                if !expected.contains(value) { expected.append(value) }
            case 1:
                set.remove(value)
                expected.removeAll { $0 == value }
            case 2:
                let index = next(expected.count + 1)
                set.insert(value, at: index)
                if !expected.contains(value) { expected.insert(value, at: index) }
            case 3 where !expected.isEmpty:
                let index = next(expected.count)
                set[index] = value
                if expected[index] != value {
                    if expected.contains(value) { expected.remove(at: index) }
                    else { expected[index] = value }
                }
            case 4 where !expected.isEmpty:
                let index = next(expected.count)
                set.moveObject(value, toIndex: index)
                if let oldIndex = expected.firstIndex(of: value) {
                    expected.remove(at: oldIndex)
                    expected.insert(value, at: index)
                }
            default:
                let other = next(40)
                set.swapObject(value, with: other)
                if let first = expected.firstIndex(of: value), let second = expected.firstIndex(of: other) {
                    expected.swapAt(first, second)
                }
            }
            assertContents(set, expected)
        }
    }
}
