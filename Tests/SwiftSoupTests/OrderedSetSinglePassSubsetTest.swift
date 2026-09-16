import XCTest
import SwiftSoup

final class OrderedSetSinglePassSubsetTest: XCTestCase {
    /// A valid single-pass Sequence: every iterator shares one input cursor.
    private final class Stream<Value>: Sequence, IteratorProtocol {
        private let values: [Value]
        private(set) var position = 0
        private(set) var iteratorCount = 0
        private(set) var nextCount = 0
        init(_ values: [Value]) { self.values = values }
        func makeIterator() -> Stream<Value> { iteratorCount += 1; return self }
        func next() -> Value? {
            nextCount += 1
            guard position < values.count else { return nil }
            defer { position += 1 }
            return values[position]
        }
    }
    private final class Item: Hashable {
        let key: Int
        let payload: String
        init(_ key: Int, _ payload: String) { self.key = key; self.payload = payload }
        static func == (lhs: Item, rhs: Item) -> Bool { lhs.key == rhs.key }
        func hash(into hasher: inout Hasher) { hasher.combine(0) }
    }
    func testSinglePassPermutationsContainTheSameMembers() {
        let set = OrderedSet(sequence: [1, 2, 3])
        for values in [[1, 2, 3], [1, 3, 2], [2, 1, 3], [2, 3, 1], [3, 1, 2], [3, 2, 1]] {
            XCTAssertTrue(set.isSubset(of: Stream(values)), "stream: \(values)")
            XCTAssertEqual(Array(set), [1, 2, 3])
        }
    }
    func testCreatesOneIteratorAndStopsAfterTheLastRequiredMember() {
        let stream = Stream([99, 3, 99, 1, 99, 2, 100, 101])
        let set = OrderedSet(sequence: [1, 2, 3])
        XCTAssertTrue(set.isSubset(of: stream))
        XCTAssertEqual(stream.iteratorCount, 1)
        XCTAssertEqual(stream.position, 6)
        XCTAssertEqual(stream.nextCount, 6)
        XCTAssertEqual(stream.next(), 100, "must not materialize the unused tail")
    }
    func testStandardAnyIteratorCanBeConsumedOnlyOnce() {
        let permutations = [[1, 2, 3], [1, 3, 2], [2, 1, 3], [2, 3, 1], [3, 1, 2], [3, 2, 1]]
        for values in permutations {
            var position = 0
            let iterator = AnyIterator<Int> {
                guard position < values.count else { return nil }
                defer { position += 1 }
                return values[position]
            }
            XCTAssertTrue(OrderedSet(sequence: [1, 2, 3]).isSubset(of: iterator))
        }
    }
    func testEmptyReceiverDoesNotConsumeOrCreateAnIterator() {
        let stream = Stream([1, 2, 3])
        XCTAssertTrue(OrderedSet<Int>().isSubset(of: stream))
        XCTAssertEqual(stream.iteratorCount, 0)
        XCTAssertEqual(stream.nextCount, 0)
    }
    func testMissingMembersAndDuplicateValues() {
        for values in [[], [0], [1, 1, 1], [3, 2, 2, 9], [9, 9, 9]] {
            let required = [1, 2, 3]
            let expected = required.allSatisfy { values.contains($0) }
            XCTAssertEqual(OrderedSet(sequence: required).isSubset(of: Stream(values)), expected)
        }
        for values in [[3, 3, 1, 1, 2, 2], [2, 2, 1, 1, 3, 3], [1, 1, 2, 2, 3, 3]] {
            XCTAssertTrue(OrderedSet(sequence: [1, 2, 3]).isSubset(of: Stream(values)))
        }
    }
    func testReferenceRepresentativesRemainStoredAndLookupsAreReleased() {
        let a = Item(1, "original-a"), b = Item(2, "original-b")
        let set = OrderedSet(sequence: [a, b])
        var iterator = set.makeIterator()
        weak var lookup: Item?
        do {
            let temporary = Item(1, "lookup")
            lookup = temporary
            XCTAssertTrue(set.isSubset(of: [Item(2, "lookup"), temporary]))
        }
        XCTAssertNil(lookup)
        XCTAssertTrue(set[0] === a)
        XCTAssertTrue(set[1] === b)
        XCTAssertTrue(iterator.next() === a)
        XCTAssertTrue(iterator.next() === b)
        XCTAssertEqual(set.index(of: Item(1, "probe")), 0)
        XCTAssertEqual(set.index(of: Item(2, "probe")), 1)
    }
    func testCanonicalStringEqualityDoesNotRewriteStoredBytes() {
        let composed = "caf\u{E9}", decomposed = "cafe\u{301}"
        let set = OrderedSet(sequence: [composed, "日本"])
        XCTAssertTrue(set.isSubset(of: ["日本", decomposed]))
        XCTAssertEqual(set.map { Array($0.utf8) }, [Array(composed.utf8), Array("日本".utf8)])
    }
    func testGeneratedStreamsMatchAnIndependentArrayMembershipOracle() {
        // 364 streams, eight subsets, both receiver orders: 5,824 comparisons.
        for length in 0...5 {
            var count = 1
            for _ in 0..<length { count *= 3 }
            for code in 0..<count {
                var remaining = code
                var values: [Int] = []
                for _ in 0..<length { values.append(remaining % 3); remaining /= 3 }
                for mask in 0..<8 {
                    let required = (0..<3).filter { mask & (1 << $0) != 0 }
                    let expected = required.allSatisfy { values.contains($0) }
                    for order in [required, Array(required.reversed())] {
                        let set = OrderedSet(sequence: order)
                        let stream = Stream(values)
                        XCTAssertEqual(set.isSubset(of: stream), expected,
                                       "receiver=\(order), input=\(values)")
                        XCTAssertEqual(Array(set), order)
                        XCTAssertLessThanOrEqual(stream.iteratorCount, 1)
                    }
                }
            }
        }
    }
    func testSelfAndRestartableCollectionsRemainSupported() {
        for width in 0...24 {
            let values = Array(0..<width)
            let set = OrderedSet(sequence: values)
            XCTAssertTrue(set.isSubset(of: set))
            XCTAssertTrue(set.isSubset(of: values.reversed()))
            XCTAssertTrue(set.isSubset(of: Set(values)))
            XCTAssertEqual(set.isSubset(of: values.dropLast()), values.isEmpty)
            XCTAssertEqual(Array(set), values)
        }
    }
    func testLazyUnboundedInputStopsWhenTheSubsetIsProved() {
        var requested = 0
        let input = AnySequence<Int> {
            AnyIterator { requested += 1; return 42 }
        }
        XCTAssertTrue(OrderedSet(sequence: [42]).isSubset(of: input))
        XCTAssertEqual(requested, 1)
    }
}
