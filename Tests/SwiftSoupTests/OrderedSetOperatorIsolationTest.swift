import XCTest
import SwiftSoup

final class OrderedSetOperatorIsolationTest: XCTestCase {
    private final class Item: Hashable {
        let key: Int
        let payload: String
        init(_ key: Int, _ payload: String) { self.key = key; self.payload = payload }
        static func == (lhs: Item, rhs: Item) -> Bool { lhs.key == rhs.key }
        func hash(into hasher: inout Hasher) { hasher.combine(key) }
    }

    func testPlusReturnsIndependentSetWithoutMutatingLeftOperand() {
        let lhs = OrderedSet(sequence: [1, 2, 3])
        let result = lhs + [3, 4]
        XCTAssertEqual(Array(lhs), [1, 2, 3])
        XCTAssertEqual(Array(result), [1, 2, 3, 4])
        XCTAssertFalse(lhs === result)
    }

    func testMinusReturnsIndependentSetWithoutMutatingLeftOperand() {
        let lhs = OrderedSet(sequence: [1, 2, 3])
        let result = lhs - [2, 9]
        XCTAssertEqual(Array(lhs), [1, 2, 3])
        XCTAssertEqual(Array(result), [1, 3])
        XCTAssertFalse(lhs === result)
    }

    func testResultsDoNotShareSubsequentMutation() {
        let lhs = OrderedSet(sequence: [1, 2, 3])
        let plus = lhs + [4]
        let minus = lhs - [2]
        plus.append(5)
        minus.remove(1)
        XCTAssertEqual(Array(lhs), [1, 2, 3])
        XCTAssertEqual(Array(plus), [1, 2, 3, 4, 5])
        XCTAssertEqual(Array(minus), [3])
    }

    func testPlusRetainsAppendReplacementSemanticsOnlyInResult() {
        let original = Item(1, "original")
        let other = Item(2, "other")
        let replacement = Item(1, "replacement")
        let lhs = OrderedSet(sequence: [original, other])
        let result = lhs + [replacement]
        XCTAssertTrue(lhs[0] === original)
        XCTAssertTrue(lhs[1] === other)
        XCTAssertTrue(result[0] === replacement)
        XCTAssertTrue(result[1] === other)
    }

    func testMutatingOperatorsStillMutateInPlace() {
        var value = OrderedSet(sequence: [1, 2, 3])
        let identity = value
        value += [4]
        XCTAssertTrue(value === identity)
        XCTAssertEqual(Array(value), [1, 2, 3, 4])
        value -= [2]
        XCTAssertTrue(value === identity)
        XCTAssertEqual(Array(value), [1, 3, 4])
    }
}
