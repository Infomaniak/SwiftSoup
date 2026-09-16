import XCTest
@testable import SwiftSoup

final class CssDirectAttributeMutationTest: XCTestCase {
    // Deliberately avoid Collector and all query indexes for the reference walk.
    private func scan(_ root: Element, _ evaluator: Evaluator) throws -> [Element] {
        var result: [Element] = []
        var stack = [root]
        while let element = stack.popLast() {
            if try evaluator.matches(root, element) { result.append(element) }
            for child in element.childNodes.reversed() {
                if let child = child as? Element { stack.append(child) }
            }
        }
        return result
    }

    private func assertPaths(_ root: Element, _ query: String, _ ids: [String]? = nil,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let evaluator = try QueryParser.parse(query)
        let reference = try scan(root, evaluator)
        if let ids {
            XCTAssertEqual(reference.map { $0.id() }, ids, "scan: \(query)", file: file, line: line)
        }
        let expected = reference.map(ObjectIdentifier.init)
        XCTAssertEqual(try Collector.collect(evaluator, root).array().map(ObjectIdentifier.init), expected,
                       "collector: \(query)", file: file, line: line)
        XCTAssertEqual(try CssSelector.select(evaluator, root).array().map(ObjectIdentifier.init), expected,
                       "evaluator selection: \(query)", file: file, line: line)
        for _ in 0..<4 {
            XCTAssertEqual(try root.select(query).array().map(ObjectIdentifier.init), expected,
                           "public: \(query)", file: file, line: line)
        }
    }

    func testDirectAttributeObjectsInvalidateIndexedSelections() throws {
        let doc = try SwiftSoup.parse("<p id='hit' class='x' data-v='item42'></p><p id='miss'></p>")
        let hit = try XCTUnwrap(doc.getElementById("hit"))
        let attributes = try XCTUnwrap(hit.getAttributes())
        let value = try XCTUnwrap(attributes.first { $0.getKey() == "data-v" })
        let classes = try XCTUnwrap(attributes.first { $0.getKey() == "class" })
        try assertPaths(doc, "[data-v=item42]", ["hit"])
        _ = value.setValue(value: Array("".utf8))
        try assertPaths(doc, "[data-v=item42]", [])
        try assertPaths(doc, "p[data-v='']", ["hit"])
        try value.setKey(key: "DATA-OTHER")
        try assertPaths(doc, "[data-v]", [])
        try assertPaths(doc, "[data-other='']", ["hit"])
        try assertPaths(doc, ".x", ["hit"])
        _ = classes.setValue(value: Array("x x y x".utf8))
        try assertPaths(doc, ".x.y", ["hit"])
        try classes.setKey(key: "other-class")
        try assertPaths(doc, ".x", [])
    }

}
