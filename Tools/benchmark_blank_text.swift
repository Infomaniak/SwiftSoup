import Foundation
import SwiftSoup

func reference(_ text: String) -> Bool { text.allSatisfy { StringUtil.isWhitespace($0) } }

func verify() throws -> [[String: Any]] {
    var records: [[String: Any]] = []
    // Every Unicode scalar: independently exercise the old Character predicate.
    var validScalars = 0
    var whitespaceScalars: [UInt32] = []
    for value in UInt32(0)...0x10FFFF {
        guard let scalar = UnicodeScalar(value) else { continue }
        let text = String(scalar)
        let expected = reference(text)
        precondition(StringUtil.isBlank(text) == expected, "scalar \(value)")
        if expected { whitespaceScalars.append(value) }
        validScalars += 1
    }
    records.append(["scalar_count": validScalars, "whitespace_scalars": whitespaceScalars])
    let values = ["", " \t\r\n\u{c}", "\u{b}", "\u{a0}", " \u{301}", "e\u{301}", "👩🏽‍💻", "🇯🇵", "日本語", String(repeating: " \r\n", count: 4096)]
    for value in values {
        let node = TextNode(value, nil)
        let result = node.isBlank()
        precondition(result == reference(value))
        records.append(["input": Array(value.utf8), "blank": result, "retained": node.getWholeTextUTF8()])
    }
    for value in UInt16(0)...255 {
        let bytes = [UInt8(32), UInt8(value), 13, 10]
        let node = TextNode(bytes, nil)
        let result = node.isBlank()
        precondition(result == reference(String(decoding: bytes, as: UTF8.self)))
        records.append(["input": bytes, "blank": result, "retained": node.getWholeTextUTF8()])
    }
    for shape in 0..<16 {
        let doc = try SwiftSoup.parse("<main><p> \r\n </p><p>日本 &amp; text</p><p>&nbsp;</p><pre> \r\n </pre></main>")
        doc.outputSettings().prettyPrint(pretty: shape % 2 == 0)
        let nodes = try doc.select("p")
        if shape % 3 == 0 { try nodes.first()!.text(shape % 2 == 0 ? "" : "changed") }
        records.append(["shape": shape, "hasText": nodes.array().map { $0.hasText() }, "eachText": try nodes.eachText(), "html": try doc.outerHtmlUTF8(), "text": Array(try doc.text().utf8)])
    }
    return records
}

func workload(_ name: String) throws -> () throws -> Int {
    let whitespace = String(repeating: " \t\r\n\u{c}", count: 1024)
    let japanese = String(repeating: "日本語の文章", count: 1024)
    switch name {
    case "string-blank-long", "string-short", "string-unicode":
        let text = name == "string-short" ? " \t " : name == "string-unicode" ? japanese : whitespace
        return { StringUtil.isBlank(text) ? 1 : 2 }
    case "node-blank-long", "node-short", "node-unicode", "node-late-text":
        let text = name == "node-short" ? " " : name == "node-unicode" ? japanese : name == "node-late-text" ? whitespace + "日" : whitespace
        let node = TextNode(text, nil)
        return { node.isBlank() ? 1 : 2 }
    case "node-custom":
        final class Custom: TextNode { override func getWholeText() -> String { " \t " } }
        let node = Custom("ignored", nil)
        return { node.isBlank() ? 1 : 2 }
    case "hastext-blank", "hastext-nonblank", "serialize-pretty":
        let doc = Document.createShell("")
        let body = doc.body()!
        let value = name == "hastext-nonblank" ? japanese : String(repeating: " \t\r\n", count: 128)
        for _ in 0..<128 {
            let p = try body.appendElement("p")
            try p.appendText(value)
        }
        if name == "serialize-pretty" {
            return { try doc.outerHtmlUTF8().count }
        }
        return { body.hasText() ? 1 : 2 }
    case "parse-hastext", "parse-control":
        let paragraph = name == "parse-control" ? "<p>日本語 &amp; ordinary text <em>強調</em></p>" : "<p> \t\r\n </p>"
        let html = "<main>" + String(repeating: paragraph, count: 128) + "</main>"
        return {
            let doc = try SwiftSoup.parse(html)
            if name == "parse-hastext" { return try doc.select("p").array().reduce(0) { $0 + ($1.hasText() ? 1 : 2) } }
            return try doc.select("p").size()
        }
    default: fatalError("Unknown workload: \(name)")
    }
}

do {
    let args = CommandLine.arguments
    if args.count == 2 && args[1] == "--verify" {
        let data = try JSONSerialization.data(withJSONObject: verify(), options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } else {
        guard args.count == 3, let iterations = Int(args[2]), iterations > 0 else { fatalError("workload positive-iterations, or --verify") }
        let operation = try workload(args[1])
        let expected = try operation()
        for _ in 0..<3 { let value = try operation(); precondition(value == expected) }
        var checksum = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { checksum += try operation() }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        precondition(checksum == expected * iterations)
        let data = try JSONSerialization.data(withJSONObject: ["workload": args[1], "iterations": iterations, "expected": expected, "checksum": checksum, "elapsed_ns": elapsed], options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
