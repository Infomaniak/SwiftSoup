// Public-API benchmark. Build with -O against the matching SwiftSoup module.
// Run <workload> <iterations>, --verify, or --list. Cache disabled explicitly.
import Foundation
import SwiftSoup

struct SearchCase {
    let name: String
    let input: String
    let needle: String
    let prefix: String
    let skip: String
}
let japanese = "日本語文"
let mixed = "日e\u{301}👩🏽‍💻🇯🇵\r\n"
let cases: [SearchCase] = [
    SearchCase(name: "early-ascii", input: "(" + String(repeating: "x", count: 2048), needle: "(", prefix: "", skip: ""),
    SearchCase(name: "tiny-ascii", input: "li:eq(1)", needle: "(", prefix: "li:eq", skip: ""),
    SearchCase(name: "late-ascii-2048", input: String(repeating: "x", count: 2048) + ")tail", needle: ")", prefix: String(repeating: "x", count: 2048), skip: ""),
    SearchCase(name: "late-japanese-128", input: String(repeating: japanese, count: 32) + ")tail", needle: ")", prefix: String(repeating: japanese, count: 32), skip: ""),
    SearchCase(name: "late-japanese-512", input: String(repeating: japanese, count: 128) + ")tail", needle: ")", prefix: String(repeating: japanese, count: 128), skip: ""),
    SearchCase(name: "late-japanese-2048", input: String(repeating: japanese, count: 512) + ")tail", needle: ")", prefix: String(repeating: japanese, count: 512), skip: ""),
    SearchCase(name: "miss-japanese-512", input: String(repeating: japanese, count: 128), needle: ")", prefix: "", skip: ""),
    SearchCase(name: "mixed-graphemes", input: String(repeating: mixed, count: 128) + ")tail", needle: ")", prefix: String(repeating: mixed, count: 128), skip: ""),
    SearchCase(name: "offset-japanese", input: "skip" + String(repeating: japanese, count: 128) + ")tail", needle: ")", prefix: String(repeating: japanese, count: 128), skip: "skip"),
    SearchCase(name: "canonical-match", input: String(repeating: "日", count: 512) + "e\u{301}tail", needle: "é", prefix: String(repeating: "日", count: 512), skip: "")
]
let names = cases.map(\.name) + ["numeric-parse-512", "normal-parse-control"]
QueryParser.cache = nil

func makeOperation(_ name: String) throws -> () throws -> Int {
    if let fixture = cases.first(where: { $0.name == name }) {
        return {
            let q = TokenQueue(fixture.input)
            if !fixture.skip.isEmpty { try q.consume(fixture.skip) }
            let consumed = q.consumeTo(fixture.needle)
            return consumed.utf8.count &+ q.toString().utf8.count
        }
    }
    if name == "numeric-parse-512" {
        let query = "li:eq(" + String(repeating: "0", count: 512) + "1)"
        return { try QueryParser.parse(query).toString().utf8.count }
    }
    if name == "normal-parse-control" {
        let html = "<article>" + String(repeating: "<p>日本語の文章 <em>example</em></p>", count: 64) + "</article>"
        return {
            let doc = try SwiftSoup.parse(html)
            return try doc.select("p").size() + doc.text().utf8.count
        }
    }
    throw NSError(domain: "Unknown workload", code: 1)
}
func output(_ object: Any) throws {
    let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(decoding: bytes, as: UTF8.self))
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--list" {
    try output(names)
} else if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--verify" {
    var records: [[String: Any]] = []
    for fixture in cases {
        let q = TokenQueue(fixture.input)
        if !fixture.skip.isEmpty { try q.consume(fixture.skip) }
        let consumed = q.consumeTo(fixture.needle)
        precondition(Array(consumed.utf8) == Array(fixture.prefix.utf8))
        records.append(["name": fixture.name, "prefix": Array(consumed.utf8), "remainder": Array(q.toString().utf8)])
    }
    for count in [0, 1, 8, 32, 128] {
        let html = "<article>" + String(repeating: "<p>日e\u{301}<ruby>語<rt>ご</rt></ruby></p>", count: count) + "</article>"
        let doc = try SwiftSoup.parse(html)
        records.append(["html": Array(try doc.outerHtml().utf8), "text": Array(try doc.text().utf8), "count": try doc.select("p").size()])
    }
    try output(records)
} else {
    guard CommandLine.arguments.count == 3, let iterations = Int(CommandLine.arguments[2]), iterations > 0 else {
        fatalError("Use --list, --verify, or <workload> <positive iterations>")
    }
    let name = CommandLine.arguments[1]
    let operation = try makeOperation(name)
    let expected = try operation()
    for _ in 0..<3 { let value = try operation(); precondition(value == expected) }
    var checksum = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { checksum &+= try operation() }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    precondition(checksum == expected &* iterations)
    try output(["workload": name, "iterations": iterations, "elapsed_ns": elapsed, "checksum": checksum, "expected": expected])
}
