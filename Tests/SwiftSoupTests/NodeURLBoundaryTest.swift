import XCTest
@testable import SwiftSoup

final class NodeURLBoundaryTest: XCTestCase {
    func testAbsentBaseURIResolvesAbsoluteAttributeWithoutCrashing() throws {
        let node = TextNode("text", nil)
        try node.attr("href", "https://example.test/path")
        XCTAssertEqual(try node.absUrl("href"), "https://example.test/path")
        XCTAssertEqual(try node.attr("abs:href"), "https://example.test/path")
        XCTAssertEqual(try node.absUrl(Array("href".utf8)), Array("https://example.test/path".utf8))
    }
    func testAbsentBaseURIDoesNotInventRelativeResolution() throws {
        let node = TextNode("text", nil)
        try node.attr("href", "relative")
        XCTAssertEqual(try node.absUrl("href"), "")
        XCTAssertEqual(try node.absUrl("missing"), "")
        XCTAssertThrowsError(try node.absUrl(""))
    }
    func testURLResolutionUsesPublicBaseByteProjection() throws {
        final class ProjectedBase: TextNode {
            override func getBaseUriUTF8() -> [UInt8] { Array("https://example.test/root/".utf8) }
        }
        let node = ProjectedBase("text", "https://backing.invalid/")
        try node.attr("href", "target")
        XCTAssertEqual(try node.absUrl("href"), "https://example.test/root/target")
    }
}
