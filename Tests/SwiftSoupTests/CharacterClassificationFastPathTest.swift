import Foundation
import XCTest
@testable import SwiftSoup

final class CharacterClassificationFastPathTest: XCTestCase {
    // Preserve the pre-optimization definition, including normalization before
    // deciding whether a Character consists of exactly one scalar.
    private func original(_ character: Character, _ set: CharacterSet) -> Bool {
        let normalized = String(character).precomposedStringWithCanonicalMapping.unicodeScalars
        return normalized.count == 1 && set.contains(normalized.first!)
    }

    private var sets: [CharacterSet] {
        [.letters, .decimalDigits, .alphanumerics, .whitespacesAndNewlines,
         .controlCharacters, .punctuationCharacters, .symbols, .nonBaseCharacters,
         CharacterSet(), CharacterSet().inverted,
         CharacterSet(charactersIn: "\0\r\nAe\u{00E9}1"),
         CharacterSet(charactersIn: "\0\r\nAe\u{00E9}1").inverted]
    }

    private func check(_ character: Character, file: StaticString = #filePath, line: UInt = #line) {
        for set in sets {
            XCTAssertEqual(character.isMemberOfCharacterSet(set), original(character, set),
                           String(reflecting: character), file: file, line: line)
        }
        let letter = original(character, .letters)
        let digit = original(character, .decimalDigits)
        XCTAssertEqual(character.isLetter(), letter, file: file, line: line)
        XCTAssertEqual(Character.isLetter(character), letter, file: file, line: line)
        XCTAssertEqual(character.isDigit, digit, file: file, line: line)
        XCTAssertEqual(character.isLetterOrDigit(), letter || digit, file: file, line: line)
        XCTAssertEqual(Character.isLetterOrDigit(character), letter || digit, file: file, line: line)
    }

    func testEveryASCIIValueAcrossCharacterSetsAndPublicQueue() {
        for value in UInt32(0)..<128 {
            let scalar = UnicodeScalar(value)!
            let character = Character(scalar)
            check(character)
            let word = original(character, .letters) || original(character, .decimalDigits)
            let queue = TokenQueue(String(character) + "!")
            XCTAssertEqual(queue.matchesWord(), word)
            XCTAssertEqual(queue.toString(), String(character) + "!")
            XCTAssertEqual(TokenQueue("<" + String(character)).matchesStartTag(), original(character, .letters))
        }
    }

    func testCRLFIsNotASingleNewlineScalar() {
        let crlf: Character = "\r\n"
        XCTAssertEqual(crlf.asciiValue, 10) // Not sufficient for the fast-path guard.
        for set in sets {
            XCTAssertFalse(crlf.isMemberOfCharacterSet(set))
        }
        XCTAssertTrue(Character("\n").isMemberOfCharacterSet(.newlines))
        XCTAssertTrue(Character("\r").isMemberOfCharacterSet(.newlines))
        XCTAssertFalse(crlf.isMemberOfCharacterSet(.newlines))
        check(crlf)
    }

    func testASCIIBaseWithCombiningMarksStillNormalizes() {
        for base in ["A", "e", "n", "1", " ", "#", "\0"] {
            for suffix in ["\u{0301}", "\u{0308}", "\u{0327}", "\u{030A}", "\u{20E3}",
                           "\u{FE0F}", "\u{0301}\u{0327}", "\u{200D}", String(repeating: "\u{0301}", count: 64)] {
                for character in base + suffix { check(character) }
            }
        }
        let decomposed: Character = "e\u{0301}"
        XCTAssertTrue(decomposed.isMemberOfCharacterSet(CharacterSet(charactersIn: "é")))
        XCTAssertFalse(decomposed.isMemberOfCharacterSet(CharacterSet(charactersIn: "e")))
    }

