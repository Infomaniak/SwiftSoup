import XCTest
@testable import SwiftSoup

final class StringSearchBoundaryTest: XCTestCase {
    // Deliberately use Character arrays and independently constructed windows,
    // not String.index, Foundation search, or the production helper.
    private func reference(_ text: String, _ needle: String, _ offset: Int) -> Int {
        let chars = Array(text), width = Array(needle).count
        guard offset >= 0, offset <= chars.count, width <= chars.count - offset else { return -1 }
        for i in offset...(chars.count - width) {
            if String(chars[i..<(i + width)]) == needle { return i }
        }
        return -1
    }

    func testEmptyNeedlesAndBounds() {
        for text in ["", "abc", "日👩🏽‍💻e\u{301}\r\n"] {
            for offset in [Int.min, -1, 0, 1, text.count, text.count + 1, Int.max] {
                for needle in ["", "x", "abc", "a needle longer than the input"] {
                    XCTAssertEqual(text.indexOf(needle, offset), reference(text, needle, offset))
                }
            }
        }
    }

    func testSuffixTooShortAndExhaustedSearchReturnNotFound() {
        XCTAssertEqual("abc".indexOf("xx", 2), -1)
        XCTAssertEqual("abc".indexOf("x", 3), -1)
        XCTAssertEqual("日語".indexOf("語語", 1), -1)
        XCTAssertEqual("日語".indexOf("語", 2), -1)
        XCTAssertEqual("abc".indexOf("", 3), 3)
    }

    func testWholeGraphemesAndCanonicalEquivalence() {
        let texts = ["ae\u{301}z", "aéz", "x👩🏽‍💻y🇯🇵z", "x\r\ny", "x\u{0600}Ay", "x\0y", "가끝", "a\u{301}\u{327}b"]
        let needles = ["e", "é", "e\u{301}", "\u{301}", "👩", "🏽", "👩🏽‍💻", "🇯", "🇯🇵", "\r", "\n", "\r\n", "A", "\u{0600}A", "\0", "가", "a\u{327}\u{301}"]
        for text in texts {
            for needle in needles {
                for offset in 0...text.count {
                    XCTAssertEqual(text.indexOf(needle, offset), reference(text, needle, offset), "\(text.debugDescription) / \(needle.debugDescription) @ \(offset)")
                }
            }
        }
    }

    func testGeneratedCompatibilityOnPreviouslyValidSearchRanges() {
        var state: UInt64 = 0x1234fedc
        func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(n))
        }
        let atoms = ["a", "b", "日", "e\u{301}", "é", "👩🏽‍💻", "🇯🇵", "\r\n", "\0", "\u{0600}A", "\u{301}", "(", ")"]
        for _ in 0..<512 {
            let text = (0..<next(32)).map { _ in atoms[next(atoms.count)] }.joined()
            let chars = Array(text)
            var needles = ["", "absent", atoms[next(atoms.count)], "é", ")"]
            if !chars.isEmpty {
                let a = next(chars.count), b = next(chars.count + 1)
                needles.append(String(chars[min(a,b)..<max(a,b)]))
            }
            for needle in needles {
                let maxOffset = chars.count - needle.count
                // The old implementation traps when 0 <= offset <= count but
                // offset > maxOffset >= 0. Boundary fixes have separate tests.
                for offset in 0...max(0, maxOffset) {
                    XCTAssertEqual(text.indexOf(needle, offset), reference(text, needle, offset))
                }
            }
        }
    }

    func testPublicQueueRetainsDelimiterAndExactSourceBytes() {
        let prefix = "日本e\u{301}👩🏽‍💻\r\n"
        let queue = TokenQueue(prefix + "éEND")
        XCTAssertEqual(Array(queue.consumeTo("é").utf8), Array("日本".utf8))
        XCTAssertEqual(Array(queue.toString().utf8), Array("e\u{301}👩🏽‍💻\r\néEND".utf8))
        // Case-sensitive search is canonical-equivalence-aware, not byte search.
        let other = TokenQueue(prefix + "STOPtail")
        XCTAssertEqual(Array(other.consumeToSlice("STOP").utf8), Array(prefix.utf8))
        XCTAssertEqual(other.chompTo("STOP"), "")
        XCTAssertEqual(other.remainder(), "tail")
    }

    func testPublicQueueMissesPreserveExistingNonconsumingBehavior() throws {
        let queue = TokenQueue("abcdef")
        try queue.consume("ab")
        XCTAssertEqual(queue.consumeTo("missing"), "")
        XCTAssertEqual(queue.toString(), "cdef")
        XCTAssertEqual(queue.consumeTo("xyz"), "")
        XCTAssertEqual(queue.toString(), "cdef")
        XCTAssertEqual(queue.consumeTo("ef"), "cd")
        XCTAssertEqual(queue.toString(), "ef")
    }

    func testPublicQueueExhaustionAndShortSuffixNoLongerTrap() throws {
        let queue = TokenQueue("abc")
        try queue.consume("ab")
        XCTAssertEqual(queue.consumeTo("xx"), "")
        XCTAssertEqual(queue.toString(), "c")
        try queue.consume("c")
        for _ in 0..<4 {
            XCTAssertEqual(queue.consumeTo("x"), "")
            XCTAssertEqual(queue.consumeTo(""), "")
            XCTAssertTrue(queue.isEmpty())
        }
        queue.addFirst("日本)")
        XCTAssertEqual(queue.consumeTo(")"), "日本")
        XCTAssertEqual(queue.toString(), ")")
    }

    func testIgnoreCasePublicQueueUsesUncasedSkipWithoutChangingResults() {
        let cases = ["日本</tAg>後", "abc<x><y></TAG>tail", "日👩🏽‍💻無一致", "abc<", "a\r\nb</TaG>"]
        for text in cases {
            let q = TokenQueue(text)
            let result = q.chompToIgnoreCase("</tag>")
            let expected = text.range(of: "</tag>", options: .caseInsensitive).map { String(text[..<$0.lowerBound]) } ?? text
            XCTAssertEqual(Array(result.utf8), Array(expected.utf8))
        }
    }

    func testLongNumericSelectorParsingAndSelection() throws {
        let saved = QueryParser.cache
        QueryParser.cache = nil
        defer { QueryParser.cache = saved }
        let root = try SwiftSoup.parse("<ul><li>a</li><li>b</li><li>c</li></ul>")
        for count in [1, 64, 512, 2048] {
            let query = "li:eq(" + String(repeating: "0", count: count) + "1)"
            let eval = try QueryParser.parse(query)
            XCTAssertEqual(try root.select(eval).text(), "b")
        }
    }
}
