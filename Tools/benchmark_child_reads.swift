// Standalone public-API client. Build against each matching shipping module/library.
// Do not time compilation, fixture construction (except parse-*), or verification.
import Foundation
import SwiftSoup

private final class ProjectedParent: Element {
    override func children() -> Elements { super.children() }
}

private struct Fixture {
    let parent: Element
    let elements: [Element]
}

private func fixture(_ count: Int, mixed: Bool = false, custom: Bool = false) throws -> Fixture {
    let parent: Element = custom
        ? try ProjectedParent(Tag.valueOf("main"), "")
        : try Element(Tag.valueOf("main"), "")
    var elements: [Element] = []
    for i in 0..<count {
        if mixed {
            try parent.appendChild(TextNode("日\(i)", ""))
            try parent.appendChild(Comment([120], []))
        }
        let child = try Element(Tag.valueOf("p"), "")
        try child.attr("id", "n\(i)")
        try child.appendText("日本語\(i)")
        try parent.appendChild(child)
        elements.append(child)
    }
    return Fixture(parent: parent, elements: elements)
}

private func verification() throws -> Data {
    var records: [[String: Any]] = []
    for width in [0, 1, 2, 3, 8, 32, 128] {
        for mixed in [false, true] {
            for custom in [false, true] {
                let f = try fixture(width, mixed: mixed, custom: custom)
                let eval = Evaluator.IsOnlyChild()
                var positions: [Int] = []
                var only: [Bool] = []
                for i in 0..<width {
                    let got = f.parent.child(i)
                    precondition(got === f.elements[i])
                    positions.append(got.siblingIndex)
                    let match = try eval.matches(f.parent, got)
                    precondition(match == (width == 1))
                    only.append(match)
                }
                let before = try f.parent.outerHtml()
                let selected = try f.parent.select(eval).array().map { $0.id() }
                if width > 1 {
                    try f.elements.last!.remove()
                    for i in 0..<(width-1) { precondition(f.parent.child(i) === f.elements[i]) }
                }
                records.append(["width":width, "mixed":mixed, "custom":custom,
                                "positions":positions, "only":only, "selection":selected,
                                "before":before, "after":try f.parent.outerHtml()])
            }
        }
    }
    return try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
}

private func operation(_ name: String) throws -> () throws -> Int {
    if name == "parse-control" || name == "parse-child" || name == "parse-only" {
        let html = (0..<128).map { "<section><p id='n\($0)'>日本語\($0)</p><em>text</em></section>" }.joined()
        let evaluator = Evaluator.IsOnlyChild()
        return {
            let document = try SwiftSoup.parse(html)
            if name == "parse-control" {
                return try document.text().utf8.count + document.select("p").size()
            }
            if name == "parse-only" { return try document.select(evaluator).size() }
            let body = document.body()!
            var sum = 0
            for i in 0..<128 { sum += body.child(i).child(0).siblingIndex + 1 }
            return sum
        }
    }
    if name == "only-unary-256" {
        let fixtures = try (0..<256).map { _ in try fixture(1, mixed: true) }
        let evaluator = Evaluator.IsOnlyChild()
        return {
            var sum = 0
            for f in fixtures { sum += try evaluator.matches(f.parent, f.elements[0]) ? 1 : 0 }
            return sum
        }
    }
    let parts = name.split(separator: "-")
    guard let count = Int(parts.last!) else { fatalError("Unknown workload \(name)") }
    let f = try fixture(count, mixed: name.contains("mixed"), custom: name.contains("custom"))
    if name.hasPrefix("only-") {
        let evaluator = Evaluator.IsOnlyChild()
        if name.contains("select") {
            return { try f.parent.select(evaluator).size() }
        }
        return {
            var sum = 0
            for child in f.elements {
                sum += try evaluator.matches(f.parent, child) ? 1 : 0
            }
            return sum
        }
    }
    let indices: [Int]
    if name.contains("all") { indices = Array(0..<count) }
    else if name.contains("last") { indices = Array(repeating: count-1, count: 32) }
    else if name.contains("middle") { indices = Array(repeating: count/2, count: 32) }
    else { indices = Array(repeating: 0, count: 32) }
    return {
        var sum = 0
        for index in indices { sum += f.parent.child(index).siblingIndex + 1 }
        return sum
    }
}

let args = CommandLine.arguments
if args.count == 2 && args[1] == "--verify" {
    FileHandle.standardOutput.write(try verification())
    print("")
} else if args.count == 3 && args[1] == "--invalid-child" {
    let f = try fixture(2)
    _ = f.parent.child(Int(args[2])!)
    fatalError("Invalid child unexpectedly returned")
} else {
    guard args.count == 3, let iterations = Int(args[2]), iterations > 0 else {
        fatalError("Usage: client <workload> <positive iterations>, or --verify")
    }
    let name = args[1], work = try operation(name)
    let expected = try work()
    for _ in 0..<3 { let value = try work(); precondition(value == expected) }
    var checksum = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { checksum &+= try work() }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    precondition(checksum == expected * iterations)
    let record: [String: Any] = ["workload":name, "iterations":iterations,
                               "elapsed_ns":elapsed, "expected":expected, "checksum":checksum]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:record, options:[.sortedKeys]))
    print("")
}
