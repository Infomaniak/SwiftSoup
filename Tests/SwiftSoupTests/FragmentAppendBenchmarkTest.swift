import Foundation
import XCTest
@testable import SwiftSoup

/// Opt in with SWIFTSOUP_FRAGMENT_BENCHMARK=1 in a release test build.
/// Use identical test sources/counts/iterations on both revisions and alternate
/// execution order. Inputs here are synthetic, not a production distribution.
final class FragmentAppendBenchmarkTest: XCTestCase {
    private func benchmark(_ kind: String) throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SWIFTSOUP_FRAGMENT_BENCHMARK"] == "1" else {
            throw XCTSkip("Set SWIFTSOUP_FRAGMENT_BENCHMARK=1 to run")
        }
        let count = Int(env["SWIFTSOUP_FRAGMENT_COUNT"] ?? "256") ?? 0
        let iterations = Int(env["SWIFTSOUP_FRAGMENT_ITERATIONS"] ?? "100") ?? 0
        guard (1...8192).contains(count), (1...1_000_000).contains(iterations) else {
            throw NSError(domain: "FragmentAppendBenchmark", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid count or iterations"])
        }
        let parts = (0..<count).map { i in Array(["日本", "&", "語\t", "😀"][i % 4].utf8) }
        let slices = parts.map(ByteSlice.fromArray)
        let flat = parts.flatMap { $0 }
        let encoded = String(repeating: "日&amp;本&#x8a9e;", count: count)
        let decoded = Array(String(repeating: "日&本語", count: count).utf8)
        let markup = kind == "parse-attribute" ? "<p title='\(encoded)'>text</p>" : "<p>\(encoded)</p>"
        let scriptText = String(repeating: "if(a<b){s='<x';}<!--c-->\n", count: count)
        let script = "<script>\(scriptText)</script>"
        let interrupted = "<p>" + String(repeating: "日本</discarded-end>語", count: count) + "</p>"
        func operation() throws -> [UInt8] {
            switch kind {
            case "text":
                let text = TextNode(slice: .empty, baseUri: nil)
                for slice in slices { text.appendSlice(slice) }
                return text.getWholeTextUTF8()
            case "data":
                let data = DataNode(slice: .empty, baseUri: [])
                for slice in slices { data.appendSlice(slice) }
                return data.getWholeDataUTF8()
            case "attribute":
                let attr = try Attribute(key: "x", value: "")
                for slice in slices { attr.appendValueSlice(slice) }
                return attr.getValueUTF8()
            case "parse-coalesced", "parse-discarded":
                let parser = Parser.htmlParser().settings(ParseSettings(false, false, kind != "parse-coalesced"))
                return try parser.parseInput(interrupted, "").textUTF8()
            case "parse-text":
                return try SwiftSoup.parse(markup).textUTF8()
            case "parse-attribute":
                let doc = try SwiftSoup.parse(markup)
                doc.materializeAttributesRecursively()
                return try doc.getElementsByTag("p").first()!.attr(Array("title".utf8))
            default:
                return Array(try SwiftSoup.parse(script).getElementsByTag("script").first()!.data().utf8)
            }
        }
        let expected = ["parse-coalesced", "parse-discarded"].contains(kind)
            ? Array(String(repeating: "日本語", count: count).utf8)
            : kind == "parse-script" ? Array(scriptText.utf8) : kind.hasPrefix("parse-") ? decoded : flat
        XCTAssertEqual(try operation(), expected)
        var checksum: UInt64 = 0
        for _ in 0..<3 { checksum &+= UInt64(try operation().count) }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { checksum &+= UInt64(try operation().count) }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        XCTAssertEqual(checksum, UInt64(iterations + 3) * UInt64(expected.count))
        let result: [String: Any] = ["operation":kind,"fragments":count,"iterations":iterations,
            "warmups":3,"elapsed_ms":Double(elapsed)/1_000_000,"checksum":String(checksum)]
        print("SWIFTSOUP_FRAGMENT_RESULT " + String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
    func testParsingCoalescedTextWithoutSourceRanges() throws { try benchmark("parse-coalesced") }
    func testParsingDiscardedTagsWithSourceRanges() throws { try benchmark("parse-discarded") }
    func testTextAppend() throws { try benchmark("text") }
    func testDataAppend() throws { try benchmark("data") }
    func testAttributeAppend() throws { try benchmark("attribute") }
    func testEntityTextParsing() throws { try benchmark("parse-text") }
    func testEntityAttributeParsing() throws { try benchmark("parse-attribute") }
    func testScriptParsing() throws { try benchmark("parse-script") }
}
