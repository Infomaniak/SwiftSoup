import XCTest
import SwiftSoup

final class NodeIdentityHashTest: XCTestCase {
    func testHashAndDictionaryMembershipSurviveDOMMutation() throws {
        let document = try SwiftSoup.parse("<p>Before</p>")
        let node = try XCTUnwrap(document.select("p").first())
        let originalHash = node.hashValue
        let nodes: Set<Node> = [node]
        var values: [Node: String] = [node: "retained"]

        try node.attr("class", "updated")
        try node.text("After")
        try node.setBaseUri("https://example.com/changed/")

        XCTAssertEqual(node.hashValue, originalHash)
        XCTAssertTrue(nodes.contains(node))
        XCTAssertEqual(values[node], "retained")
        XCTAssertEqual(values.removeValue(forKey: node), "retained")
        XCTAssertTrue(values.isEmpty)
    }

    func testDistinctNodesWithIdenticalMarkupRemainDistinct() throws {
        let document = try SwiftSoup.parse("<p>Same</p><p>Same</p>")
        let paragraphs = try document.select("p").array()
        XCTAssertEqual(paragraphs.count, 2)
        let first: Node = paragraphs[0]
        let second: Node = paragraphs[1]
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Set<Node>([first, second, first]).count, 2)
        let values: [Node: Int] = [first: 1, second: 2]
        XCTAssertEqual(values[first], 1)
        XCTAssertEqual(values[second], 2)
    }

    func testHashSurvivesReparentingAndOutputSettingsChanges() throws {
        let original = try SwiftSoup.parse("<div><p>Value</p></div>")
        let destination = try SwiftSoup.parse("<main></main>")
        let node = try XCTUnwrap(original.select("p").first())
        let parent = try XCTUnwrap(destination.select("main").first())
        let hash = node.hashValue
        let values: [Node: Int] = [node: 42]

        try parent.appendChild(node)
        destination.outputSettings().prettyPrint(pretty: false)
        destination.outputSettings().syntax(syntax: .xml)

        XCTAssertEqual(node.hashValue, hash)
        XCTAssertEqual(values[node], 42)
    }

    func testHashDoesNotInvokeSerialization() {
        let document = CountingDocument([])
        var hasher = Hasher()
        document.hash(into: &hasher)
        _ = hasher.finalize()
        XCTAssertEqual(document.serializationCount, 0)
    }

    private final class CountingDocument: Document {
        var serializationCount = 0

        override func outerHtml() throws -> String {
            serializationCount += 1
            return try super.outerHtml()
        }
    }
}
