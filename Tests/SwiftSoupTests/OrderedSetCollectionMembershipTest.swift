import XCTest
import SwiftSoup

final class OrderedSetCollectionMembershipTest: XCTestCase {
    private final class OneShot<T>: Sequence {
        let values: [T]
        var iteratorRequests = 0
        var nextCalls = 0
        init(_ values: [T]) { self.values = values }
        func makeIterator() -> AnyIterator<T> {
            iteratorRequests += 1
            guard iteratorRequests == 1 else { return AnyIterator { nil } }
            var position = 0
            return AnyIterator {
                self.nextCalls += 1
                guard position < self.values.count else { return nil }
                defer { position += 1 }
                return self.values[position]
            }
        }
    }

    // All iterators deliberately share their traversal state, as a stream does.
    private final class SharedStream: Sequence {
        var position = 0
        var iteratorRequests = 0
        let values: [Int]
        init(_ values: [Int]) { self.values = values }
        func makeIterator() -> AnyIterator<Int> {
            iteratorRequests += 1
            return AnyIterator {
                guard self.position < self.values.count else { return nil }
                defer { self.position += 1 }
                return self.values[self.position]
            }
        }
    }

    private final class MembershipCollection: Collection {
        typealias Index = Int
        var membershipCalls = 0
        var elementReads = 0
        let values = [1, 2, 3]
        var startIndex: Int { 0 }
        var endIndex: Int { values.count }
        func index(after i: Int) -> Int { i + 1 }
        subscript(i: Int) -> Int { elementReads += 1; return values[i] }
        func _customContainsEquatableElement(_ element: Int) -> Bool? {
            membershipCalls += 1
            return values.contains(element)
        }
    }

    func testOneShotSequenceIsNotRestarted() {
        let receiver = OrderedSet<Int>(sequence: [1, 2])
        for values in [[1, 2], [2, 1], [7, 1, 1, 2, 8]] {
            let input = OneShot(values)
            XCTAssertTrue(receiver.isSubset(of: input))
            XCTAssertEqual(input.iteratorRequests, 1)
            XCTAssertEqual(Array(receiver), [1, 2])
        }
    }

    func testSharedStateAndTypeErasedSequences() {
        for values in [[1, 2], [2, 1]] {
            let stream = SharedStream(values)
            let receiver = OrderedSet<Int>(sequence: [1, 2])
            XCTAssertTrue(receiver.isSubset(of: AnySequence(stream)))
            XCTAssertEqual(stream.iteratorRequests, 1)
            XCTAssertEqual(stream.position, 2)
        }
        let receiver = OrderedSet<Int>(sequence: [1, 2, 3])
        XCTAssertTrue(receiver.isSubset(of: receiver))
    }

    func testEmptyAndSingletonKeepTheirConsumptionBehavior() {
        let unused = OneShot([1, 2])
        XCTAssertTrue(OrderedSet<Int>().isSubset(of: unused))
        XCTAssertEqual(unused.iteratorRequests, 0)
        XCTAssertEqual(unused.nextCalls, 0)
        let singleton = OneShot([1, 2, 3])
        XCTAssertTrue(OrderedSet<Int>(sequence: [2]).isSubset(of: singleton))
        XCTAssertEqual(singleton.iteratorRequests, 1)
        XCTAssertEqual(singleton.nextCalls, 2)
    }

    func testStopsWhenSatisfiedAndExhaustsOnlyMissingCases() {
        let receiver = OrderedSet<Int>(sequence: [1, 2])
        let prefix = OneShot([7, 1, 1, 2, 8, 9])
        XCTAssertTrue(receiver.isSubset(of: prefix))
        XCTAssertEqual(prefix.nextCalls, 4)
        let missing = OneShot([1, 1, 8])
        XCTAssertFalse(receiver.isSubset(of: missing))
        XCTAssertEqual(missing.iteratorRequests, 1)
        XCTAssertEqual(missing.nextCalls, 4) // Includes the nil terminator.
    }

