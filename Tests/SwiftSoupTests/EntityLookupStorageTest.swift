import Foundation
import XCTest
@testable import SwiftSoup

final class EntityLookupStorageTest: XCTestCase {
    // Parse the repository's declarative entity table without any lookup routine.
    private func table(_ data: [UInt8]) -> [String: [UnicodeScalar]] {
        var result: [String: [UnicodeScalar]] = [:]
        for row in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let pair = row.split(separator: "=", maxSplits: 1)
            let codepoints = pair[1].split(separator: ";", maxSplits: 1)[0]
            result[String(pair[0])] = codepoints.split(separator: ",").map {
                UnicodeScalar(UInt32($0, radix: 36)!)!
            }
        }
        return result
    }

    private func check(_ name: String, expected: [UnicodeScalar]?, extended: Bool,
                       file: StaticString = #filePath, line: UInt = #line) {
        let bytes = Array(name.utf8)
        let padded: [UInt8] = [33, 255, 0] + bytes + [0, 59, 255]
        for storage in [ByteStorage(array: padded), ByteStorage(data: Data(padded)),
                        ByteStorage(data: Data([99] + padded).dropFirst())] {
            let slice = ByteSlice(storage: storage, start: 3, end: 3 + bytes.count)
            XCTAssertEqual(Entities.lookupNamedEntity(slice, allowExtended: extended), expected, name, file: file, line: line)
        }
        padded.withUnsafeBufferPointer { buffer in
            let storage = ByteStorage(buffer: buffer.baseAddress!, count: buffer.count, owner: nil)
            let slice = ByteSlice(storage: storage, start: 3, end: 3 + bytes.count)
            XCTAssertEqual(Entities.lookupNamedEntity(slice, allowExtended: extended), expected, name, file: file, line: line)
        }
    }

    func testEveryNamedEntityAcrossStorage() {
        let expected = table(Entities.full)
        XCTAssertEqual(expected.count, 2125)
        for name in expected.keys.sorted() { check(name, expected: expected[name], extended: true) }
    }

    func testBaseAdmissionAcrossStorage() {
        let base = table(Entities.base)
        for name in table(Entities.full).keys.sorted() { check(name, expected: base[name], extended: false) }
    }

    func testUnknownCaseAndBoundaryNames() {
        let reference = table(Entities.full)
        let names = ["", "NotEqualTildeX", "NotEqualTild", "notequaltilde", "NotEqualTilde;", "NotEqualTilde\0",
                     "NotEqualTilde猫", "CounterClockwiseContourIntegralX", "&amp", " a", String(repeating: "X", count: 128)]
        for name in names { check(name, expected: reference[name], extended: true) }
        for name in reference.keys.sorted() {
            check(name + "X", expected: reference[name + "X"], extended: true)
            check(String(name.dropLast()), expected: reference[String(name.dropLast())], extended: true)
        }
    }

    func testPublicUnescapeAdmissionRules() throws {
        XCTAssertEqual(try Entities.unescape("&NotEqualTilde;|&CounterClockwiseContourIntegral;"), "\u{2242}\u{338}|\u{2233}")
        XCTAssertEqual(try Entities.unescape("&NotEqualTilde|&NotEqualTildeX;"), "&NotEqualTilde|&NotEqualTildeX;")
        XCTAssertEqual(try Entities.unescape(string: "&amp=1 &NotEqualTilde;", strict: true), "&amp=1 \u{2242}\u{338}")
        XCTAssertEqual(try Entities.unescape(string: "&amp=1 &NotEqualTilde;", strict: false), "&=1 \u{2242}\u{338}")
        let text = "&NotNestedGreaterGreater;&NotGreaterFullEqual;"
        XCTAssertEqual(try Entities.unescape(Array(text.utf8)), Array("\u{2aa2}\u{338}\u{2267}\u{338}".utf8))
    }

    func testPublicStringDataAndBufferParsing() throws {
        let input = "<p title='&NotEqualTilde; &CounterClockwiseContourIntegral;'>&NotSquareSubset; &NotARealLongEntity;</p>"
        let bytes = Array(input.utf8)
        let string = try SwiftSoup.parse(input)
        let data = try SwiftSoup.parse(Data(bytes))
        let pointer = try SwiftSoup.parse(withBytes: { parse in try bytes.withUnsafeBufferPointer { try parse($0) } })
        for document in [string, data, pointer] {
            let p = try XCTUnwrap(document.select("p").first())
            XCTAssertEqual(try p.attr("title"), "\u{2242}\u{338} \u{2233}")
            XCTAssertEqual(try p.text(), "\u{228f}\u{338} &NotARealLongEntity;")
        }
    }

    func testRetainedStorageAndRepeatedLookups() {
        var bytes = Array("xxNotEqualTildeyy".utf8)
        let storage = ByteStorage(array: bytes)
        let slice = ByteSlice(storage: storage, start: 2, end: bytes.count - 2)
        bytes.replaceSubrange(2..<(bytes.count - 2), with: Array("OtherLongName".utf8))
        for _ in 0..<256 {
            XCTAssertEqual(Entities.lookupNamedEntity(slice, allowExtended: true), [UnicodeScalar(0x2242)!, UnicodeScalar(0x338)!])
            XCTAssertNil(Entities.lookupNamedEntity(slice, allowExtended: false))
        }
    }
}
