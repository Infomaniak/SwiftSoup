// Build against the complete shipping SwiftSoup library, not an extracted helper.
import Foundation
import SwiftSoup

func originalWord(_ ch: Character) -> Bool {
    let scalars = String(ch).precomposedStringWithCanonicalMapping.unicodeScalars
    return scalars.count == 1 && (CharacterSet.letters.contains(scalars.first!) || CharacterSet.decimalDigits.contains(scalars.first!))
}

func verify() throws {
    var records = [[String: String]]()
    var spellings = (UInt32(0)..<128).map { String(UnicodeScalar($0)!) }
    spellings += ["日本語", "é", "e\u{0301}", "Å", "Å", "K", "١", "２", "𝟡", "Ⅸ", "👩🏽‍💻", "🇯🇵", "\r\n", "\0", "a\u{20E3}", "가"]
    var seed: UInt64 = 0xc1a551f1
    for _ in 0..<1024 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        if let scalar = UnicodeScalar(UInt32(seed % 0x110000)) { spellings.append(String(scalar)) }
    }
    for text in spellings {
        let q = TokenQueue(text + "!tail")
        let expected = String(text.prefix { originalWord($0) })
        let word = q.consumeWord()
        precondition(Array(word.utf8) == Array(expected.utf8))
        let remainder = String(text.dropFirst(expected.count)) + "!tail"
        precondition(Array(q.toString().utf8) == Array(remainder.utf8))
        records.append(["input": Data(text.utf8).base64EncodedString(), "word": Data(word.utf8).base64EncodedString(), "remainder": Data(q.toString().utf8).base64EncodedString()])
    }
    let doc = try SwiftSoup.parse("<main><section class='article'><p id='a'>日本語</p><p id='b'>two</p></section><section><p id='c'>three</p></section></main>")
    for query in ["main > section.article:nth-child(2n + 1) p:contains(日本語)", "main section p", "p", "main > section > p:nth-child(2)", "section:has(p)"] {
        records.append(["query": query, "evaluator": try QueryParser.parse(query).toString(), "ids": try doc.select(query).array().map { $0.id() }.joined(separator: ","), "html": try doc.outerHtml()])
    }
    print(String(decoding: try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]), as: UTF8.self))
}

func workload(_ name: String) throws -> () throws -> Int {
    switch name {
    case "ascii-letters", "ascii-mixed", "unicode-mixed", "start-tags":
        let values: [String]
        if name == "ascii-mixed" { values = (UInt32(0)..<128).map { String(UnicodeScalar($0)!) } }
        else if name == "unicode-mixed" { values = ["日", "é", "e\u{0301}", "١", "２", "👩🏽‍💻", "🇯🇵", "\r\n", "a\u{20E3}", "가"] }
        else { values = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init) }
        let queues = values.map { TokenQueue((name == "start-tags" ? "<" : "") + $0 + "!") }
        return { var total = 0; for q in queues { total += (name == "start-tags" ? q.matchesStartTag() : q.matchesWord()) ? 1 : 0 }; return total }
    case "word-short":
        return { let q = TokenQueue("article42:tail"); return q.consumeWord().utf8.count + q.toString().utf8.count }
    case "tag-name":
        return { let q = TokenQueue("custom-component_12:part!"); return q.consumeTagNameSlice().utf8.count + q.toString().utf8.count }
    case "word-unicode":
        return { let q = TokenQueue("日本語éclair２:tail"); return q.consumeWord().utf8.count + q.toString().utf8.count }
    case "selector-parse", "selector-tags", "selector-unicode":
        let query = name == "selector-parse" ? "main > section.article:nth-child(2n + 1) p:contains(日本語)" : (name == "selector-tags" ? "main section article header span" : "本 > 節 文章")
        let doc = try SwiftSoup.parse("<main><section class='article'><p>日本語</p></section></main>")
        let leaf = try doc.select("p").first()!
        return { let evaluator = try QueryParser.parse(query); return try evaluator.matches(doc, leaf) ? 1 : 0 }
    case "parse-control":
        let html = "<main>" + (0..<128).map { "<section class='article'><p id='p\($0)'>日本語 and English</p></section>" }.joined() + "</main>"
        return { let doc = try SwiftSoup.parse(html); return try doc.select("p").size() + doc.text().utf8.count }
    default: fatalError("Unknown workload: \(name)")
    }
}

QueryParser.cache = nil
if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--verify" {
    try verify()
} else {
    guard CommandLine.arguments.count == 3, let iterations = Int(CommandLine.arguments[2]), iterations > 0 else { fatalError("Usage: client --verify | workload positive-iterations") }
    let name = CommandLine.arguments[1]
    let operation = try workload(name)
    let expected = try operation()
    for _ in 0..<3 { let result = try operation(); precondition(result == expected) }
    let start = DispatchTime.now().uptimeNanoseconds
    var checksum = 0
    for _ in 0..<iterations { checksum += try operation() }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    precondition(checksum == expected * iterations)
    let result: [String: Any] = ["workload": name, "iterations": iterations, "elapsed_ns": elapsed, "expected": expected, "checksum": checksum]
    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
}
