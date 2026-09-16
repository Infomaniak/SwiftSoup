import Foundation
import SwiftSoup

let counts = [16, 128, 1024]
let exposureCount = 131_072
var result: [[String: Any]] = []
for count in counts {
    let attributes = Attributes()
    for index in 0..<count { try attributes.put("k\(index)", "v\(index)") }
    let saved = attributes.asList()
    let iterations = exposureCount / count
    var checksum = 0
    for _ in 0..<max(2, iterations / 10) { checksum &+= attributes.asList().count }
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { checksum &+= attributes.asList().count }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    let final = attributes.asList()
    precondition(final.count == count && final.first === saved.first && final.last === saved.last)
    result.append(["attributes": count, "iterations": iterations, "elapsed_ns": elapsed, "checksum": checksum])
}
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
