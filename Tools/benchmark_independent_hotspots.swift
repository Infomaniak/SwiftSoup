import Foundation
import SwiftSoup

private final class ReversedBenchmarkParent: Element {
    override func children() -> Elements {
        Elements(Array(super.children().array().reversed()))
    }
}

private func output(_ object: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

private func rules() throws -> Whitelist {
    try Whitelist.none().addTags("main", "p", "b", "span")
        .addAttributes(":all", "style")
        .addCSSProperties(":all", "color", "font-weight", "font-family", "content", "width", "margin", "background-image", "transform")
}

private func markup(_ count: Int, mixed: Bool = false, style: String? = nil) -> String {
    "<main>" + (0..<count).map { i in
        let gap = mixed ? "text<!--gap-->" : ""
        let attribute = style.map { " style=\"\($0)\"" } ?? ""
        return "\(gap)<p id='n\(i)'\(attribute)>日本語 \(i)<b>text</b></p>"
    }.joined() + "</main>"
}

private func verification() throws {
    var records = [[String: Any]]()
    let selectors = [":first-child", ":nth-child(2n)", ":nth-child(3n+1)", ":nth-last-child(2)", ":nth-last-of-type(2)"]
    for width in [1, 2, 8, 32, 128] {
        for mixed in [false, true] {
            let document = try SwiftSoup.parse(markup(width, mixed: mixed))
            let root = try document.select("main").first()!
            for round in 0..<4 {
                let children = root.children().array()
                var selected = [[String]]()
                for query in selectors {
                    selected.append(try root.select(query).map { try $0.attr("id") })
                }
                records.append(["kind": "position", "width": width, "mixed": mixed, "round": round,
                                "positions": try children.map { try $0.elementSiblingIndex() },
                                "ids": try children.map { try $0.attr("id") }, "selection": selected,
                                "html": try root.outerHtml(), "text": try root.text()])
                try root.prependChild(children.last!)
            }
        }
    }
    let rules = try rules()
    let element = try Element(Tag.valueOf("p"), "")
    let values = ["red", "'日本語'", "'cafe\u{301}'", "'👩🏽‍💻'", "'a;b:c'", "url(x)", "exp/*c*/ression(1)", "calc(100% / 2)", "'a/*b*/c'", "'a\\\"b'", "u\u{00A0}rl(x)", "re/**/d", "red/*unterminated", "'unterminated", "\u{301}x", "'∕／⁄'", "'a/\u{301}*b'", "'a*\u{301}/b'", "'a\r\nb'", "'\\/x'"]
    let keys = ["color", "font-family", "content", "width", "unknown"]
    var seed: UInt64 = 0x49abc
    for i in 0..<2048 {
        seed = seed &* 6364136223846793005 &+ 1
        let key = keys[Int(seed % UInt64(keys.count))]
        let value = values[Int((seed >> 12) % UInt64(values.count))]
        let prefix = i % 3 == 0 ? "/*before*/" : ""
        let suffix = i % 5 == 0 ? "; color:blue" : ""
        let style = prefix + key + ":" + value + suffix
        let attribute = try Attribute(key: "style", value: style)
        let cleaned = try rules.safeAttribute("p", element, attribute)
        records.append(["kind": "style", "input": style, "result": cleaned?.getValue() as Any? ?? NSNull(), "original": attribute.getValue()])
    }
    let cleaner = Cleaner(headWhitelist: nil, bodyWhitelist: rules)
    for style in values {
        let document = try SwiftSoup.parse(markup(8))
        for p in try document.select("p") { try p.attr("style", "content:" + style + "; color:red") }
        let before = try document.outerHtml()
        let clean = try cleaner.clean(document)
        records.append(["kind": "clean", "input": before, "originalAfter": try document.outerHtml(),
                        "cleanHTML": try clean.outerHtml(), "cleanText": try clean.text()])
    }
    precondition(!records.isEmpty)
    try output(records)
}

private func run() throws {
    let args = CommandLine.arguments
    if args.count == 2 && args[1] == "--verify" { try verification(); return }
    guard args.count == 3, let iterations = Int(args[2]), iterations > 0 else {
        throw NSError(domain: "benchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "usage: benchmark WORKLOAD ITERATIONS | --verify"])
    }
    let name = args[1]
    let operation: () throws -> UInt64
    switch name {
    case "index-wide", "index-mixed":
        let document = try SwiftSoup.parse(markup(256, mixed: name == "index-mixed"))
        let root = try document.select("main").first()!
        let children = root.children().array()
        operation = { var sum: UInt64 = 0; for e in children { sum &+= UInt64(try e.elementSiblingIndex()) }; return withExtendedLifetime(document) { sum } }
    case "nth-select":
        let document = try SwiftSoup.parse(markup(256, mixed: true))
        let root = try document.select("main").first()!
        let evaluator = Evaluator.IsNthChild(2, 0)
        operation = { withExtendedLifetime(document) {}; return UInt64(try Collector.collect(evaluator, root).size()) }
    case "parse-nth", "parse-control":
        let html = markup(128, mixed: true)
        let evaluator = Evaluator.IsNthChild(2, 0)
        if name == "parse-nth" {
            operation = { let d = try SwiftSoup.parse(html); return UInt64(try Collector.collect(evaluator, d).size()) }
        } else {
            operation = { let d = try SwiftSoup.parse(html); return UInt64(try d.text().utf8.count) }
        }
    case "custom-parent":
        let parent = try ReversedBenchmarkParent(Tag.valueOf("main"), "")
        try parent.append((0..<128).map { "<p>\($0)</p>" }.joined())
        let children = parent.children().array()
        operation = { var sum: UInt64 = 0; for e in children { sum &+= UInt64(try e.elementSiblingIndex()) }; return withExtendedLifetime(parent) { sum } }
    case "css-short", "css-long", "css-slash", "css-comments":
        let rules = try rules()
        let element = try Element(Tag.valueOf("p"), "")
        let style: String
        if name == "css-long" { style = "font-family:'" + String(repeating: "日本語名e\u{301}👩🏽‍💻 ", count: 32) + "'; color:red" }
        else if name == "css-slash" { style = "content:'" + String(repeating: "日本語abcdefgh ", count: 32) + "/'; color:red" }
        else if name == "css-comments" { style = "/*before*/co/*x*/lor:red; content:'a/*b*/c'; width:calc(100% / 2)" }
        else { style = "color:navy; font-weight:bold; margin:0 1em; font-family:'日本語'" }
        let attributes = try (0..<64).map { _ in try Attribute(key: "style", value: style) }
        operation = { var sum: UInt64 = 0; for a in attributes { sum &+= UInt64(try rules.safeAttribute("p", element, a)?.getValue().utf8.count ?? 0) }; return sum }
    case "clean-styled", "parse-clean", "clean-plain":
        let rules = try rules()
        let cleaner = Cleaner(headWhitelist: nil, bodyWhitelist: rules)
        let style = name == "clean-plain" ? nil : "color:navy; font-weight:bold; margin:0 1em; font-family:'日本語'"
        let html = markup(64, style: style)
        let document = try SwiftSoup.parse(html)
        if name == "parse-clean" {
            operation = { let d = try SwiftSoup.parse(html); return UInt64(try cleaner.clean(d).outerHtml().utf8.count) }
        } else {
            operation = { UInt64(try cleaner.clean(document).outerHtml().utf8.count) }
        }
    default: throw NSError(domain: "benchmark", code: 2, userInfo: [NSLocalizedDescriptionKey: "unknown workload \(name)"])
    }
    let expected = try operation()
    for _ in 0..<3 { let value = try operation(); precondition(value == expected) }
    var checksum: UInt64 = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { checksum &+= try operation() }
    let duration = DispatchTime.now().uptimeNanoseconds - start
    precondition(checksum == expected &* UInt64(iterations))
    try output(["workload": name, "iterations": iterations, "elapsed_ns": duration, "checksum": checksum, "expected": expected])
}

do { try run() } catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
