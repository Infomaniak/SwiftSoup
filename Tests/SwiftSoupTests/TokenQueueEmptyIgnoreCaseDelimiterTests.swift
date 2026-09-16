import XCTest
@testable import SwiftSoup
final class TokenQueueEmptyIgnoreCaseDelimiterTests: XCTestCase {
    func testConsumeToIgnoreCaseEmptyDelimiterIsNoOp() {
        let q=TokenQueue("AbC"); XCTAssertEqual(q.consumeToIgnoreCase(""), ""); XCTAssertEqual(q.remainder(), "AbC")
    }
    func testChompToIgnoreCaseEmptyDelimiterIsNoOp() {
        let q=TokenQueue("AbC"); XCTAssertEqual(q.chompToIgnoreCase(""), ""); XCTAssertEqual(q.remainder(), "AbC")
    }
    func testEmptyDelimiterAfterPartialConsumptionPreservesRemainder() {
        let q=TokenQueue("AbC"); XCTAssertEqual(q.consume(), "A"); XCTAssertEqual(q.consumeToIgnoreCase(""), ""); XCTAssertEqual(q.remainder(), "bC")
    }
    func testNonemptyIgnoreCaseBehaviorIsUnchanged() {
        let q=TokenQueue("xxAbCyy"); XCTAssertEqual(q.consumeToIgnoreCase("aBc"), "xx"); XCTAssertEqual(q.chompToIgnoreCase("aBc"), ""); XCTAssertEqual(q.remainder(), "yy")
    }
}
