import Foundation
import SwiftSoup

private func emit(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

private func markup(_ width: Int, dropEvery: Int = 2, descendants: Int = 0) -> String {
    "<main>" + (0..<width).map { i in
        "<section id='n\(i)' class='\(i % dropEvery == 0 ? "drop" : "keep")'>日本語 \(i)" +
        (0..<descendants).map { j in "<span id='d\(i)-\(j)' class='drop'>text</span>" }.joined() + "</section>"
    }.joined() + "</main>"
}

private func verification() throws {
    var records: [[String: Any]] = []
    for width in [0, 1, 8, 63, 64, 65, 128, 512] {
        for descendants in [0, 3] {
            let document = try SwiftSoup.parse(markup(width, descendants: descendants))
            let roots = try document.select("section").array()
            let input = roots + roots.reversed()
            let list = Elements(input)
            for round in 0..<4 {
                if round > 0, let first = roots.first {
                    try first.attr("class", round % 2 == 0 ? "drop" : "keep")
                    if round == 2 { try first.remove() }
                    if round == 3 { try document.body()!.appendChild(first) }
                }
                let expected = try input.filter { !$0.hasClass("drop") }.map { try $0.attr("id") }
                let a = try list.not(".drop").map { try $0.attr("id") }
                let b = try list.not(Evaluator.Class("drop")).map { try $0.attr("id") }
                precondition(a == expected && b == expected)
                records.append(["width": width, "descendants": descendants, "round": round,
                                "string": a, "evaluator": b, "html": try document.outerHtml(),
                                "input": try input.map { try $0.attr("id") }])
            }
        }
    }
    try emit(records)
}

private func main() throws {
    let args = CommandLine.arguments
    if args.count == 2 && args[1] == "--verify" { try verification(); return }
    guard args.count == 3, let iterations = Int(args[2]), iterations > 0 else {
        throw NSError(domain: "benchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "usage: benchmark WORKLOAD ITERATIONS | --verify"])
    }
    let name = args[1]
    let operation: () throws -> UInt64
    if name == "parse-control" || name == "parse-not" {
        let html = markup(512)
        operation = {
            let document = try SwiftSoup.parse(html)
            let list = try document.select("section")
            return UInt64(try (name == "parse-not" ? list.not(".drop").size() : document.text().utf8.count))
        }
    } else {
        let width: Int
        let dropEvery: Int
        let descendants: Int
        switch name {
        case "not-8": (width, dropEvery, descendants) = (8, 2, 0)
        case "not-128": (width, dropEvery, descendants) = (128, 2, 0)
        case "not-512": (width, dropEvery, descendants) = (512, 2, 0)
        case "not-2048": (width, dropEvery, descendants) = (2048, 2, 0)
        case "not-8192": (width, dropEvery, descendants) = (8192, 2, 0)
        case "sparse-control": (width, dropEvery, descendants) = (1024, 128, 0)
        case "descendant-control": (width, dropEvery, descendants) = (64, 2, 64)
        default: throw NSError(domain: "benchmark", code: 2, userInfo: [NSLocalizedDescriptionKey: "unknown workload"])
        }
        let document = try SwiftSoup.parse(markup(width, dropEvery: dropEvery, descendants: descendants))
        let list = try document.select("section")
        let expected = list.array().filter { !$0.hasClass("drop") }
        let check = try list.not(".drop").array()
        precondition(check.map(ObjectIdentifier.init) == expected.map(ObjectIdentifier.init))
        operation = {
            let result = try list.not(".drop")
            var sum = UInt64(result.count)
            for element in result { sum += UInt64(element.siblingIndex + 1) }
            return withExtendedLifetime(document) { sum }
        }
    }
    let expected = try operation()
    for _ in 0..<3 { let warm = try operation(); precondition(warm == expected) }
    var checksum: UInt64 = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { checksum += try operation() }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    precondition(checksum == expected * UInt64(iterations))
    try emit(["workload": name, "iterations": iterations, "elapsed_ns": elapsed,
              "expected": expected, "checksum": checksum])
}
try main()
