import XCTest
@testable import SwiftSoup

final class ElementIdentityHashTest: XCTestCase {
    func testHashRemainsStableWhenTagChanges() throws {
        let element = try Element(Tag.valueOf("p"), "")
        let node: Node = element
        let initialElementHash = element.hashValue
        let initialNodeHash = node.hashValue
        for tag in ["div", "SPAN", "custom-element", "日本語", "p"] {
            try element.tagName(tag)
            XCTAssertEqual(element.hashValue, initialElementHash)
            XCTAssertEqual(node.hashValue, initialNodeHash)
        }
    }

    func testElementAndNodeCollectionsKeepRenamedKeys() throws {
        let document = try SwiftSoup.parse("<main><p>one</p><p>two</p></main>")
        let elements = try document.getElementsByTag("p").array()
        let elementSet = Set(elements)
        let nodeSet = Set(elements.map { $0 as Node })
        let elementMap = Dictionary(uniqueKeysWithValues: elements.enumerated().map { ($0.element, $0.offset) })
        let nodeMap = Dictionary(uniqueKeysWithValues: elements.enumerated().map { ($0.element as Node, $0.offset) })
        for (index, element) in elements.enumerated() {
            try element.tagName("section")
            XCTAssertTrue(elementSet.contains(element))
            XCTAssertTrue(nodeSet.contains(element))
            XCTAssertEqual(elementMap[element], index)
            XCTAssertEqual(nodeMap[element], index)
        }
        XCTAssertEqual(elementSet.count, 2)
        XCTAssertNotEqual(elements[0], elements[1])
    }

    func testHashDoesNotSerializeOrDependOnAttributeAndTextChanges() throws {
        let element = try Element(Tag.valueOf("p"), "")
        let original = element.hashValue
        try element.attr("class", "one")
        try element.text("日本語 < &")
        try element.appendElement("em").text("two")
        try element.tagName("article")
        XCTAssertEqual(element.hashValue, original)
        XCTAssertEqual(Set([element, element]).count, 1)
    }
}
