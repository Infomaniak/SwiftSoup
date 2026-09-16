import XCTest
@testable import SwiftSoup

final class CSSCommentFastPathTest: XCTestCase {
    private func whitelist() throws -> Whitelist {
        try Whitelist.none().addTags("p", "span")
            .addAttributes(":all", "style")
            .addCSSProperties(":all", "color", "font-weight", "font-family", "content", "width", "background-image", "transform", "behavior", "-moz-binding")
    }

    private func sanitize(_ value: String, using whitelist: Whitelist? = nil) throws -> String? {
        let rules = try whitelist ?? self.whitelist()
        let element = try Element(Tag.valueOf("p"), "")
        return try rules.safeAttribute("p", element, Attribute(key: "style", value: value))?.getValue()
    }

    func testSlashFreePropertiesStillFilterAndNormalize() throws {
        XCTAssertEqual(try sanitize(" COLOR: red; position:absolute; font-weight: bold "), "color:red; font-weight:bold")
        XCTAssertNil(try sanitize(""))
        XCTAssertNil(try sanitize("position:absolute"))
        XCTAssertEqual(try sanitize("transform:translate(10px, calc(100% - 1em)); content:'a;b:c'"),
                       "transform:translate(10px, calc(100% - 1em)); content:'a;b:c'")
    }

    func testUnicodeBytesAndQuotedEscapesArePreserved() throws {
        for value in ["日本語", "cafe\u{301}", "👩🏽‍💻", "∕／⁄", "a\u{00A0}b", "x\\\"y", "a\u{200D}b"] {
            let style = "content:'\(value)'"
            XCTAssertEqual(Array(try XCTUnwrap(sanitize(style)).utf8), Array(style.utf8))
        }
    }

    func testSlashFreeUnsafeValuesRemainRejected() throws {
        for value in ["expression(alert(1))", "ExPrEsSiOn (alert(1))", "expre\nssion(alert(1))", "@import 'x'", "url(x)", "u\u{00A0}rl(x)"] {
            XCTAssertNil(try sanitize("width:\(value)"), value)
        }
        XCTAssertNil(try sanitize("behavior:test; -moz-binding:test"))
    }

    func testCommentsAndCommentLikeQuotedContentRetainOldScanner() throws {
        XCTAssertEqual(try sanitize("co/*x*/lor:red; /* ; : */ font-weight:bold; content:'a/*not-comment*/b'"),
                       "color:red; font-weight:bold; content:'a/*not-comment*/b'")
        XCTAssertEqual(try sanitize("color:red/*unterminated"), "color:red")
        XCTAssertNil(try sanitize("/*unterminated"))
        XCTAssertEqual(try sanitize("content:'a/b'; color:red"), "content:'a/b'; color:red")
        XCTAssertEqual(try sanitize("color:red; width:exp/*x*/ression(alert(1)); background-image:u/*x*/rl(x)"), "color:red")
    }

    func testSeededSlashFreeStylesAgreeWithForcedCommentScanner() throws {
        let rules = try whitelist()
        var state: UInt64 = 0x9624
        let values = ["red", "日本語", "cafe\u{301}", "'x;y:z'", "calc(100% - 1em)", "expression(1)", "'👩🏽‍💻'", "'a\\\"b'", "u\u{00A0}rl(x)"]
        let keys = ["color", "content", "font-family", "width", "position"]
        for _ in 0..<512 {
            state = state &* 6364136223846793005 &+ 1
            let key = keys[Int(state % UInt64(keys.count))]
            let value = values[Int((state >> 16) % UInt64(values.count))]
            let style = "\(key):\(value); color:blue"
            // The prefix is stripped by the unchanged scanner. All fixtures
            // begin with ASCII property names, avoiding grapheme-boundary changes.
            XCTAssertEqual(try sanitize(style, using: rules), try sanitize("/**/" + style, using: rules))
        }
    }

    func testCleaningAndRepeatedRuleChangesDoNotMutateInput() throws {
        let rules = try whitelist()
        let document = try SwiftSoup.parse("<p style=\"color:red; position:absolute\">日本語</p><span style=\"content:'a/b'\">x</span>")
        let original = try document.outerHtml()
        let cleaner = Cleaner(headWhitelist: nil, bodyWhitelist: rules)
        let first = try cleaner.clean(document)
        XCTAssertEqual(try first.select("p").attr("style"), "color:red")
        try rules.removeCSSProperties(":all", "color")
        let second = try cleaner.clean(document)
        XCTAssertFalse(try second.select("p").hasAttr("style"))
        XCTAssertEqual(try document.outerHtml(), original)
        XCTAssertEqual(try first.select("p").attr("style"), "color:red")
    }
}
