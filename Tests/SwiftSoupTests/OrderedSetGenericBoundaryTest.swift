import XCTest
import SwiftSoup

final class OrderedSetGenericBoundaryTest: XCTestCase {
    private final class Stream<Value>: Sequence, IteratorProtocol {
        let values: [Value]
        var offset = 0
        private(set) var iteratorCount = 0
        init(_ values: [Value]) { self.values = values }
        func makeIterator() -> Stream<Value> { iteratorCount += 1; return self }
        func next() -> Value? {
            guard offset < values.count else { return nil }
            defer { offset += 1 }
            return .some(values[offset]) // A nil member is not end-of-stream.
        }
    }

    private final class Key: Hashable {
        let id: Int
        init(_ id: Int) { self.id = id }
        static func == (lhs: Key, rhs: Key) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(0) }
    }

    func testNestedOptionalSinglePassSubsetsMatchFiniteArrayOracle() {
        let alphabet: [Int??] = [nil, .some(nil), .some(.some(1)), .some(.some(2))]
        var comparisons = 0
        for length in 0...5 {
            let possibilities = 1 << (2 * length)
            for code in 0..<possibilities {
                var bits = code
                let values: [Int??] = (0..<length).map { _ in
                    defer { bits >>= 2 }
                    return alphabet[bits & 3]
                }
                for mask in 0..<16 {
                    let required = alphabet.enumerated().compactMap { index, value -> Int??? in
                        mask & (1 << index) == 0 ? nil : .some(value)
                    }
                    let expected = required.allSatisfy { values.contains($0) }
                    for order in [required, Array(required.reversed())] {
                        let subject = OrderedSet(sequence: order)
                        let stream = Stream(values)
                        XCTAssertEqual(subject.isSubset(of: stream), expected)
                        XCTAssertLessThanOrEqual(stream.iteratorCount, 1)
                        XCTAssertEqual(Array(subject), order)
                        comparisons += 1
                    }
                }
            }
        }
        XCTAssertEqual(comparisons, 43_680)
    }

    func testNilMembersRemainDistinctFromMissingIndicesAndIteratorExhaustion() {
        let values: [Int??] = [nil, .some(nil), .some(.some(1))]
        let subject = OrderedSet(sequence: values)
        var saved = subject.makeIterator()
        subject.swapObject(values[0], with: values[1])
        XCTAssertEqual(Array(subject), [values[1], values[0], values[2]])
        for index in 0..<subject.count {
            XCTAssertEqual(subject.index(of: subject[index]), index)
        }
        subject.moveObject(values[0], toIndex: 2)
        XCTAssertEqual(Array(subject), [values[1], values[2], values[0]])
        for value in values {
            let next: Int??? = saved.next()
            XCTAssertNotNil(next as Any?)
            XCTAssertEqual(next, .some(value))
        }
        XCTAssertNil(saved.next() as Any?)
        subject.remove(values[1])
        XCTAssertNil(subject.index(of: values[1]))
        XCTAssertEqual(subject.index(of: values[0]), 1)
        XCTAssertTrue(subject.isSubset(of: Stream([values[0], values[2]])))
    }

    func testTypeErasedCollisionKeysKeepRepresentativesAndReleaseLookups() {
        let first = Key(1), second = Key(2)
        let subject = OrderedSet(sequence: [AnyHashable(first), AnyHashable(second)])
        weak var lookup: Key?
        do {
            let temporary = Key(1)
            lookup = temporary
            subject.swapObject(AnyHashable(temporary), with: AnyHashable(Key(2)))
            XCTAssertTrue(subject.isSubset(of: Stream([AnyHashable(temporary), AnyHashable(Key(2))])))
        }
        XCTAssertNil(lookup)
        XCTAssertTrue(subject[0].base as? Key === second)
        XCTAssertTrue(subject[1].base as? Key === first)
        XCTAssertEqual(subject.index(of: AnyHashable(Key(1))), 1)
        XCTAssertEqual(subject.index(of: AnyHashable(Key(2))), 0)
        let replacement = Key(1)
        subject.append(AnyHashable(replacement))
        XCTAssertTrue(subject[1].base as? Key === replacement, "Append still explicitly replaces equal members")
    }
}
