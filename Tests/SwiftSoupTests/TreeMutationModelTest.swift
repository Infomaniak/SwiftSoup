import XCTest
@testable import SwiftSoup

final class TreeMutationModelTest: XCTestCase {
    private func check(_ parent: Element, _ expected: [Node], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(parent.getChildNodes().map(ObjectIdentifier.init), expected.map(ObjectIdentifier.init), file: file, line: line)
        for (i, child) in expected.enumerated() {
            XCTAssertTrue(child.parent() === parent, file: file, line: line)
            XCTAssertEqual(child.siblingIndex, i, file: file, line: line)
            XCTAssertTrue(child.previousSibling() === (i == 0 ? nil : expected[i - 1]), file: file, line: line)
            XCTAssertTrue(child.nextSibling() === (i + 1 == expected.count ? nil : expected[i + 1]), file: file, line: line)
        }
    }

    func testExhaustiveIndexedMovesAgreeWithOriginalGapModel() throws {
        var states = 0
        for count in 0...4 {
            let width = count + 2 // Include two detached input nodes.
            for length in 0...3 {
                let combinations = (0..<length).reduce(1) { value, _ in value * width }
                for encoded in 0..<combinations {
                    var remaining = encoded
                    var sequence: [Int] = []
                    for _ in 0..<length { sequence.append(remaining % width); remaining /= width }
                    for gap in 0...count {
                        let parent = Element(try Tag.valueOf("div"), "")
                        let nodes = try (0..<width).map { _ in Element(try Tag.valueOf("i"), "") }
                        for child in nodes.prefix(count) { try parent.appendChild(child) }
                        var seen = Set<Int>()
                        let unique = sequence.filter { seen.insert($0).inserted }
                        let prefix = (0..<gap).filter { !seen.contains($0) }
                        let suffix = (gap..<count).filter { !seen.contains($0) }
                        let expected = (prefix + unique + suffix).map { nodes[$0] as Node }
                        try parent.insertChildren(gap, sequence.map { nodes[$0] })
                        check(parent, expected)
                        for index in count..<width where !seen.contains(index) { XCTAssertNil(nodes[index].parent()) }
                        states += 1
                    }
                }
            }
        }
        XCTAssertEqual(states, 2269)
    }

    private func independentScan(_ root: Element, _ evaluator: Evaluator) throws -> [ObjectIdentifier] {
        var stack = [root]
        var result: [ObjectIdentifier] = []
        while let node = stack.popLast() {
            if try evaluator.matches(root, node) { result.append(ObjectIdentifier(node)) }
            for child in node.getChildNodes().reversed() {
                if let element = child as? Element { stack.append(element) }
            }
        }
        return result
    }

    func testMutationSequenceMatchesIndependentParentAndSelectorModels() throws {
        let doc = try SwiftSoup.parse("<main><section id='a'></section><section id='b'></section></main>")
        let a = try XCTUnwrap(doc.getElementById("a"))
        let b = try XCTUnwrap(doc.getElementById("b"))
        let parents = [a, b]
        let nodes = try (0..<8).map { index -> Element in
            let node = Element(try Tag.valueOf("i"), "")
            try node.attr("id", "n\(index)").attr("class", "item").text("v\(index)")
            return node
        }
        var model: [[Int]] = [[], []]
        var state: UInt64 = 0x79A3845
        func next(_ limit: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(limit))
        }
        let queries = ["i", ".item", "section:empty", "section > i:first-child", "i + i", "i:nth-child(2)", "i:contains(extra)", "section:containsData(data)", "#n3"]
        for step in 0..<384 {
            let destination = next(2)
            let chosen = next(nodes.count)
            switch next(6) {
            case 0, 1:
                let gap = next(model[destination].count + 1)
                let input = [chosen, next(nodes.count), chosen]
                var seen = Set<Int>()
                let unique = input.filter { seen.insert($0).inserted }
                let prefix = model[destination].prefix(gap).filter { !seen.contains($0) }
                let suffix = model[destination].dropFirst(gap).filter { !seen.contains($0) }
                for i in model.indices { model[i].removeAll { seen.contains($0) } }
                model[destination] = prefix + unique + suffix
                // Character/data children are appended only to the leaf elements.
                try parents[destination].insertChildren(gap, input.map { nodes[$0] })
            case 2:
                try nodes[chosen].remove()
                for i in model.indices { model[i].removeAll { $0 == chosen } }
            case 3:
                parents[destination].empty()
                model[destination] = []
            case 4:
                try nodes[chosen].appendText("extra")
            default:
                try nodes[chosen].appendChild(DataNode(Array("data".utf8), []))
            }
            for i in model.indices { check(parents[i], model[i].map { nodes[$0] }) }
            for i in nodes.indices where !model.joined().contains(i) { XCTAssertNil(nodes[i].parent()) }
            for root in [doc as Element, a, b, nodes[chosen]] {
                for query in queries {
                    let evaluator = try QueryParser.parse(query)
                    let expected = try independentScan(root, evaluator)
                    XCTAssertEqual(try Collector.collect(evaluator, root).array().map(ObjectIdentifier.init), expected, "step \(step): \(query)")
                    for _ in 0..<3 {
                        XCTAssertEqual(try root.select(query).array().map(ObjectIdentifier.init), expected, "step \(step): \(query)")
                    }
                }
            }
        }
    }

    func testCrossDocumentMovesInvalidateOldAndNewRoots() throws {
        let left = try SwiftSoup.parse("<main><i id='move'>payload</i></main>")
        let right = try SwiftSoup.parse("<main></main>")
        let node = try XCTUnwrap(left.getElementById("move"))
        let roots = [try XCTUnwrap(left.select("main").first()), try XCTUnwrap(right.select("main").first())]
        for iteration in 0..<64 {
            for root in [left as Element, right, roots[0], roots[1], node] {
                for _ in 0..<3 { _ = try root.select("#move:contains(payload)") }
            }
            let destination = roots[(iteration + 1) % 2]
            try destination.appendChild(node)
            for root in [left as Element, right, roots[0], roots[1], node] {
                let query = "#move:contains(payload)"
                XCTAssertEqual(try root.select(query).array().map(ObjectIdentifier.init), try independentScan(root, QueryParser.parse(query)))
            }
            XCTAssertTrue(node.ownerDocument() === (iteration % 2 == 0 ? right : left))
        }
    }

    func testEmptyDetachesWithoutRetainingFormerDocument() throws {
        weak var observed: Document?
        let retained: Element
        do {
            let doc = try SwiftSoup.parse("<div><i id='retained'>text</i></div>")
            observed = doc
            let div = try XCTUnwrap(doc.select("div").first())
            retained = try XCTUnwrap(div.select("i").first())
            for _ in 0..<4 { _ = try retained.select("i:contains(text)") }
            div.empty()
            XCTAssertNil(retained.parent())
        }
        XCTAssertNil(observed)
        XCTAssertEqual(try retained.text(), "text")
    }
}
