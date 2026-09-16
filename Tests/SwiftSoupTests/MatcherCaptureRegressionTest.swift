import XCTest
import Foundation
import Dispatch
@testable import SwiftSoup

final class MatcherCaptureRegressionTest: XCTestCase {
    private func assertCapture(
        _ matcher: Matcher, _ group: Int, _ expected: String?,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        // String equality hides canonical-equivalence differences. Check bytes.
        XCTAssertEqual(matcher.group(group).map { Array($0.utf8) },
                       expected.map { Array($0.utf8) }, file: file, line: line)
    }

    func testASCIICapturesAtNonzeroOffsets() {
        let matcher = Pattern.compile("(a)(b+)").matcher(in: "--abb--ab")
        XCTAssertTrue(matcher.find())
        assertCapture(matcher, 0, "abb")
        assertCapture(matcher, 1, "a")
        assertCapture(matcher, 2, "bb")
        XCTAssertTrue(matcher.find())
        assertCapture(matcher, 0, "ab")
        assertCapture(matcher, 2, "b")
    }

    func testJapaneseBMPCaptures() {
        let matcher = Pattern.compile("(日本)(語)").matcher(in: "前 日本語 後")
        XCTAssertTrue(matcher.find())
        assertCapture(matcher, 0, "日本語")
        assertCapture(matcher, 1, "日本")
        assertCapture(matcher, 2, "語")
    }

    func testCaptureAfterEmojiPrefixDoesNotTrap() {
        let matcher = Pattern.compile("(x)").matcher(in: "👩🏽‍💻x")
        XCTAssertTrue(matcher.find())
        assertCapture(matcher, 0, "x")
        assertCapture(matcher, 1, "x")
    }

    func testSupplementaryScalarCaptureUsesUTF16Length() {
        let matcher = Pattern.compile("(😀)").matcher(in: "😀z")
        XCTAssertTrue(matcher.find())
        assertCapture(matcher, 0, "😀")
        assertCapture(matcher, 1, "😀")
    }

    func testZWJSequenceCanBeCapturedAsSeparateScalars() {
        let matcher = Pattern.compile("(👩)(🏽)(\u{200D})(💻)").matcher(in: "👩🏽‍💻!")
        XCTAssertTrue(matcher.find())
        for (index, expected) in ["👩🏽‍💻", "👩", "🏽", "\u{200D}", "💻"].enumerated() {
            assertCapture(matcher, index, expected)
        }
    }

    func testCombiningMarkCapturesDoNotExpandToWholeGrapheme() {
        let matcher = Pattern.compile("(e)(\\p{M})").matcher(in: "e\u{301}x")
        XCTAssertTrue(matcher.find())
        assertCapture(matcher, 0, "e\u{301}")
        assertCapture(matcher, 1, "e")
        assertCapture(matcher, 2, "\u{301}")
    }

    func testFlagCanBeCapturedAsSeparateRegionalIndicators() {
        let matcher = Pattern.compile("(🇯)(🇵)").matcher(in: "🇯🇵x")
        XCTAssertTrue(matcher.find())
        assertCapture(matcher, 0, "🇯🇵")
        assertCapture(matcher, 1, "🇯")
        assertCapture(matcher, 2, "🇵")
    }

    func testCRLFCapturesKeepExactCodeUnits() {
        let matcher = Pattern.compile("(\r)(\n)").matcher(in: "\r\nx")
        XCTAssertTrue(matcher.find())
        assertCapture(matcher, 0, "\r\n")
        assertCapture(matcher, 1, "\r")
        assertCapture(matcher, 2, "\n")
    }

    func testZeroWidthMatchInsideGraphemeRemainsPresent() {
        let matcher = Pattern.compile("(?=(\u{301}))").matcher(in: "e\u{301}x")
        XCTAssertTrue(matcher.find())
        assertCapture(matcher, 0, "")
        assertCapture(matcher, 1, "\u{301}")
    }

    func testZeroWidthMatchAtUnicodeEnd() {
        let matcher = Pattern.compile("$").matcher(in: "👩🏽‍💻")
        XCTAssertTrue(matcher.find())
        assertCapture(matcher, 0, "")
        XCTAssertFalse(matcher.find())
    }

    func testEmbeddedNULAndUnicodeBytesArePreserved() {
        let matcher = Pattern.compile("(日\0😀)").matcher(in: "前日\0😀後")
        XCTAssertTrue(matcher.find())
        assertCapture(matcher, 0, "日\0😀")
        assertCapture(matcher, 1, "日\0😀")
    }

