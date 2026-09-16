import Foundation
import XCTest
@testable import SwiftSoup

final class FragmentAppendTest: XCTestCase {
    private func chunks(_ count: Int) -> [[UInt8]] {
        (0..<count).map { i in
            [Array("日本😀".utf8), [], [0,255,192,175], Array("\t &<>\" ".utf8), Array("é\u{00a0}".utf8), [UInt8(i % 256)]][i % 6]
        }
    }
    private func slice(_ bytes: [UInt8], data: Bool) -> ByteSlice {
        let padded = [UInt8(250)] + bytes + [251]
        let storage = data ? ByteStorage(data: Data([249] + padded).dropFirst()) : ByteStorage(array: padded)
        return ByteSlice(storage: storage, start: 1, end: bytes.count + 1)
    }
    func testTextGrowthBoundariesAndBackings() {
        for count in [0,1,2,3,15,16,17,128,1024] {
            for data in [false,true] {
                let node = TextNode(slice: .empty, baseUri: nil)
                let input = chunks(count)
                for bytes in input { node.appendSlice(slice(bytes, data: data)) }
                XCTAssertEqual(node.getWholeTextUTF8(), input.flatMap { $0 })
                XCTAssertEqual(node.getWholeText(), String(decoding: input.flatMap { $0 }, as: UTF8.self))
            }
        }
    }
    func testDataGrowthBoundariesAndBackings() {
        for count in [0,1,2,3,15,16,17,128,1024] {
            for data in [false,true] {
                let node = DataNode(slice: .empty, baseUri: [])
                let input = chunks(count)
                for bytes in input { node.appendSlice(slice(bytes, data: data)) }
                XCTAssertEqual(node.getWholeDataUTF8(), input.flatMap { $0 }, "count=\(count)")
                XCTAssertEqual(node.getWholeData(), String(decoding: input.flatMap { $0 }, as: UTF8.self))
            }
        }
    }
    func testAttributeGrowthBoundariesAndBackings() throws {
        for count in [0,1,2,3,15,16,17,128,1024] {
            for data in [false,true] {
                let attribute = try Attribute(key: "data-test", value: "prefix")
                let input = chunks(count)
                for bytes in input { attribute.appendValueSlice(slice(bytes, data: data)) }
                XCTAssertEqual(attribute.getValueUTF8(), Array("prefix".utf8) + input.flatMap { $0 })
            }
        }
    }
    func testTextMaterializationSnapshotsAndReset() {
        let node = TextNode(slice: .fromArray(Array("prefix".utf8)), baseUri: [])
        var expected = Array("prefix".utf8)
        var snapshots: [([UInt8],[UInt8])] = []
        for (i,bytes) in chunks(80).enumerated() {
            node.appendSlice(slice(bytes, data: i.isMultiple(of: 2)))
            expected.append(contentsOf: bytes)
            if i.isMultiple(of: 7) { snapshots.append((node.getWholeTextUTF8(), expected)) }
        }
        XCTAssertEqual(node.getWholeTextUTF8(), expected)
        for (value,snapshot) in snapshots { XCTAssertEqual(value, snapshot) }
        node.text("reset").appendBytes(Array("追加".utf8))
        XCTAssertEqual(node.getWholeText(), "reset追加")
    }
    func testDataMaterializationSnapshotsAndReset() {
        let node = DataNode(slice: .fromArray(Array("prefix".utf8)), baseUri: [])
        var expected = Array("prefix".utf8)
        var snapshots: [([UInt8],[UInt8])] = []
        for (i,bytes) in chunks(80).enumerated() {
            node.appendSlice(slice(bytes, data: true))
            expected.append(contentsOf: bytes)
            if i.isMultiple(of: 7) { snapshots.append((node.getWholeDataUTF8(), expected)) }
        }
        XCTAssertEqual(node.getWholeDataUTF8(), expected)
        for (value,snapshot) in snapshots { XCTAssertEqual(value, snapshot) }
        node.setWholeData("reset").appendBytes(Array("追加".utf8))
        XCTAssertEqual(node.getWholeData(), "reset追加")
    }
    func testAttributeRetainedSliceArrayAndValueSnapshots() throws {
        let attribute = try Attribute(key: "x", value: "a")
        attribute.appendValueSlice(.fromArray(Array("b".utf8)))
        let retained = try XCTUnwrap(attribute.valueSlices)
        let retainedValues = retained.map { $0.toArray() }
        for _ in 0..<50 { attribute.appendValueSlice(.fromArray(Array("c".utf8))) }
        XCTAssertEqual(retained.map { $0.toArray() }, retainedValues)
        XCTAssertEqual(retained.count, 2)
        let snapshot = attribute.getValueUTF8()
        let sliceSnapshot = attribute.valueSliceMaterialized()
        attribute.appendValueSlice(.fromArray(Array("tail".utf8)))
        XCTAssertEqual(snapshot, Array(("ab" + String(repeating: "c", count: 50)).utf8))
        XCTAssertEqual(sliceSnapshot.toArray(), snapshot)
        XCTAssertEqual(attribute.getValueUTF8(), snapshot + Array("tail".utf8))
    }
    func testAttributeNormalizationCachesInvalidate() throws {
        let attribute = try Attribute(key: "x", value: " BEFORE ")
        XCTAssertEqual(String(decoding: attribute.lowerValueSlice(), as: UTF8.self), " before ")
        XCTAssertEqual(String(decoding: attribute.lowerTrimmedValueSlice(), as: UTF8.self), "before")
        for value in ["AFTER", " NEXT", " END "] { attribute.appendValueSlice(.fromArray(Array(value.utf8))) }
        XCTAssertEqual(String(decoding: attribute.lowerValueSlice(), as: UTF8.self), " before after next end ")
        XCTAssertEqual(String(decoding: attribute.lowerTrimmedValueSlice(), as: UTF8.self), "before after next end")
    }
    func testTextAttributeBackedPathAndMutationToken() throws {
        let doc = try SwiftSoup.parse("<p>initial</p>")
        let p = try XCTUnwrap(doc.getElementsByTag("p").first())
        let text = try XCTUnwrap(p.childNode(0) as? TextNode)
        _ = text.getAttributes()
        let version = doc.textMutationVersionToken()
        for _ in 0..<4 { XCTAssertEqual(try doc.select("p:contains(tail)").size(), 0) }
        text.appendSlice(.fromArray(Array("tail".utf8)))
        // Attribute ownership notifications can legitimately add an increment.
        // The public contract is invalidation, not the exact internal count.
        XCTAssertNotEqual(doc.textMutationVersionToken(), version)
        XCTAssertEqual(text.getWholeText(), "initialtail")
        XCTAssertEqual(try doc.select("p:contains(tail)").size(), 1)
        doc.outputSettings().prettyPrint(pretty: false)
        XCTAssertTrue(try doc.outerHtml().contains("initialtail"))
    }
    func testPublicHTMLAndXMLCharacterReferences() throws {
        for count in [1,17,256,1024] {
            let encoded = String(repeating: "日&amp;本&#x8a9e;&#32;", count: count)
            let decoded = String(repeating: "日&本語 ", count: count)
            for parser in [Parser.htmlParser(), Parser.xmlParser()] {
                let doc = try parser.parseInput("<root><p title='\(encoded)'>\(encoded)</p></root>", "")
                let p = try XCTUnwrap(doc.getElementsByTag("p").first())
                doc.materializeAttributesRecursively()
                XCTAssertEqual(try p.attr("title"), decoded)
                XCTAssertEqual(try p.text(trimAndNormaliseWhitespace: false), decoded)
            }
        }
    }
    func testBorrowedBufferAppends() throws {
        let bytes = Array("日本語😀".utf8)
        try bytes.withUnsafeBufferPointer { buffer in
            let storage = ByteStorage(buffer: buffer.baseAddress!, count: buffer.count, owner: nil)
            let part = ByteSlice(storage: storage, start: 0, end: bytes.count)
            let text = TextNode(slice: .empty, baseUri: [])
            let data = DataNode(slice: .empty, baseUri: [])
            let attribute = try Attribute(key: "x", value: "")
            for _ in 0..<64 { text.appendSlice(part); data.appendSlice(part); attribute.appendValueSlice(part) }
            let expected = Array(String(repeating: "日本語😀", count: 64).utf8)
            XCTAssertEqual(text.getWholeTextUTF8(), expected)
            XCTAssertEqual(data.getWholeDataUTF8(), expected)
            XCTAssertEqual(attribute.getValueUTF8(), expected)
        }
    }
    func testCoalescingWithoutSourceRangesPreservesTextAndClones() throws {
        for count in [1, 2, 17, 256, 2048] {
            let html = "<p>" + String(repeating: "日本</discarded-end>語", count: count) + "</p>"
            let parser = Parser.htmlParser().settings(ParseSettings(false, false, false))
            let doc = try parser.parseInput(html, "")
            let expected = String(repeating: "日本語", count: count)
            XCTAssertEqual(try doc.text(), expected)
            let p = try XCTUnwrap(doc.getElementsByTag("p").first())
            XCTAssertEqual(p.childNodeSize(), 1)
            let clone = doc.copy() as! Document
            XCTAssertEqual(try clone.text(), expected)
            doc.outputSettings().prettyPrint(pretty: false)
            clone.outputSettings().prettyPrint(pretty: false)
            XCTAssertEqual(try clone.outerHtml(), try doc.outerHtml())
            let text = try XCTUnwrap(p.childNode(0) as? TextNode)
            text.appendBytes(Array("末尾".utf8))
            XCTAssertEqual(try p.text(), expected + "末尾")
            XCTAssertEqual(try clone.text(), expected)
        }
    }

}
