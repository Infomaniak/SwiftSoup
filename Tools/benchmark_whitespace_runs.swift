// Build against a release SwiftSoup library without -enable-testing.
import Foundation
import Dispatch
import SwiftSoup
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

func option(_ name: String, _ fallback: String) -> String {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return fallback }
    return CommandLine.arguments[i + 1]
}
let workload = option("--workload", "text-japanese")
guard let iterations = Int(option("--iterations", "100")), iterations > 0,
      let size = Int(option("--size", "128")), (1...4096).contains(size) else {
    fatalError("Iterations must be positive; size must be 1...4096")
}
let japanese = String(repeating: "日本語の文章を読んで言葉の意味を理解します。", count: 8)
let pieces: [String]
switch workload {
case "text-ascii": pieces = (0..<size).map { "\tArticle \($0) " + String(repeating: "A reader learns words and phrases. ", count: 8) + "\nEnd" }
case "text-short": pieces = (0..<size).map { "\t日本語\($0)\nです" }
case "text-mixed": pieces = (0..<size).map { "\t\($0) " + String(repeating: "日本語abc😀e\u{301}文章\u{a0} 次\n", count: 8) }
case "text-plain": pieces = (0..<size).map { _ in japanese }
case "text-japanese", "textnode", "owntext", "parse-text", "raw":
    pieces = (0..<size).map { "\t" + japanese + "\n段落\($0)\u{a0}" + japanese }
default: fatalError("Unknown workload: \(workload)")
}
let html = "<main>" + pieces.map { "<p>\($0)</p>" }.joined() + "</main>"
let doc = try SwiftSoup.parse(html)
let root = try doc.select("main").first()!
let paragraphs = try doc.select("p").array()
let nodes = pieces.map { TextNode($0, "") }
let run: () throws -> Int
switch workload {
case "textnode": run = { nodes.reduce(0) { $0 &+ $1.text().utf8.count } }
case "owntext": run = { paragraphs.reduce(0) { $0 &+ $1.ownText().utf8.count } }
case "parse-text": run = { try SwiftSoup.parse(html).text().utf8.count }
case "raw": run = { try root.text(trimAndNormaliseWhitespace: false).utf8.count }
default: run = { try root.text().utf8.count }
}
if CommandLine.arguments.contains("--verify") {
    let outputs: [String: Any] = ["text": try root.text(), "raw": try root.text(trimAndNormaliseWhitespace: false),
                                "bytes": try root.textUTF8(), "slice": Array(try root.textUTF8Slice()),
                                "own": paragraphs.map { $0.ownText() }, "nodes": nodes.map { $0.text() },
                                "html": try doc.outerHtml(), "checksum": try run()]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: outputs, options: [.sortedKeys]))
    exit(0)
}
for _ in 0..<3 { _ = try run() }
let start = DispatchTime.now().uptimeNanoseconds
var checksum = 0
for _ in 0..<iterations { checksum &+= try run() }
let nanos = DispatchTime.now().uptimeNanoseconds - start
let result: [String: Any] = ["workload": workload, "size": size, "iterations": iterations,
                           "elapsed_ns": nanos, "ns_per_op": Double(nanos) / Double(iterations), "checksum": checksum]
print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
