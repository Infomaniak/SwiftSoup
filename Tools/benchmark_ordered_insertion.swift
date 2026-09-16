import Foundation
import SwiftSoup

private func emit(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

private func verification() throws {
    var records: [[String: Any]] = []
    for width in [0, 1, 8, 16, 63, 64, 128] {
        for gap in 0...width {
            let set = OrderedSet(sequence: Array(0..<width))
            let before = Array(set)
            var expected = before
            expected.insert(-1, at: gap)
            set.insert(-1, at: gap)
            precondition(Array(set) == expected)
            let indices = expected.map { set.index(of: $0)! }
            precondition(indices == Array(expected.indices))
            // Existing values must not move or replace their representative.
            set.insert(-1, at: set.count)
            precondition(Array(set) == expected)
            records.append(["width": width, "gap": gap, "values": Array(set), "indices": indices])
            set.remove(-1)
            precondition(Array(set) == before)
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
    if name == "parse-control" {
        let html = "<main>" + (0..<128).map { "<p class='x'>日本語 \($0)</p>" }.joined() + "</main>"
        operation = {
            let document = try SwiftSoup.parse(html)
            return UInt64(try document.select("p.x").count + document.text().utf8.count)
        }
    } else {
        let parts = name.split(separator: "-")
        guard parts.count == 2, let width = Int(parts[1]), [16, 128, 1024].contains(width),
              ["head", "middle", "tail", "duplicate"].contains(parts[0]) else {
            throw NSError(domain: "benchmark", code: 2, userInfo: [NSLocalizedDescriptionKey: "unknown workload"])
        }
        let whereTo = String(parts[0])
        let values = Array(0..<width)
        let set = OrderedSet(sequence: values)
        let gap = whereTo == "head" ? 0 : whereTo == "middle" ? width / 2 : width
        // Full array/index expectations are checked outside the timed loop.
        if whereTo != "duplicate" {
            var expected = values
            expected.insert(-1, at: gap)
            set.insert(-1, at: gap)
            precondition(Array(set) == expected)
            precondition(expected.enumerated().allSatisfy { set.index(of: $0.element) == $0.offset })
            set.remove(-1)
        }
        operation = {
            if whereTo == "duplicate" {
                set.insert(width / 2, at: 0)
                return UInt64(set.index(of: width / 2)! + set.count)
            }
            set.insert(-1, at: gap)
            let checksum = UInt64(set.index(of: -1)! + set.count)
            set.remove(-1) // restore fixed-sized state; removal is included in timing
            return checksum
        }
        precondition(Array(set) == values)
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
