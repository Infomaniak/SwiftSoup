import XCTest
@testable import SwiftSoup

final class RegionCursorTest: XCTestCase {
    // Character arrays provide an independent positional model (not String offsets).
    private func reference(_ text: String, _ needle: String, _ start: Int, _ other: Int,
                           _ length: Int, _ fold: Bool) -> Bool {
        let lhs = Array(text), rhs = Array(needle)
        guard start >= 0, other >= 0, length >= 0,
              start <= lhs.count, other <= rhs.count,
              length <= lhs.count - start, length <= rhs.count - other else { return false }
        for i in 0..<length {
            let a = String(lhs[start+i]), b = String(rhs[other+i])
            if fold ? a.lowercased() != b.lowercased() : a != b { return false }
        }
        return true
    }

    func testAllOrdinaryBoundsAgainstCharacterArrayModel() {
        let samples = ["", "Abc", "日本語", "e\u{301}Éx", "👩🏽‍💻🇯🇵\r\nA", "İıΣσς", "a\0b"]
        for text in samples {
            for needle in samples {
                for start in -1...(text.count + 1) {
                    for other in -1...(needle.count + 1) {
                        for length in 0...(needle.count + 1) {
                            for fold in [false, true] {
                                XCTAssertEqual(text.regionMatches(ignoreCase: fold, selfOffset: start,
                                    other: needle, otherOffset: other, targetLength: length),
                                    reference(text, needle, start, other, length, fold))
                            }
                        }
                    }
                    XCTAssertEqual(text.startsWith(needle, start),
                        reference(text, needle, start, 0, needle.count, false))
                }
            }
        }
    }

    func testCanonicalEquivalenceAndWholeGraphemePolicy() {
        XCTAssertTrue("xéz".startsWith("e\u{301}", 1))
        XCTAssertFalse("xe\u{301}z".startsWith("e", 1))
        XCTAssertTrue("xÉz".regionMatches(ignoreCase: true, selfOffset: 1,
            other: "qe\u{301}!", otherOffset: 1, targetLength: 1))
        XCTAssertFalse("👩🏽‍💻!".startsWith("👩", 0))
        XCTAssertFalse("🇯🇵!".startsWith("🇯", 0))
        XCTAssertFalse("\r\n!".startsWith("\r", 0))
        // Do not substitute Foundation case folding (or whole-string lowercasing).
        XCTAssertFalse("ß".regionMatches(ignoreCase: true, selfOffset: 0,
            other: "SS", otherOffset: 0, targetLength: 1))
        XCTAssertFalse("Σ".regionMatches(ignoreCase: true, selfOffset: 0,
            other: "ς", otherOffset: 0, targetLength: 1))
    }

    func testHugeOffsetsAndLengthsStayBounded() {
        for offset in [Int.min, -1, 4, Int.max] {
            XCTAssertFalse("abc".startsWith("a", offset))
            XCTAssertFalse("abc".regionMatches(ignoreCase: true, selfOffset: offset,
                other: "a", otherOffset: 0, targetLength: 1))
            XCTAssertFalse("abc".regionMatches(ignoreCase: false, selfOffset: 0,
                other: "a", otherOffset: offset, targetLength: 1))
        }
        XCTAssertFalse("abc".regionMatches(ignoreCase: false, selfOffset: 0,
            other: "abc", otherOffset: 0, targetLength: Int.max))
        XCTAssertTrue("abc".startsWith("", 3))
        XCTAssertFalse("abc".startsWith("", 4))
    }

    func testInvalidNegativeLengthReturnsFalse() {
        // Internal invalid ranges used to trap; no public TokenQueue API supplies a length.
        for length in [-1, Int.min] {
            XCTAssertFalse("abc".regionMatches(ignoreCase: true, selfOffset: 0,
                other: "abc", otherOffset: 0, targetLength: length))
        }
    }

    func testSeededUnicodePrefixChecks() throws {
        let atoms = ["日", "本", "A", "a", "É", "e\u{301}", "👩🏽‍💻", "🇯🇵", "\r\n", "İ", "\0", " "]
        var seed: UInt64 = 0xA3D_20260909
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % UInt64(n)) }
        for _ in 0..<512 {
            let text = (0..<next(24)).map { _ in atoms[next(atoms.count)] }.joined()
            let offset = next(text.count + 1)
            let chars = Array(text)
            let prefix = String(chars.prefix(offset))
            let needle = next(2) == 0 ? String(chars.dropFirst(offset).prefix(next(10)))
                : (0..<next(8)).map { _ in atoms[next(atoms.count)] }.joined()
            let q = TokenQueue(text)
            if !prefix.isEmpty { try q.consume(prefix) }
            let saved = q.toString()
            XCTAssertEqual(q.matches(needle), reference(text, needle, offset, 0, needle.count, true))
            XCTAssertEqual(q.matchesCS(needle), reference(text, needle, offset, 0, needle.count, false))
            XCTAssertEqual(Array(q.toString().utf8), Array(saved.utf8))
        }
    }

    func testPublicQueueConsumeMissExhaustionAndReuse() throws {
        let q = TokenQueue("É日👩🏽‍💻!")
        XCTAssertTrue(q.matchesCS("E\u{301}"))
        XCTAssertFalse(q.matchesCS("é日")) // Capital É versus lowercase é remains case-sensitive.
        XCTAssertTrue(q.matchChomp("e\u{301}"))
        XCTAssertTrue(q.matches("日👩🏽‍💻"))
        XCTAssertThrowsError(try q.consume("other"))
        XCTAssertEqual(q.toString(), "日👩🏽‍💻!")
        try q.consume("日👩🏽‍💻!")
        XCTAssertTrue(q.isEmpty())
        XCTAssertTrue(q.matches("")); XCTAssertTrue(q.matchesCS(""))
        XCTAssertFalse(q.matches("x")); XCTAssertFalse(q.matchesCS("x"))
        q.addFirst("e\u{301}X")
        XCTAssertTrue(q.matches("Éx")); XCTAssertFalse(q.matchesCS("Éx"))
        XCTAssertEqual(Array(q.toString().utf8), Array("e\u{301}X".utf8))
    }

    func testActualSelectorsAndMutationRetainOutputs() throws {
        let doc = try SwiftSoup.parse("<main><p id='a' class='日本語'>École</p><p id='b'>other</p></main>")
        for _ in 0..<4 {
            XCTAssertEqual(try doc.select("MAIN > P.日本語:contains(école)").array().map { $0.id() }, ["a"])
            XCTAssertEqual(try doc.select("main > p:nth-child(2n + 1)").array().map { $0.id() }, ["a"])
        }
        try doc.getElementById("a")!.text("changed")
        XCTAssertTrue(try doc.select("MAIN > P.日本語:contains(école)").isEmpty())
        XCTAssertEqual(try doc.select("main > p:contains(changed)").array().map { $0.id() }, ["a"])
    }
}
