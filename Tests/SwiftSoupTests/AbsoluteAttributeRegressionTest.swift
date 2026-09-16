import XCTest
@testable import SwiftSoup

final class AbsoluteAttributeRegressionTest: XCTestCase {
    func testVirtualAttributePrefixIsCaseInsensitiveAcrossOverloads() throws {
        for prefix in ["abs:", "ABS:", "Abs:", "aBs:"] {
            for key in ["href", "HREF", "HrEf"] {
                let doc = try SwiftSoup.parse("<a href='page'>link</a>", "https://example.test/dir/")
                let link = try XCTUnwrap(doc.select("a").first())
                let query = prefix + key
                XCTAssertEqual(try link.attr(query), "https://example.test/dir/page")
                XCTAssertTrue(link.hasAttr(query), query)
                XCTAssertTrue(link.hasAttr(Array(query.utf8)), query)
                let node: Node = link
                XCTAssertTrue(node.hasAttr(query), query)
            }
        }
    }

    func testCaseInsensitiveVirtualPresenceTracksBaseURIChanges() throws {
        let doc = try SwiftSoup.parse("<a href='relative'>link</a>", "")
        let link = try XCTUnwrap(doc.select("a").first())
        for base in ["", "https://example.test/a/", "", "https://example.test/b/"] {
            try link.setBaseUri(base)
            for key in ["abs:href", "ABS:HREF", "AbS:href"] {
                XCTAssertEqual(link.hasAttr(key), !base.isEmpty, key)
                XCTAssertEqual(try link.attr(key).isEmpty, base.isEmpty, key)
            }
        }
    }

    func testVirtualPresenceTracksDirectAttributeMutation() throws {
        let doc = try SwiftSoup.parse("<a href='https://one.test/a'>link</a>")
        let link = try XCTUnwrap(doc.select("a").first())
        let attr = try XCTUnwrap(link.getAttributes()?.asList().first)
        for value in ["https://one.test/a", "relative", "https://two.test/b", ""] {
            attr.setValue(value: Array(value.utf8))
            for key in ["abs:href", "ABS:HREF"] {
                XCTAssertEqual(link.hasAttr(key), value.hasPrefix("https://"), key)
            }
        }
    }

    func testPhysicalVirtualNamedAttributesRetainFallback() throws {
        let link = try SwiftSoup.parse("<a abs:href='literal'>link</a>").select("a").first()!
        for key in ["abs:href", "ABS:HREF", "Abs:href"] {
            XCTAssertTrue(link.hasAttr(key))
            XCTAssertEqual(try link.attr(key), "literal")
        }
        try link.removeAttr("abs:href")
        for key in ["abs:href", "ABS:HREF", "abs:", "ABS:"] {
            XCTAssertFalse(link.hasAttr(key))
        }
    }

    func testNilBaseURIResolvesExistingAbsoluteURL() throws {
        // Retain the existing nil-base URL fix while checking virtual presence.
        let node = TextNode("text", nil)
        try node.attr("href", "https://example.test/a")
        XCTAssertEqual(try node.absUrl("href"), "https://example.test/a")
        XCTAssertEqual(try node.attr("abs:href"), "https://example.test/a")
        XCTAssertTrue(node.hasAttr("ABS:HREF"))
    }

    func testNilBaseURIRelativeValueIsUnresolvable() throws {
        for value in ["relative", "", "#fragment"] {
            let node = TextNode("text", nil)
            try node.attr("href", value)
            XCTAssertEqual(try node.absUrl("href"), "")
            XCTAssertEqual(try node.attr("ABS:HREF"), "")
            XCTAssertFalse(node.hasAttr("abs:href"))
        }
    }

    func testMissingAttributesWithNilBaseURIAreEmpty() throws {
        let node = TextNode("text", nil)
        XCTAssertEqual(try node.absUrl("missing"), "")
        XCTAssertFalse(node.hasAttr("abs:missing"))
        XCTAssertFalse(node.hasAttr("ABS:missing"))
        XCTAssertThrowsError(try node.absUrl(""))
    }

    func testByteCollectionAbsURLOverloadsAgree() throws {
        let node = TextNode("text", nil)
        try node.attr("href", "https://example.test/%E6%97%A5%E6%9C%AC")
        let padded = Array("xhrefy".utf8)
        let slice = padded.dropFirst().dropLast()
        let expected = try node.absUrl("href")
        XCTAssertEqual(expected, "https://example.test/%E6%97%A5%E6%9C%AC")
        XCTAssertEqual(try node.absUrl(slice), Array(expected.utf8))
        XCTAssertEqual(try node.absUrl(Array("HREF".utf8)), Array(expected.utf8))
    }

    func testUnescapedUnicodeURLPreservesPlatformResolverPolicy() throws {
        // Apple uses CFURL here; Linux uses URL. This test guards overload
        // parity without introducing a new cross-platform escaping policy.
        let raw = "https://example.test/日本"
        let expected = StringUtil.resolve("", relUrl: raw)
        let node = TextNode("text", nil)
        try node.attr("href", raw)
        XCTAssertEqual(try node.absUrl("href"), expected)
        XCTAssertEqual(try node.absUrl(Array("HREF".utf8)), Array(expected.utf8))
        let padded = Array("xhrefy".utf8)
        XCTAssertEqual(try node.absUrl(padded.dropFirst().dropLast()), Array(expected.utf8))
        XCTAssertEqual(node.hasAttr("ABS:HREF"), !expected.isEmpty)
        XCTAssertEqual(try node.attr("href"), raw)
    }

    func testAbsoluteURLLookupDoesNotDirtySourceOrTextCaches() throws {
        let doc = try SwiftSoup.parse("<p>text</p>", "https://example.test/")
        let text = try XCTUnwrap(doc.select("p").first()?.textNodes().first)
        try text.attr("href", "relative")
        let version = doc.textMutationVersionToken()
        let dirty = text.sourceRangeDirty
        for _ in 0..<4 {
            XCTAssertTrue(text.hasAttr("ABS:HREF"))
            XCTAssertEqual(try text.absUrl("href"), "https://example.test/relative")
        }
        XCTAssertEqual(doc.textMutationVersionToken(), version)
        XCTAssertEqual(text.sourceRangeDirty, dirty)
    }
    func testInvalidVirtualSuffixDoesNotHidePhysicalAttribute() throws {
        for value in ["literal", ""] {
            let node = TextNode("text", nil)
            try node.attr("abs:", value)
            for key in ["abs:", "ABS:", "aBs:"] { XCTAssertTrue(node.hasAttr(key)) }
            if !value.isEmpty { XCTAssertEqual(try node.attr("ABS:"), value) }
            try node.removeAttr("ABS:")
            XCTAssertFalse(node.hasAttr("abs:"))
        }
    }

    private final class ProjectedBaseURI: TextNode {
        override func getBaseUriUTF8() -> [UInt8] { Array("https://projected.test/path/".utf8) }
    }

    func testAbsoluteURLUsesPublicBaseURIProjection() throws {
        let node = ProjectedBaseURI("text", "https://stored.test/")
        try node.attr("href", "page")
        XCTAssertEqual(try node.absUrl("href"), "https://projected.test/path/page")
        XCTAssertTrue(node.hasAttr("ABS:HREF"))
    }

}
