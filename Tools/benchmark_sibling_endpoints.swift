import Foundation
import SwiftSoup

final class CustomParent: Element, @unchecked Sendable {}

struct Workload {
    let name: String
    let parent: Element?
    let receiver: Element?
    let html: String?
    func run() throws -> Int {
        if let html {
            let doc=try SwiftSoup.parse(html)
            let nodes=try doc.select("section").array()
            if name=="parse-control" { return nodes.count + (try doc.select("p").size()) }
            return nodes.reduce(0) { result,node in result + (node.firstElementSibling()?.siblingIndex ?? -1) + (node.lastElementSibling()?.siblingIndex ?? -1) }
        }
        let node=receiver!
        var result=0
        for _ in 0..<32 {
            let endpoint=name.hasPrefix("last-") ? node.lastElementSibling() : node.firstElementSibling()
            result += (endpoint?.siblingIndex ?? -1) + 2
        }
        // Keep the owning parent live throughout every read, including optimized builds.
        withExtendedLifetime(parent) {}
        return result
    }
}

func fixture(_ name: String) throws -> Workload {
    if name.hasPrefix("parse-") {
        let html="<main>" + (0..<128).map { "<section id='n\($0)'><p>日本語</p><p>文章</p></section>" }.joined() + "</main>"
        return Workload(name:name,parent:nil,receiver:nil,html:html)
    }
    let count: Int
    if name=="single" { count=1 }
    else if name=="first-mixed" { count=4 }
    else if name=="fallback" { count=256 }
    else { count=Int(name.split(separator:"-").last!)! }
    let parent:Element = name=="fallback" ? try CustomParent(Tag.valueOf("main"), "") : try Element(Tag.valueOf("main"), "")
    if name=="first-mixed" { for _ in 0..<256 { try parent.appendChild(TextNode("文字", "")); try parent.appendChild(Comment(Array("c".utf8), [])) } }
    for i in 0..<count { try parent.appendElement("p").attr("id", "n\(i)") }
    return Workload(name:name,parent:parent,receiver:parent.children().last()!,html:nil)
}

func verify() throws {
    var records=[[String:Any]]()
    for count in 1...48 {
        let root=try Element(Tag.valueOf("main"), "")
        for i in 0..<count {
            try root.appendChild(TextNode("日本語", ""))
            try root.appendElement("p").attr("id", "n\(i)")
            try root.appendChild(Comment(Array("c".utf8), []))
        }
        let nodes=root.children().array()
        for node in nodes {
            let first=node.firstElementSibling(), last=node.lastElementSibling()
            precondition(first === (count>1 ? nodes.first:nil))
            precondition(last === (count>1 ? nodes.last:nil))
            records.append(["count":count,"node":node.id(),"first":first?.id() ?? "nil","last":last?.id() ?? "nil"])
        }
        records.append(["count":count,"html":try root.outerHtml()])
    }
    for name in ["single","first-8","first-256","first-2048","last-256","last-2048","first-mixed","fallback","parse-endpoints","parse-control"] {
        let work=try fixture(name)
        records.append(["case":name,"expected":try work.run()])
    }
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:records,options:[.sortedKeys]))
}

let args=CommandLine.arguments
if args.count==2 && args[1]=="--verify" { try verify() }
else {
    guard args.count==3,let n=Int(args[2]),n>0 else { fatalError("Usage: benchmark CASE ITERATIONS | --verify") }
    let work=try fixture(args[1]), expected=try work.run()
    for _ in 0..<3 { let observed=try work.run(); precondition(observed==expected) }
    var checksum=0
    let start=DispatchTime.now().uptimeNanoseconds
    for _ in 0..<n { checksum &+= try work.run() }
    let ns=DispatchTime.now().uptimeNanoseconds-start
    precondition(checksum==expected*n)
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:["case":args[1],"iterations":n,"ns":ns,"expected":expected,"checksum":checksum],options:[.sortedKeys])); print("")
}
