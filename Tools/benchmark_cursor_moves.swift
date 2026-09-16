import Foundation
import SwiftSoup

// Public-client benchmark. Compile the same file against each matching module.
// Fixture setup is outside timing unless the workload name starts with parse-.
QueryParser.cache = nil
let arguments = CommandLine.arguments
func verify() throws {
    var records: [[String: Any]] = []
    let samples = ["", "Abc", "日本語", "e\u{301}Éx", "👩🏽‍💻🇯🇵\r\nA", "İıΣσς", "a\0b"]
    for text in samples {
        for needle in samples {
            let q = TokenQueue(text)
            records.append(["source": Array(text.utf8), "needle": Array(needle.utf8),
                            "cs": q.matchesCS(needle), "ci": q.matches(needle), "after": Array(q.toString().utf8)])
        }
    }
    for n in [1, 2, 8, 32] {
        for from in 0..<n {
            for to in 0..<n {
                let set = OrderedSet(sequence: 0..<n)
                var model = Array(0..<n)
                model.insert(model.remove(at: from), at: to)
                set.moveObject(from, toIndex: to)
                precondition(Array(set) == model)
                let positions = model.map { set.index(of: $0)! }
                precondition(positions == Array(0..<n))
                records.append(["width": n, "from": from, "to": to, "values": Array(set), "indices": positions])
            }
        }
    }
    let doc = try SwiftSoup.parse("<main><p class='日本語'>École</p><p>other</p></main>")
    records.append(["html": try doc.outerHtml(), "text": try doc.text(),
                    "selected": try doc.select("main > p:nth-child(2n + 1)").array().map { try $0.outerHtml() }])
    let data = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}
if arguments.count == 2 && arguments[1] == "--verify" {
    try verify()
    exit(0)
}
precondition(arguments.count == 3, "Usage: client WORKLOAD ITERATIONS or --verify")
let name = arguments[1]
let iterations = Int(arguments[2])!
precondition(iterations > 0)
let operation: () throws -> Int
if name.hasPrefix("region-") || name.hasPrefix("prefix-") {
    var needle: String
    var text: String
    var offsetPrefix = ""
    switch name {
    case "region-short": needle = "DIV"; text = "div"
    case "region-ascii-512": needle = String(repeating: "A", count: 512); text = needle.lowercased() + "tail"
    case "region-unicode-128": needle = String(repeating: "日", count: 128); text = needle + "tail"
    case "region-unicode-512", "prefix-unicode-512": needle = String(repeating: "日", count: 512); text = needle + "tail"
    case "region-long-tail": needle = "div"; text = "DiV" + String(repeating: "日", count: 2048)
    case "region-offset": needle = String(repeating: "本", count: 128); offsetPrefix = String(repeating: "日", count: 512); text = offsetPrefix + needle + "tail"
    case "region-miss": needle = "x"; text = String(repeating: "日", count: 2048)
    case "prefix-short": needle = "div"; text = "div"
    default: fatalError("unknown workload")
    }
    let q = TokenQueue(text)
    if !offsetPrefix.isEmpty { try q.consume(offsetPrefix) }
    let cs = name.hasPrefix("prefix-")
    operation = {
        var sum = 0
        for _ in 0..<16 { sum += (cs ? q.matchesCS(needle) : q.matches(needle)) ? 2 : 1 }
        return sum
    }
} else if name.hasPrefix("move-") {
    let n: Int
    let from: Int
    let to: Int
    switch name {
    case "move-wide-16": n = 16; from = 0; to = 15
    case "move-wide-128": n = 128; from = 0; to = 127
    case "move-wide-1024": n = 1024; from = 0; to = 1023
    case "move-middle-128": n = 128; from = 32; to = 96
    case "move-adjacent-4096": n = 4096; from = 2048; to = 2049
    case "move-noop-128": n = 128; from = 32; to = 32
    case "move-absent-128": n = 128; from = -1; to = 0
    default: fatalError("unknown workload")
    }
    let set = OrderedSet(sequence: 0..<n)
    operation = {
        set.moveObject(from, toIndex: to)
        let moved = set.index(of: from) ?? -1
        if from >= 0 { set.moveObject(from, toIndex: from) }
        return moved + set.count + (set.index(of: from) ?? -1) + 2
    }
} else if name == "parse-selector" {
    // Typical, short ASCII selector grammar with Unicode content. No query cache.
    let query = "main > section.article:nth-child(2n + 1) p:contains(日本語)"
    operation = { let parsed = try QueryParser.parse(query); return parsed.toString().utf8.count }
} else if name == "parse-control" {
    let html = "<main>" + (0..<128).map { "<section id='n\($0)'><p>日本語の文章 \($0)</p></section>" }.joined() + "</main>"
    operation = { let doc = try SwiftSoup.parse(html); return try doc.text().utf8.count + doc.select("p").size() }
} else { fatalError("unknown workload") }
let expected = try operation()
for _ in 0..<3 { let value = try operation(); precondition(value == expected) }
let start = DispatchTime.now().uptimeNanoseconds
var checksum = 0
for _ in 0..<iterations { checksum += try operation() }
let elapsed = DispatchTime.now().uptimeNanoseconds - start
precondition(checksum == expected * iterations)
let data = try JSONSerialization.data(withJSONObject: ["workload": name, "iterations": iterations,
    "elapsed_ns": elapsed, "expected": expected, "checksum": checksum], options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