    func testNonASCIIScalarsAndComposedGraphemes() {
        for text in ["日本語", "éÅÅ", "١２𝟡", "½Ⅸ", "👩🏽‍💻", "🇯🇵", "가", "\u{0344}",
                     "\u{212A}", "\u{00A0}\u{2003}\u{2028}", "\u{0301}\u{0327}"] {
            for character in text { check(character) }
        }
        var state: UInt64 = 0x4c415353494659
        for _ in 0..<4096 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            if let scalar = UnicodeScalar(UInt32(state % 0x110000)) { check(Character(scalar)) }
        }
    }

    func testWordAndTagConsumersKeepExactSourceBytes() throws {
        for spelling in ["section12", "ABCxyz019", "日本語２", "e\u{0301}clair", "éclair", "가", "a\u{20E3}"] {
            let word = TokenQueue(spelling + "!tail")
            let expected = String(spelling.prefix { original($0, .letters) || original($0, .decimalDigits) })
            XCTAssertEqual(Array(word.consumeWord().utf8), Array(expected.utf8))
            XCTAssertEqual(Array(word.toString().utf8), Array((String(spelling.dropFirst(expected.count)) + "!tail").utf8))
        }
        for spelling in ["custom-tag_12:part", "日本語:タグ", "e\u{0301}clair-test"] {
            let queue = TokenQueue("xx" + spelling + "!")
            try queue.consume("xx")
            XCTAssertEqual(Array(queue.consumeTagNameSlice().utf8), Array(spelling.utf8))
            XCTAssertEqual(queue.toString(), "!")
        }
    }

    func testSelectorResultsSurviveWarmupAndMutation() throws {
        let document = try SwiftSoup.parse("<main><section id='s'><p id='a'>日本語</p><p id='b'>two</p></section></main>")
        let query = "main > section p:nth-child(2n + 1)"
        for _ in 0..<3 { XCTAssertEqual(try document.select(query).array().map { $0.id() }, ["a"]) }
        let before = try document.outerHtml()
        _ = try QueryParser.parse("main > section.article:nth-child(2n + 1) p:contains(日本語)")
        XCTAssertEqual(try document.outerHtml(), before)
        let section = try XCTUnwrap(document.getElementById("s"))
        try section.prepend("<p id='c'>added</p>")
        XCTAssertEqual(try document.select(query).array().map { $0.id() }, ["c", "b"])
    }

    func testEveryASCIIStarterWithCombiningSuffixesUsesFullCharacter() {
        let marks = Array(UInt32(0x0300)...UInt32(0x036F)) + [0x200D, 0x20E3, 0xFE0E, 0xFE0F]
        let memberships: [CharacterSet] = [.letters, .decimalDigits, .nonBaseCharacters,
                                         CharacterSet(charactersIn: "Aez0\r\n"), CharacterSet().inverted]
        for value in UInt32(0)..<128 {
            for mark in marks {
                let text = String(UnicodeScalar(value)!) + String(UnicodeScalar(mark)!)
                // Controls may introduce a boundary instead of one grapheme.
                // Check actual Characters rather than inventing a grouping.
                for character in text {
                    for set in memberships {
                        XCTAssertEqual(character.isMemberOfCharacterSet(set), original(character, set),
                                       "starter=\(value), mark=\(mark)")
                    }
                }
            }
        }
    }

    func testMembershipUsesTheCurrentMutableCharacterSet() {
        for value in UInt32(0)..<128 {
            let scalar = UnicodeScalar(value)!
            let character = Character(scalar)
            var set = CharacterSet()
            XCTAssertFalse(character.isMemberOfCharacterSet(set))
            set.insert(charactersIn: String(scalar))
            XCTAssertTrue(character.isMemberOfCharacterSet(set))
            let snapshot = set
            set.invert()
            XCTAssertFalse(character.isMemberOfCharacterSet(set))
            XCTAssertTrue(character.isMemberOfCharacterSet(snapshot))
            set.insert(charactersIn: "\r\n")
            XCTAssertFalse(Character("\r\n").isMemberOfCharacterSet(set))
        }
    }

    func testBridgedAndSlicedStorageKeepsClassificationAndExactSpelling() {
        // NUL forces a grapheme boundary even before a leading combining mark.
        let prefix = String(repeating: "日", count: 1024) + "\0"
        let suffix = String(repeating: "語", count: 1024)
        for spelling in ["A", "1", "\0", "\r\n", "e\u{0301}", "\u{0344}", "\u{212A}", "가", "🇯🇵"] {
            let bridged = NSString(string: prefix + spelling + suffix) as String
            let begin = bridged.index(bridged.startIndex, offsetBy: 1025)
            let end = bridged.index(after: begin)
            let slice = bridged[begin..<end]
            XCTAssertEqual(Array(slice.utf8), Array(spelling.utf8))
            check(bridged[begin])
            check(Character(String(slice)))
            XCTAssertEqual(Array(bridged.utf8), Array((prefix + spelling + suffix).utf8))
        }
    }
}
