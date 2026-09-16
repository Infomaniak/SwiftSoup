import Foundation
import XCTest
@testable import SwiftSoup

final class FormattingStackLookupTest: XCTestCase {
    func testMembershipMatchesIdentityForEmptyAndDeepStacks() throws {
        let builder = HtmlTreeBuilder()
        let tag = try Tag.valueOf("b")
        let nodes = (0..<257).map { _ in Element(tag, "") }
        let absent = Element(tag, "")
        for count in [0, 1, 2, 8, 32, 128, 257] {
            builder.stack = Array(nodes.prefix(count))
            let snapshot = builder.stack
            for node in nodes + [absent] {
                XCTAssertEqual(builder.onStack(node), snapshot.contains { $0 === node })
            }
            XCTAssertEqual(builder.stack.map(ObjectIdentifier.init), snapshot.map(ObjectIdentifier.init))
        }
    }

    func testPublicStackReplacementAndDuplicateReferencesAreObserved() throws {
        let builder = HtmlTreeBuilder()
        let first = try Element(Tag.valueOf("b"), "")
        let second = try Element(Tag.valueOf("b"), "")
        let third = try Element(Tag.valueOf("i"), "")
        builder.stack = [first, second, first]
        XCTAssertTrue(builder.onStack(first))
        XCTAssertTrue(builder.onStack(second))
        XCTAssertFalse(builder.onStack(third))
        XCTAssertTrue(builder.aboveOnStack(first) === second)
        builder.stack.removeLast()
        XCTAssertTrue(builder.onStack(first))
        XCTAssertNil(builder.aboveOnStack(first))
        builder.stack = [third]
        XCTAssertFalse(builder.onStack(first))
        XCTAssertFalse(builder.onStack(second))
        XCTAssertTrue(builder.onStack(third))
        builder.stack.removeAll()
        XCTAssertFalse(builder.onStack(third))
    }

    func testRenamedOrReparentedMembersRemainMembers() throws {
        let builder = HtmlTreeBuilder()
        let document = try SwiftSoup.parse("<main><b>one</b></main><aside></aside>")
        let member = try XCTUnwrap(document.getElementsByTag("b").first())
        let absent = member.copy() as! Element
        builder.stack = [member]
        try member.tagName("em")
        try member.attr("class", "changed")
        try document.getElementsByTag("aside").first()!.appendChild(member)
        XCTAssertTrue(builder.onStack(member))
        XCTAssertFalse(builder.onStack(absent))
        try member.remove()
        XCTAssertTrue(builder.onStack(member))
    }

    func testFormattingMarkersAndStackMembershipStayIndependent() throws {
        let builder = HtmlTreeBuilder()
        let element = try Element(Tag.valueOf("b"), "")
        builder.pushActiveFormattingElements(element)
        XCTAssertTrue(builder.isInActiveFormattingElements(element))
        XCTAssertFalse(builder.onStack(element))
        builder.stack = [element]
        XCTAssertTrue(builder.onStack(element))
        builder.insertMarkerToFormattingElements()
        XCTAssertNil(builder.lastFormattingElement())
        XCTAssertTrue(builder.onStack(element))
        builder.clearFormattingElementsToLastMarker()
        XCTAssertTrue(builder.lastFormattingElement() === element)
        builder.removeFromActiveFormattingElements(element)
        XCTAssertFalse(builder.isInActiveFormattingElements(element))
        XCTAssertTrue(builder.onStack(element))
    }
}
