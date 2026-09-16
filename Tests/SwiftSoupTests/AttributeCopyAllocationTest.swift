import XCTest
@testable import SwiftSoup

final class AttributeCopyAllocationTest: XCTestCase {
    func testCopyPreservesOrderCaseValuesAndBooleans() throws {
        let parser = Parser.htmlParser().settings(ParseSettings.preserveCase)
        let doc = try parser.parseInput("<p ID='A' class='one two' disabled data-x='' title='日本語'></p>", "")
        let source = try XCTUnwrap(doc.getElementsByTag("p").first()?.getAttributes())
        let copy = source.clone()
        XCTAssertEqual(try source.html(), try copy.html())
        XCTAssertEqual(source.asList().map { $0.getKey() }, copy.asList().map { $0.getKey() })
        XCTAssertEqual(source.asList().map { $0.getValue() }, copy.asList().map { $0.getValue() })
        XCTAssertEqual(source.hasUppercaseKeys, copy.hasUppercaseKeys)
        XCTAssertNil(copy.ownerElement)
        for (first, second) in zip(source.asList(), copy.asList()) {
            // Clone isolation wins over the old shallow-copy optimization contract.
            XCTAssertFalse(first === second)
            let value = first.getValue()
            _ = second.setValue(value: Array("changed in copy".utf8))
            XCTAssertEqual(first.getValue(), value)
        }
    }

    func testCopyOwnsIndependentArrayAcrossThresholds() throws {
        for count in [0, 1, 8, 15, 16, 17, 32, 100] {
            let source = Attributes()
            for index in 0..<count { try source.put("data-\(index)", "value-\(index)") }
            let copy = source.clone()
            try copy.put("only-copy", "copy")
            try source.put("only-source", "source")
            XCTAssertFalse(source.hasKey(key: "only-copy"))
            XCTAssertFalse(copy.hasKey(key: "only-source"))
            XCTAssertEqual(source.size(), count + 1)
            XCTAssertEqual(copy.size(), count + 1)
        }
    }

    func testRepeatedCopiesAfterIndexedLookups() throws {
        let source = Attributes()
        for index in 0..<40 { try source.put("Key-\(index)", "\(index)") }
        for _ in 0..<5 {
            for index in 0..<40 { XCTAssertEqual(try source.getIgnoreCase(key: "KEY-\(index)"), "\(index)") }
            let copy = source.clone()
            try copy.remove(key: "Key-7")
            XCTAssertEqual(source.get(key: "Key-7"), "7")
            XCTAssertFalse(copy.hasKey(key: "Key-7"))
            XCTAssertEqual(try copy.getIgnoreCase(key: "KEY-39"), "39")
        }
    }

    func testDeferredAttributesAndDuplicateKeysMaterializeTheSameWay() throws {
        for count in [0, 1, 15, 16, 17, 64] {
            let markup = (0..<count).map { "data-\($0)='\($0)'" }.joined(separator: " ")
            let document = try SwiftSoup.parse("<p \(markup) title='a &amp; 日本語' title='last'></p>")
            let source = try XCTUnwrap(document.getElementsByTag("p").first()?.getAttributes())
            let copy = source.clone()
            XCTAssertEqual(try source.html(), try copy.html())
            XCTAssertEqual(source.size(), copy.size())
            XCTAssertEqual(copy.get(key: "title"), source.get(key: "title"))
        }
    }
    func testCopyStartsWithFreshLookupCachesAndNoOwner() throws {
        let document = try SwiftSoup.parse("<p ID='a' data-x='1' data-y='2' data-z='3'></p>")
        let source = try XCTUnwrap(document.getElementsByTag("p").first()?.getAttributes())
        _ = source.get(key: "data-x")
        _ = try source.getIgnoreCase(key: "DATA-Y")
        let copy = source.clone()
        XCTAssertNil(copy.lowercasedKeysCache)
        XCTAssertNil(copy.lowercasedKeyIndex)
        XCTAssertTrue(copy.lowercasedKeyIndexDirty)
        XCTAssertNil(copy.keyIndex)
        XCTAssertTrue(copy.keyIndexDirty)
        XCTAssertNil(copy.pendingAttributes)
        XCTAssertEqual(copy.pendingAttributesCount, 0)
        XCTAssertNil(copy.ownerElement)
        XCTAssertEqual(copy.hasUppercaseKeys, source.hasUppercaseKeys)
        XCTAssertEqual(try copy.html(), try source.html())
    }

}