    func testCollectionsKeepMembershipCustomization() {
        let receiver = OrderedSet<Int>(sequence: [1, 2])
        let specialized = MembershipCollection()
        XCTAssertTrue(receiver.isSubset(of: specialized))
        XCTAssertEqual(specialized.membershipCalls, 2)
        XCTAssertEqual(specialized.elementReads, 0)
        XCTAssertTrue(receiver.isSubset(of: Set([1, 2, 3])))
        XCTAssertTrue(receiver.isSubset(of: 0..<Int.max))
        XCTAssertFalse(receiver.isSubset(of: [0, 1]))
        XCTAssertTrue(receiver.isSubset(of: [9, 1, 2, 8][1...2]))
    }

    func testCollisionsEqualRepresentativesAndSnapshots() {
        final class Key: Hashable {
            let value: Int
            init(_ value: Int) { self.value = value }
            static func == (lhs: Key, rhs: Key) -> Bool { lhs.value == rhs.value }
            func hash(into hasher: inout Hasher) { hasher.combine(0) }
        }
        let first = Key(1), second = Key(2)
        let receiver = OrderedSet<Key>(sequence: [first, second])
        var saved = receiver.makeIterator()
        XCTAssertTrue(receiver.isSubset(of: OneShot([Key(2), Key(2), Key(1)])))
        XCTAssertTrue(receiver[0] === first)
        XCTAssertTrue(receiver[1] === second)
        XCTAssertTrue(saved.next() === first)
        XCTAssertTrue(saved.next() === second)
        XCTAssertNil(saved.next())
        XCTAssertEqual(receiver.index(of: first), 0)
        XCTAssertEqual(receiver.index(of: second), 1)
    }

    func testGeneratedFiniteSequencesAgainstSetOracle() {
        var seed: UInt64 = 0x535542534554
        func draw(_ limit: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(limit))
        }
        for _ in 0..<512 {
            let wanted = (0..<draw(16)).map { _ in draw(16) }
            let offered = (0..<draw(32)).map { _ in draw(16) }
            let receiver = OrderedSet<Int>(sequence: wanted)
            let expected = Set(wanted).isSubset(of: Set(offered))
            let input = OneShot(offered)
            XCTAssertEqual(receiver.isSubset(of: input), expected)
            XCTAssertLessThanOrEqual(input.iteratorRequests, 1)
            XCTAssertEqual(receiver.isSubset(of: offered), expected)
            XCTAssertEqual(Set(receiver), Set(wanted))
        }
    }

    func testHugeRangeMembershipIncludesRemoteEndpointsAndMisses() {
        let positive = OrderedSet(sequence: [1, Int.max - 1])
        XCTAssertTrue(positive.isSubset(of: 0..<Int.max))
        XCTAssertFalse(OrderedSet(sequence: [-1, Int.max - 1]).isSubset(of: 0..<Int.max))
        XCTAssertTrue(OrderedSet(sequence: [Int.max]).isSubset(of: 0...Int.max))
        XCTAssertFalse(OrderedSet(sequence: [Int.max]).isSubset(of: 0..<Int.max))
        XCTAssertTrue(OrderedSet(sequence: [Int.min, Int.max]).isSubset(of: Int.min...Int.max))
    }

    func testSingletonAndEmptyKeepCollectionMembershipDispatch() {
        let specialized = MembershipCollection()
        XCTAssertTrue(OrderedSet<Int>().isSubset(of: specialized))
        XCTAssertEqual(specialized.membershipCalls, 0)
        XCTAssertEqual(specialized.elementReads, 0)
        XCTAssertTrue(OrderedSet(sequence: [2]).isSubset(of: specialized))
        XCTAssertFalse(OrderedSet(sequence: [4]).isSubset(of: specialized))
        XCTAssertEqual(specialized.membershipCalls, 2)
        XCTAssertEqual(specialized.elementReads, 0)
    }
}
