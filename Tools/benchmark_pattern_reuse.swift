import Foundation
import Dispatch
import SwiftSoup

func option(_ key: String, _ fallback: String) -> String {
    guard let i = CommandLine.arguments.firstIndex(of: key), i + 1 < CommandLine.arguments.count else { return fallback }
    return CommandLine.arguments[i + 1]
}
let workload = option("--workload", "reused")
guard let iterations = Int(option("--iterations", "100")), iterations > 0 else { fatalError("Positive iterations required") }
let expression = "[0-9]+|日本語"
let texts = (0..<256).map { "日本語 item\($0)" }
let pattern = Pattern.compile(expression)
let markup = "<main>" + texts.prefix(64).map { "<p>\($0)</p>" }.joined() + "</main>"
@inline(never) func operation() throws -> Int {
    var result = 0
    switch workload {
    case "reused":
        for text in texts { result += pattern.matcher(in: text).count }
    case "validated":
        for text in texts { try pattern.validate(); result += pattern.matcher(in: text).count }
    case "fresh":
        for text in texts { result += Pattern.compile(expression).matcher(in: text).count }
    case "unused":
        for text in texts { result += Pattern.compile(expression + text).toString().utf8.count }
    case "parse":
        result = try SwiftSoup.parse(markup).text().utf8.count
    default: fatalError("Unknown workload")
    }
    return result
}
for _ in 0..<3 { _ = try operation() }
var checksum = 0
let start = DispatchTime.now().uptimeNanoseconds
for _ in 0..<iterations { checksum &+= try operation() }
let elapsed = DispatchTime.now().uptimeNanoseconds - start
let record: [String: Any] = ["workload": workload, "iterations": iterations, "elapsed_ns": elapsed,
                           "ns_per_op": Double(elapsed) / Double(iterations), "checksum": checksum]
print(String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self))
