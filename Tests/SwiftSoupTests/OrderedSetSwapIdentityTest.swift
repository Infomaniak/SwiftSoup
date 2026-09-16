import XCTest
import SwiftSoup

final class OrderedSetSwapIdentityTest: XCTestCase {
    private final class Item: Hashable {
        let key: Int
        let payload: String
        init(_ key: Int, _ payload: String = "stored") { self.key = key; self.payload = payload }
        static func == (lhs: Item, rhs: Item) -> Bool { lhs.key == rhs.key }
        func hash(into hasher: inout Hasher) { hasher.combine(0) }
    }

    private func check(_ set: OrderedSet<Int>, _ expected: [Int],
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Array(set), expected, file: file, line: line)
        XCTAssertEqual(set.count, expected.count, file: file, line: line)
        for (index, value) in expected.enumerated() {
            XCTAssertEqual(set.index(of: value), index, file: file, line: line)
        }
    }

    func testEqualLookupArgumentsDoNotReplaceStoredRepresentatives() {
        let a = Item(1), b = Item(2), c = Item(3)
        let set = OrderedSet(sequence: [a, b, c])
        set.swapObject(Item(1, "lookup-a"), with: Item(3, "lookup-c"))
        XCTAssertEqual(set.map(ObjectIdentifier.init), [c, b, a].map(ObjectIdentifier.init))
        XCTAssertTrue(set[0] === c)
        XCTAssertTrue(set[2] === a)
        for (index, item) in [c, b, a].enumerated() {
            XCTAssertEqual(set.index(of: Item(item.key)), index)
        }
    }

    func testEqualKeySelfSwapIsAnIdentityPreservingNoOp() {
        let stored = Item(1)
        let set = OrderedSet(sequence: [stored])
        set.swapObject(Item(1, "left lookup"), with: Item(1, "right lookup"))
        XCTAssertTrue(set.first === stored)
        XCTAssertEqual(set.count, 1)
        XCTAssertEqual(set.index(of: stored), 0)
    }

    func testTemporaryLookupArgumentsAreNotRetainedBySwapping() {
        let set = OrderedSet(sequence: [Item(1), Item(2)])
        weak var firstLookup: Item?
        weak var secondLookup: Item?
        do {
            let a = Item(1, "temporary-a"), b = Item(2, "temporary-b")
            firstLookup = a; secondLookup = b
            set.swapObject(a, with: b)
        }
        XCTAssertNil(firstLookup)
        XCTAssertNil(secondLookup)
        XCTAssertEqual(set.map(\.payload), ["stored", "stored"])
    }

    func testCanonicalEquivalentLookupPreservesStoredStringBytes() {
        let stored = "caf\u{E9}", lookup = "cafe\u{301}"
        XCTAssertEqual(stored, lookup)
        XCTAssertNotEqual(Array(stored.utf8), Array(lookup.utf8))
        let set = OrderedSet(sequence: [stored, "日本"])
        set.swapObject(lookup, with: "日本")
        XCTAssertEqual(set.map { Array($0.utf8) }, [Array("日本".utf8), Array(stored.utf8)])
        set.swapObject(lookup, with: stored)
        XCTAssertEqual(set.map { Array($0.utf8) }, [Array("日本".utf8), Array(stored.utf8)])
    }

    func testEveryPairIncludingSelfAndMissingKeysPreservesIndices() {
        for width in 0...32 {
            for a in -1...width {
                for b in -1...width {
                    let set = OrderedSet(sequence: 0..<width)
                    var expected = Array(0..<width)
                    if a >= 0, a < width, b >= 0, b < width { expected.swapAt(a, b) }
                    set.swapObject(a, with: b)
                    check(set, expected)
                    set.swapObject(a, with: b)
                    check(set, Array(0..<width))
                }
            }
        }
    }

    func testSnapshotIteratorAndDeliberateHashCollisions() {
        let values = (0..<48).map { Item($0) }
        let set = OrderedSet(sequence: values)
        var snapshot = set.makeIterator()
        var expected = values
        for i in 0..<192 {
            let a = (i * 7) % 48, b = (i * 11 + 3) % 48
            set.swapObject(expected[a], with: expected[b])
            expected.swapAt(a, b)
            XCTAssertEqual(set.map(ObjectIdentifier.init), expected.map(ObjectIdentifier.init))
            for (index, item) in expected.enumerated() { XCTAssertEqual(set.index(of: item), index) }
        }
        for item in values { XCTAssertTrue(snapshot.next() === item) }
        XCTAssertNil(snapshot.next())
    }

    func testMissingObjectDoesNotReplaceAnEqualPresentRepresentative() {
        let stored = Item(1)
        let set = OrderedSet(sequence: [stored])
        set.swapObject(Item(1, "lookup"), with: Item(2))
        set.swapObject(Item(2), with: Item(1, "lookup"))
        XCTAssertTrue(set.first === stored)
        XCTAssertEqual(set.count, 1)
        XCTAssertNil(set.index(of: Item(2)))
    }

    func testSwapsComposeWithAppendReplacementRemovalInsertionAndMoves() {
        let set = OrderedSet<Int>()
        var expected: [Int] = []
        var state: UInt64 = 0x9B05_20260909
        func next(_ limit: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(limit))
        }
        for _ in 0..<2048 {
            let a = next(64), b = next(64)
            switch next(5) {
            case 0:
                set.append(a)
                if !expected.contains(a) { expected.append(a) }
            case 1:
                set.remove(a); expected.removeAll { $0 == a }
            case 2:
                let gap = next(expected.count + 1)
                set.insert(a, at: gap)
                if !expected.contains(a) { expected.insert(a, at: gap) }
            case 3:
                if !expected.isEmpty {
                    let destination = next(expected.count)
                    set.moveObject(a, toIndex: destination)
                    if let index = expected.firstIndex(of: a) {
                        expected.insert(expected.remove(at: index), at: destination)
                    }
                }
            default:
                set.swapObject(a, with: b)
                if let first = expected.firstIndex(of: a), let second = expected.firstIndex(of: b) {
                    expected.swapAt(first, second)
                }
            }
            check(set, expected)
        }
        let original = Item(1), replacement = Item(1, "replacement"), other = Item(2)
        let objects = OrderedSet(sequence: [original, other])
        objects.append(replacement) // Append intentionally replaces equal representatives.
        objects.swapObject(replacement, with: other)
        XCTAssertTrue(objects[1] === replacement)
        objects.remove(Item(1))
        XCTAssertEqual(objects.count, 1)
        XCTAssertTrue(objects[0] === other)
    }
}
