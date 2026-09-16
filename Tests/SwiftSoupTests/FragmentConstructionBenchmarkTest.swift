import Foundation
import XCTest
import SwiftSoup

/// Opt-in release measurements. Each invocation prints one JSON timing record.
/// Use identical test source and environment on both revisions, alternating order.
final class FragmentConstructionBenchmarkTest: XCTestCase {
    private struct Fixture {
        let article: String
        let injected: String
    }

    private func fixture(_ count: Int) -> Fixture {
        let article = (0..<count).map { index in
            "<p id='p\(index)' class='entry'>日本語の文章です。<b>重要</b>な言葉と<a href='/\(index)'>説明</a>。</p>"
        }.joined(separator: "\n")
        let injected = (0..<count).map { index in
            "<p id='p\(index)' class='entry'><m-s><m-m data-id='\(index)'><m-t>日本語</m-t></m-m>の文章です。<b>重要</b>な言葉と<a href='/\(index)'>説明</a>。</m-s></p>"
        }.joined(separator: "\n")
        return Fixture(article: "<html><head><title>Reader</title></head><body>\(article)</body></html>",
                       injected: injected)
    }

    private struct Result {
        let html: [UInt8]
        let originalBodyBytes: Int
        var count: Int { html.count + originalBodyBytes }
    }

    private func operation(_ name: String, _ fixture: Fixture) throws -> Result {
        if name == "fragment" {
            let document = try SwiftSoup.parseBodyFragment(fixture.injected)
            document.outputSettings().prettyPrint(pretty: false)
            return try Result(html: document.outerHtmlUTF8WithoutSourceReuse(), originalBodyBytes: 0)
        }
        let document = try SwiftSoup.parse(fixture.article)
        document.outputSettings().prettyPrint(pretty: false)
        if name == "injection" {
            let root = document.body()!
            let original = try root.html()
            let stage = root.copy() as! Element
            try stage.html(fixture.injected)
            let staged = stage.getChildNodes().map { $0.copy() as! Node }
            let rollback = root.getChildNodes().map { $0.copy() as! Node }
            root.empty()
            try root.insertChildren(0, staged)
            let output = try document.outerHtmlUTF8ReusingSourceOutsideBody()
            withExtendedLifetime(rollback) {}
            // Consume both serialization results, as the caller passes the original
            // body to its separate language-processing stage (not measured here).
            return Result(html: output, originalBodyBytes: original.utf8.count)
        }
        return try Result(html: document.outerHtmlUTF8WithoutSourceReuse(), originalBodyBytes: 0)
    }

    private func benchmark(_ name: String) throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SWIFTSOUP_CONSTRUCTION_BENCHMARK"] == "1" else {
            throw XCTSkip("Set SWIFTSOUP_CONSTRUCTION_BENCHMARK=1 to run release measurements")
        }
        let count = Int(env["SWIFTSOUP_CONSTRUCTION_PARAGRAPHS"] ?? "64") ?? 0
        let iterations = Int(env["SWIFTSOUP_CONSTRUCTION_ITERATIONS"] ?? "100") ?? 0
        guard (1...4096).contains(count), (1...100_000).contains(iterations) else {
            throw NSError(domain: "FragmentConstructionBenchmark", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid paragraph or iteration count"])
        }
        let input = fixture(count)
        let expected = try operation(name, input)
        var checksum: UInt64 = 0
        for _ in 0..<3 { checksum &+= UInt64(try operation(name, input).count) }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { checksum &+= UInt64(try operation(name, input).count) }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        XCTAssertEqual(checksum, UInt64(iterations + 3) * UInt64(expected.count))
        let actual = try operation(name, input)
        XCTAssertEqual(actual.html, expected.html)
        XCTAssertEqual(actual.originalBodyBytes, expected.originalBodyBytes)
        let checked = try SwiftSoup.parse(expected.html, "", Parser.htmlParser())
        XCTAssertEqual(try checked.getElementsByTag("p").size(), count)
        XCTAssertEqual(try checked.getElementsByTag("m-m").size(), name == "document" ? 0 : count)
        let result: [String: Any] = ["operation": name, "paragraphs": count, "iterations": iterations,
                                   "warmups": 3, "elapsed_ms": Double(elapsed) / 1_000_000,
                                   "checksum": String(checksum)]
        print("SWIFTSOUP_CONSTRUCTION_RESULT " + String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }

    func testDocumentConstructionAndSerialization() throws { try benchmark("document") }
    func testFragmentConstructionAndSerialization() throws { try benchmark("fragment") }
    func testReaderInjectionReplay() throws { try benchmark("injection") }
}
