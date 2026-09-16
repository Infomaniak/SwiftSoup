import Foundation
import XCTest
@testable import SwiftSoup

/// Opt-in release benchmarks for small DOM operations. Setup is not timed.
///
/// SWIFTSOUP_OPERATION_BENCHMARK=1 swift test -c release --filter DOMOperationBenchmarkTest
/// Use the same file, toolchain, sizes and iterations in baseline/candidate worktrees.
/// Alternate execution order, run A/A controls, and keep profiling separate from timing.
final class DOMOperationBenchmarkTest: XCTestCase {
    private func configuration() throws -> (count: Int, iterations: Int) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SWIFTSOUP_OPERATION_BENCHMARK"] == "1" else {
            throw XCTSkip("Set SWIFTSOUP_OPERATION_BENCHMARK=1 to run release benchmarks")
        }
        let count = Int(environment["SWIFTSOUP_OPERATION_COUNT"] ?? "256") ?? 0
        let iterations = Int(environment["SWIFTSOUP_OPERATION_ITERATIONS"] ?? "1000") ?? 0
        guard (1...100_000).contains(count), (1...1_000_000).contains(iterations) else {
            throw NSError(domain: "DOMOperationBenchmark", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid benchmark count or iteration count"])
        }
        return (count, iterations)
    }

    private func document(_ count: Int) throws -> Document {
        let paragraphs = (0..<count).map {
            "<p id='p\($0)' class='entry' data-n='\($0)'><b>日本語</b>text</p>"
        }.joined()
        let document = try SwiftSoup.parse("<main>\(paragraphs)</main>")
        document.outputSettings().prettyPrint(pretty: false)
        return document
    }

    @discardableResult
    private func run(_ name: String, count: Int, iterations: Int,
                     operation: () throws -> UInt64) throws -> UInt64 {
        var checksum: UInt64 = 0
        let warmups = 3
        for _ in 0..<warmups { checksum &+= try operation() }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { checksum &+= try operation() }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let result: [String: Any] = [
            "operation": name, "count": count, "iterations": iterations,
            "warmups": warmups, "elapsed_ms": Double(elapsed) / 1_000_000,
            "checksum": String(checksum)
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("SWIFTSOUP_OPERATION_RESULT " + String(decoding: data, as: UTF8.self))
        return checksum
    }

    func testNormalizedLeafText() throws {
        try leafText(normalize: true)
    }

    func testRawLeafText() throws {
        try leafText(normalize: false)
    }

    private func leafText(normalize: Bool) throws {
        let config = try configuration()
        let document = try document(config.count)
        let leaves = try document.getElementsByTag("b").array()
        let checksum = try run(normalize ? "leaf-text" : "leaf-text-raw",
                               count: config.count, iterations: config.iterations) {
            var bytes: UInt64 = 0
            for leaf in leaves { bytes &+= UInt64(try leaf.text(trimAndNormaliseWhitespace: normalize).utf8.count) }
            return bytes
        }
        XCTAssertEqual(checksum, UInt64(config.iterations + 3) * UInt64(config.count) * UInt64("日本語".utf8.count))
        withExtendedLifetime(document) {}
    }

    func testAttributeCopy() throws {
        let config = try configuration()
        let document = try document(config.count)
        let attributes = try document.getElementsByTag("p").map { $0.getAttributes()! }
        for attributes in attributes { _ = Array(attributes) }
        let checksum = try run("attributes-copy", count: config.count, iterations: config.iterations) {
            var size: UInt64 = 0
            for attributes in attributes { size &+= UInt64(attributes.clone().size()) }
            return size
        }
        XCTAssertEqual(checksum, UInt64(config.iterations + 3) * UInt64(config.count) * 3)
        withExtendedLifetime(document) {}
    }

    func testDocumentCopy() throws {
        let config = try configuration()
        let document = try document(config.count)
        // Keep materialization outside the timed deep-copy operation.
        document.materializeAttributesRecursively()
        let checksum = try run("document-copy", count: config.count, iterations: config.iterations) {
            let copy = document.copy() as! Document
            return UInt64(copy.childNodeSize())
        }
        XCTAssertEqual(checksum, UInt64(config.iterations + 3) * UInt64(document.childNodeSize()))
        let copy = document.copy() as! Document
        // Compare DOM serialization under the same explicit output policy.
        copy.outputSettings().prettyPrint(pretty: false)
        XCTAssertEqual(try copy.outerHtml(), try document.outerHtml())
        XCTAssertTrue(try copy.getElementsByTag("b").first()?.ownerDocument() === copy)
    }

    func testSiblingReindex() throws {
        let config = try configuration()
        let document = try document(config.count)
        let root = try XCTUnwrap(document.getElementsByTag("main").first())
        let checksum = try run("siblings-reindex", count: config.count, iterations: config.iterations) {
            root.reindexChildren(0)
            return UInt64(root.childNode(config.count - 1).siblingIndex)
        }
        XCTAssertEqual(checksum, UInt64(config.iterations + 3) * UInt64(config.count - 1))
        for (index, child) in root.getChildNodes().enumerated() {
            XCTAssertEqual(child.siblingIndex, index)
            XCTAssertTrue(child.parent() === root)
        }
        withExtendedLifetime(document) {}
    }

    func testSiblingRotation() throws {
        let config = try configuration()
        let document = try document(config.count)
        let root = try XCTUnwrap(document.getElementsByTag("main").first())
        let checksum = try run("siblings-rotate", count: config.count, iterations: config.iterations) {
            try root.insertChildren(0, [root.childNode(config.count - 1)])
            return UInt64(root.childNode(config.count - 1).siblingIndex)
        }
        XCTAssertEqual(checksum, UInt64(config.iterations + 3) * UInt64(config.count - 1))
        let offset = (config.iterations + 3) % config.count
        for (index, child) in root.getChildNodes().enumerated() {
            XCTAssertEqual(child.siblingIndex, index)
            XCTAssertTrue(child.parent() === root)
            XCTAssertEqual(try child.attr("id"), "p\((index - offset + config.count) % config.count)")
        }
        withExtendedLifetime(document) {}
    }
}
