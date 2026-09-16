import Foundation
import SwiftSoup
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}
let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String, _ fallback: String) -> String {
    guard let i = args.firstIndex(of: name) else { return fallback }
    guard i + 1 < args.count else { fail("Missing value for \(name)") }
    return args[i + 1]
}
let workload = option("--workload", "escape-japanese")
guard let iterations = Int(option("--iterations", "100")), iterations > 0,
      let size = Int(option("--size", "256")), size > 0,
      let warmups = Int(option("--warmups", "3")), warmups >= 0 else { fail("Invalid count") }
let settings = OutputSettings().charset(.utf8).prettyPrint(pretty: false)
let phrase = "吾輩は猫である名前はまだ無い。"
let escapeInputs: [String]
switch workload {
case "escape-japanese": escapeInputs = (0..<8).map { String(repeating: phrase, count: size) + "&\($0)" }
case "escape-mixed": escapeInputs = (0..<8).map { String(repeating: "日本語を読む & 東京<京都> 👩🏽‍💻 café e\u{301}\u{A0}\n", count: size) + "\($0)" }
case "escape-ascii": escapeInputs = (0..<8).map { String(repeating: "A readable ASCII phrase & <markup> \"quote\".", count: size) + "\($0)" }
case "escape-plain": escapeInputs = (0..<8).map { String(repeating: phrase, count: size) + "\($0)" }
case "escape-short": escapeInputs = ["&猫", "é&", "猫<&", "abc&", "aé&", "👩🏽‍💻&", "\u{A0}&", ""]
default: escapeInputs = []
}
let entityText: String
switch workload {
case "unescape-multi", "parse-multi-string", "parse-multi-data", "parse-multi-buffer":
    entityText = "&NotEqualTilde;&NotGreaterFullEqual;&NotNestedGreaterGreater;&NotSquareSubset;"
case "unescape-long", "parse-long-string", "parse-long-data", "parse-long-buffer":
    entityText = "&CounterClockwiseContourIntegral;&ClockwiseContourIntegral;&DoubleLongLeftRightArrow;"
case "unescape-unknown", "parse-unknown-string":
    entityText = "&NotARealLongEntity;&AnotherMissingName;&UnknownReference;"
case "unescape-common", "parse-common-string": entityText = "&amp;&lt;&quot;&nbsp;&#x732b;"
case "parse-normal-string", "parse-normal-data": entityText = "日本語の記事です。東京と京都の本を読みます。 text &amp; reading."
default: entityText = ""
}
let unescapeInputs = (0..<8).map { String(repeating: entityText, count: size) + "\($0)" }
let htmlInputs = (0..<8).map { index in
    "<html><head><title>Article \(index)</title></head><body>" +
    (0..<size).map { "<p data-seq='\($0)'>\(entityText)</p>" }.joined() + "</body></html>"
}
let dataInputs = htmlInputs.map { Data($0.utf8) }
let byteInputs = htmlInputs.map { Array($0.utf8) }
let document = Document("")
document.outputSettings().prettyPrint(pretty: false).charset(.utf8)
if workload == "serialize-japanese" {
    let body = try document.appendElement("body")
    for i in 0..<size {
        try body.appendElement("p").attr("title", phrase + "&\(i)").text(String(repeating: phrase, count: 8) + " & \(i)")
    }
}
@inline(never)
func runOne(_ i: Int) throws -> String {
    let index = i & 7
    if workload.hasPrefix("escape-") { return Entities.escape(escapeInputs[index], settings) }
    if workload.hasPrefix("unescape-") { return try Entities.unescape(unescapeInputs[index]) }
    if workload == "serialize-japanese" { return try document.outerHtml() }
    if workload.hasPrefix("parse-") {
        let doc: Document
        if workload.hasSuffix("-data") {
            doc = try SwiftSoup.parse(dataInputs[index])
        } else if workload.hasSuffix("-buffer") {
            doc = try SwiftSoup.parse(withBytes: { parse in
                try byteInputs[index].withUnsafeBufferPointer { try parse($0) }
            })
        } else {
            doc = try SwiftSoup.parse(htmlInputs[index])
        }
        return try doc.text()
    }
    fail("Unknown workload \(workload)")
}
if args.contains("--verify") {
    for i in 0..<8 { print(Data(try runOne(i).utf8).base64EncodedString()) }
} else {
    var checksum = 0
    for i in 0..<warmups { checksum &+= try runOne(i).utf8.count }
    var cpuStart = timespec()
    guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpuStart) == 0 else { fail("CPU clock unavailable") }
    let start = DispatchTime.now().uptimeNanoseconds
    for i in 0..<iterations { checksum &+= try runOne(i).utf8.count }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    var cpuEnd = timespec()
    guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpuEnd) == 0 else { fail("CPU clock unavailable") }
    let cpu = (cpuEnd.tv_sec - cpuStart.tv_sec) * 1_000_000_000 + cpuEnd.tv_nsec - cpuStart.tv_nsec
    let result: [String: Any] = ["workload": workload, "size": size, "iterations": iterations,
        "warmups": warmups, "nanoseconds": elapsed, "cpu_nanoseconds": cpu, "checksum": checksum]
    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
}