    func testUnmatchedOptionalAndPresentEmptyGroupsStayDistinct() {
        let matcher = Pattern.compile("(a)?()").matcher(in: "")
        XCTAssertTrue(matcher.find())
        assertCapture(matcher, 0, "")
        assertCapture(matcher, 1, nil)
        assertCapture(matcher, 2, "")
        assertCapture(matcher, 1, nil)
        assertCapture(matcher, 2, "")
    }

    func testGroupBeforeFindReturnsNilWithoutAdvancing() {
        let matcher = Pattern.compile("(x)").matcher(in: "x")
        XCTAssertNil(matcher.group())
        assertCapture(matcher, 1, nil)
        XCTAssertTrue(matcher.find())
        assertCapture(matcher, 1, "x")
    }

    func testNoMatchAndRepeatedFailedFindRemainSafe() {
        let matcher = Pattern.compile("x").matcher(in: "日本")
        XCTAssertEqual(matcher.count, 0)
        XCTAssertNil(matcher.group())
        for _ in 0..<128 {
            XCTAssertFalse(matcher.find())
            assertCapture(matcher, 0, nil)
        }
    }

    func testExhaustionDoesNotExposePreviousCapture() {
        let matcher = Pattern.compile("(x)").matcher(in: "x")
        XCTAssertTrue(matcher.find())
        assertCapture(matcher, 1, "x")
        for _ in 0..<128 {
            XCTAssertFalse(matcher.find())
            XCTAssertNil(matcher.group())
            assertCapture(matcher, 1, nil)
        }
        XCTAssertEqual(matcher.count, 1)
    }

    func testInvalidGroupIndicesDoNotTrapOrMoveCursor() {
        let matcher = Pattern.compile("(x)").matcher(in: "x")
        XCTAssertTrue(matcher.find())
        for group in [Int.min, -1, 2, 3, Int.max] {
            assertCapture(matcher, group, nil)
            assertCapture(matcher, 1, "x")
        }
        XCTAssertFalse(matcher.find())
    }

    func testSourceSnapshotAndCopiedPatternMatchersAreIndependent() {
        var source = "😀x"
        let pattern = Pattern.compile("(x|日)")
        let copy = pattern
        let first = pattern.matcher(in: source)
        let second = copy.matcher(in: "e\u{301}日")
        source = "replacement"
        XCTAssertTrue(first.find())
        assertCapture(first, 1, "x")
        XCTAssertTrue(second.find())
        assertCapture(second, 1, "日")
        XCTAssertFalse(first.find())
        assertCapture(second, 1, "日")
        XCTAssertEqual(source, "replacement")
    }

    func testConcurrentPatternReuseWithIndependentUnicodeCaptures() {
        final class Failures: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func record() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let failures = Failures()
        let pattern = Pattern.compile("(日|x)")
        DispatchQueue.concurrentPerform(iterations: 128) { index in
            let expected = index.isMultiple(of: 2) ? "日" : "x"
            let matcher = pattern.matcher(in: "👩🏽‍💻" + expected)
            if !matcher.find() || matcher.group(1).map({ Array($0.utf8) }) != Array(expected.utf8)
                || matcher.find() || matcher.group() != nil {
                failures.record()
            }
        }
        XCTAssertEqual(failures.count, 0)
    }

    func testGeneratedCapturesMatchIndependentUTF16SliceOracle() throws {
        let fragments = ["", "日本", "😀", "👩🏽‍💻", "e\u{301}", "é", "🇯🇵", "\r\n", "a\0b", "\u{600}x", "क्‍ष", "\u{10FFFF}"]
        let patterns = ["(.)", "(\\X)", "(\\p{L}+)(\\p{M}*)", "(a)?(b|日|😀)",
                        "(?=(.))", "^|$", "(e)(\u{301})", "(\r)(\n)"]
        for source in patterns {
            let pattern = Pattern.compile(source)
            let reference = try NSRegularExpression(pattern: source)
            for seed in 0..<128 {
                let input = fragments[seed % fragments.count]
                    + fragments[(seed * 7 + 3) % fragments.count] + "ab" + String(seed)
                let units = Array(input.utf16)
                let expected = reference.matches(in: input, range: NSRange(location: 0, length: units.count))
                let matcher = pattern.matcher(in: input)
                XCTAssertEqual(matcher.count, expected.count)
                for match in expected {
                    XCTAssertTrue(matcher.find())
                    for group in 0..<match.numberOfRanges {
                        let range = match.range(at: group)
                        let text: String? = range.location == NSNotFound ? nil
                            : String(decoding: units[range.location..<(range.location + range.length)], as: UTF16.self)
                        assertCapture(matcher, group, text)
                    }
                }
                XCTAssertFalse(matcher.find())
            }
        }
    }
}
