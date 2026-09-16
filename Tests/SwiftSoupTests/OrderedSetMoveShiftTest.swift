import XCTest
import SwiftSoup

final class OrderedSetMoveShiftTest: XCTestCase {
    private final class Item: Hashable {
        let key: Int
        let payload: String
        init(_ key: Int, _ payload: String = "original") { self.key = key; self.payload = payload }
        static func == (lhs: Item, rhs: Item) -> Bool { lhs.key == rhs.key }
        func hash(into hasher: inout Hasher) { hasher.combine(0) }
    }
    private func check(_ set: OrderedSet<Int>, _ expected: [Int], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Array(set), expected, file: file, line: line)
        XCTAssertEqual(set.count, expected.count, file: file, line: line)
        for (index, value) in expected.enumerated() { XCTAssertEqual(set.index(of: value), index, file: file, line: line) }
    }

    func testEverySourceDestinationAndBothPublicOverloads() {
        for width in 1...48 {
            for source in 0..<width {
                for destination in 0..<width {
                    var expected = Array(0..<width)
                    let stored = expected.remove(at: source)
                    expected.insert(stored, at: destination)
                    let first = OrderedSet(sequence: 0..<width)
                    first.moveObject(source, toIndex: destination)
                    check(first, expected)
                    let second = OrderedSet(sequence: 0..<width)
                    second.moveObject(at: source, to: destination)
                    check(second, expected)
                }
            }
        }
    }

    func testEqualArgumentDoesNotReplaceStoredRepresentativeOrStayRetained() {
        let values = (0..<24).map { Item($0) }
        let set = OrderedSet(sequence: values)
        weak var supplied: Item?
        do {
            let duplicate = Item(7, "must not replace")
            supplied = duplicate
            set.moveObject(duplicate, toIndex: 0)
            XCTAssertTrue(set[0] === values[7])
            set.moveObject(duplicate, toIndex: 23)
            XCTAssertTrue(set[23] === values[7])
        }
        XCTAssertNil(supplied)
        XCTAssertEqual(set.map(\.payload), Array(repeating: "original", count: 24))
        set.remove(values[7])
        XCTAssertNil(set.index(of: values[7]))
        XCTAssertEqual(set.map(\.key), (0..<24).filter { $0 != 7 })
    }

    func testSnapshotIteratorsAndHashCollisionsSurviveMoves() {
        let values = (0..<64).map { Item($0) }
        let set = OrderedSet(sequence: values)
        var snapshot = set.makeIterator()
        var expected = values
        for i in 0..<256 {
            let from = (i * 13) % 64, to = (i * 29 + 3) % 64
            let item = expected.remove(at: from)
            expected.insert(item, at: to)
            set.moveObject(item, toIndex: to)
            XCTAssertEqual(set.map(ObjectIdentifier.init), expected.map(ObjectIdentifier.init))
            for (index, value) in expected.enumerated() { XCTAssertEqual(set.index(of: value), index) }
        }
        for value in values { XCTAssertTrue(snapshot.next() === value) }
        XCTAssertNil(snapshot.next())
    }

    func testAbsentAndSamePositionMovesAreNoOps() {
        for width in [1, 2, 16, 512] {
            let set = OrderedSet(sequence: 0..<width)
            for index in 0..<width {
                set.moveObject(-1, toIndex: index)
                set.moveObject(index, toIndex: index)
                set.moveObject(at: index, to: index)
            }
            check(set, Array(0..<width))
        }
    }

    func testSeededInterleavedMovesAndCollectionEdits() {
        let set = OrderedSet(sequence: 0..<40)
        var expected = Array(0..<40)
        var seed: UInt64 = 0xE975_20260909
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % UInt64(n)) }
        for _ in 0..<2048 {
            let value = next(96)
            switch next(5) {
            case 0:
                set.append(value)
                if !expected.contains(value) { expected.append(value) }
            case 1:
                set.remove(value)
                expected.removeAll { $0 == value }
            case 2:
                let gap = next(expected.count + 1)
                set.insert(value, at: gap)
                if !expected.contains(value) { expected.insert(value, at: gap) }
            default:
                if !expected.isEmpty {
                    let to = next(expected.count)
                    set.moveObject(value, toIndex: to)
                    if let from = expected.firstIndex(of: value) {
                        expected.insert(expected.remove(at: from), at: to)
                    }
                }
            }
            check(set, expected)
        }
    }

    func testElementIdentityAndDOMAreIndependentOfCollectionMoves() throws {
        let doc = try SwiftSoup.parse("<main><i id=a>A</i><b id=b>B</b><em id=c>C</em></main>")
        let elements = try doc.select("main > *").array()
        let set = OrderedSet(sequence: elements)
        let before = try doc.outerHtml()
        set.moveObject(elements[2], toIndex: 0)
        XCTAssertEqual(set.map { $0.id() }, ["c", "a", "b"])
        try elements[2].tagName("section")
        set.moveObject(elements[2], toIndex: 2)
        XCTAssertEqual(set.map(ObjectIdentifier.init), elements.map(ObjectIdentifier.init))
        try elements[2].tagName("em")
        XCTAssertEqual(try doc.outerHtml(), before)
        for (index, element) in elements.enumerated() { XCTAssertEqual(set.index(of: element), index) }
    }
}
