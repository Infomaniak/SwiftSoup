import XCTest
@testable import SwiftSoup

final class CssIndexConsistencyTest: XCTestCase {
    // Deliberately avoid Collector and all query indexes for the reference walk.
    private func scan(_ root: Element, _ evaluator: Evaluator) throws -> [Element] {
        var result: [Element] = []
        var stack = [root]
        while let element = stack.popLast() {
            if try evaluator.matches(root, element) { result.append(element) }
            for child in element.childNodes.reversed() {
                if let child = child as? Element { stack.append(child) }
            }
        }
        return result
    }

    private func assertPaths(_ root: Element, _ query: String, _ ids: [String]? = nil,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let evaluator = try QueryParser.parse(query)
        let reference = try scan(root, evaluator)
        if let ids {
            XCTAssertEqual(reference.map { $0.id() }, ids, "scan: \(query)", file: file, line: line)
        }
        let expected = reference.map(ObjectIdentifier.init)
        XCTAssertEqual(try Collector.collect(evaluator, root).array().map(ObjectIdentifier.init), expected,
                       "collector: \(query)", file: file, line: line)
        XCTAssertEqual(try CssSelector.select(evaluator, root).array().map(ObjectIdentifier.init), expected,
                       "evaluator selection: \(query)", file: file, line: line)
        for _ in 0..<4 {
            XCTAssertEqual(try root.select(query).array().map(ObjectIdentifier.init), expected,
                           "public: \(query)", file: file, line: line)
        }
    }

    func testRepeatedClassTokensAreUniqueInCombinedIndex() throws {
        let doc = try SwiftSoup.parse("<p id='a' class='x x y X'></p><p id='b' class='x y'></p>")
        for query in [".x", "p.x", ".x.y", #".\78"#, #"p.\78"#, #":not(:not(.\78))"#] {
            try assertPaths(doc, query, ["a", "b"])
        }
        XCTAssertEqual(try doc.getElementsByClass("x").array().map { $0.id() }, ["a", "b"])
    }

    func testRepeatedClassTokensAreUniqueInClassOnlyRebuild() throws {
        let doc = try SwiftSoup.parse("<p id='a' class='x x'></p><p id='b' class='x'></p>")
        _ = try doc.getElementsByClass("x")
        XCTAssertFalse(doc.isIdQueryIndexDirty)
        XCTAssertFalse(doc.isAttributeQueryIndexDirty)
        XCTAssertFalse(doc.isAttributeValueQueryIndexDirty)
        // Force the solo rebuild rather than accidentally testing only the combined path.
        doc.isClassQueryIndexDirty = true
        try assertPaths(doc, ".x", ["a", "b"])
    }

    func testRepeatedClassSeedsInDescendantsAndHas() throws {
        let doc = try SwiftSoup.parse("<main id='main' class='x x'><section id='s'><p id='a' class='x x y'></p><p id='b' class='y'></p></section></main>")
        for query in ["main .x", "section > .x", "p.x.y", #"main .\78"#, ".x:not(#main)"] {
            try assertPaths(doc, query, ["a"])
        }
        try assertPaths(doc, "main:has(.x)", ["main"])
        try assertPaths(doc, "section:has(> .x)", ["s"])
        let main = try XCTUnwrap(doc.getElementById("main"))
        try assertPaths(main, ".x", ["main", "a"])
    }

    func testRepeatedClassTokensAcrossOverlappingRoots() throws {
        let doc = try SwiftSoup.parse("<main id='main' class='x x'><p id='a' class='x x'></p><p id='b' class='x'></p></main>")
        let main = try XCTUnwrap(doc.getElementById("main"))
        let a = try XCTUnwrap(doc.getElementById("a"))
        for query in [".x", #".\78"#, ".x:not(#absent)"] {
            for _ in 0..<4 {
                XCTAssertEqual(try CssSelector.select(query, [doc, main, a, doc]).array().map { $0.id() }, ["main", "a", "b"])
                XCTAssertEqual(try CssSelector.select(query, [a, main]).array().map { $0.id() }, ["a", "main", "b"])
                try assertPaths(main, query, ["main", "a", "b"])
            }
        }
    }

    func testClassMutationPreservesUnicodeDistinctionsAndDeduplicates() throws {
        let doc = try SwiftSoup.parse("<p id='a'></p><p id='b'></p>")
        let a = try XCTUnwrap(doc.getElementById("a"))
        let b = try XCTUnwrap(doc.getElementById("b"))
        for value in ["x", "é", "e\u{301}", "日本", "x\u{B}y", "x\u{600}", "👩‍💻"] {
            try a.attr("class", value + " " + value + " other " + value)
            try b.attr("class", value)
            let escaped = value.unicodeScalars.map { "\\" + String($0.value, radix: 16) + " " }.joined()
            try assertPaths(doc, "." + escaped, ["a", "b"])
            try assertPaths(doc, "p." + escaped, ["a", "b"])
            try a.removeAttr("class")
            try assertPaths(doc, "." + escaped, ["b"])
        }
    }

    func testEmptyAttributeEqualityAcrossEverySelectionPath() throws {
        let doc = try SwiftSoup.parse("<p id='empty' data-v=''></p><p id='full' data-v='abc'></p><p id='missing'></p>")
        for query in ["[data-v='']", "p[data-v='']", "[data-v='']:not(#absent)", "p:not(:not([data-v='']))"] {
            try assertPaths(doc, query, ["empty"])
        }
        XCTAssertEqual(try doc.getElementsByAttributeValue("data-v", "").array().map { $0.id() }, ["empty"])
    }

    func testEmptyAttributeEqualityRetainsExistingTrimSemantics() throws {
        let doc = try SwiftSoup.parse("<p id='empty' data-v=''></p><p id='space' data-v=' \t\n'></p><p id='full' data-v='abc'></p>")
        // SwiftSoup equality historically trims values. This is not a browser-CSS assertion.
        try assertPaths(doc, "p[data-v='']", ["empty", "space"])
        try assertPaths(doc, "p[data-v='abc']", ["full"])
    }

    func testEmptyAttributeNegationDistinguishesMissingFromEmpty() throws {
        let doc = try SwiftSoup.parse("<p id='empty' data-v=''></p><p id='full' data-v='abc'></p><p id='missing'></p>")
        for query in ["p[data-v!='']", "p:not([data-v=''])"] {
            try assertPaths(doc, query, ["full", "missing"])
        }
    }

    func testEmptySubstringOperandsNeverMatch() throws {
        let doc = try SwiftSoup.parse("<p id='empty' data-v=''></p><p id='full' data-v='abc'></p><p id='missing'></p>")
        for op in ["^=", "$=", "*="] {
            for prefix in ["", "p"] {
                try assertPaths(doc, prefix + "[data-v" + op + "'']", [])
                try assertPaths(doc, prefix + "[data-v" + op + "'']:not(#absent)", [])
            }
        }
    }

    func testRegexCanMatchPresentEmptyPhysicalAttributes() throws {
        let doc = try SwiftSoup.parse("<p id='empty' data-v=''></p><p id='full' data-v='abc'></p><p id='missing'></p>")
        for query in ["[data-v~=^$]", "p[data-v~=^$]", "[data-v~=^$]:not(#absent)"] {
            try assertPaths(doc, query, ["empty"])
        }
        XCTAssertEqual(try doc.getElementsByAttributeValueMatching("data-v", "^$").array().map { $0.id() }, ["empty"])
    }

    func testEmptyVirtualValuesDoNotInventResolvedAttributes() throws {
        let doc = try SwiftSoup.parse("<a id='relative' href='/item'></a><a id='empty' href=''></a><a id='absolute' href='https://example.com/a'></a><a id='missing'></a>")
        for query in ["[abs:href='']", "[abs:href~=^$]", "[abs:href^='']", "[abs:href$='']", "[abs:href*='']"] {
            try assertPaths(doc, query, [])
            try assertPaths(doc, query + ":not(#absent)", [])
        }
        try doc.setBaseUri("https://example.com")
        for query in ["[abs:href='']", "[abs:href~=^$]", "[abs:href^='']", "[abs:href$='']", "[abs:href*='']"] {
            try assertPaths(doc, query, [])
        }
    }

    func testEmptyValuesTrackMutationAfterCachePromotion() throws {
        let doc = try SwiftSoup.parse("<p id='a' data-v=''></p><p id='b' data-v='abc'></p>")
        let a = try XCTUnwrap(doc.getElementById("a"))
        let b = try XCTUnwrap(doc.getElementById("b"))
        for query in ["p[data-v='']", "p[data-v~=^$]"] { try assertPaths(doc, query, ["a"]) }
        try a.attr("data-v", "abc")
        try b.attr("data-v", "")
        for query in ["p[data-v='']", "p[data-v~=^$]"] { try assertPaths(doc, query, ["b"]) }
        try b.removeAttr("data-v")
        for query in ["p[data-v='']", "p[data-v~=^$]"] { try assertPaths(doc, query, []) }
    }

    func testNonAsciiEqualityFastPlansUseParserNormalization() throws {
        let doc = try SwiftSoup.parse("<p id='a'></p><p id='b'></p><p id='other'></p>")
        let a = try XCTUnwrap(doc.getElementById("a"))
        let b = try XCTUnwrap(doc.getElementById("b"))
        // Preserve the parser's existing normalization; do not introduce Unicode case folding.
        for value in ["É", "Ä", "İ", "Σ", "日本", "\u{A0}abc\u{A0}", "é", "e\u{301}"] {
            try a.attr("data-v", value)
            try b.attr("data-v", value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
            for prefix in ["", "p", "body "] {
                try assertPaths(doc, prefix + "[data-v='" + value + "']")
            }
        }
    }

    func testPaddedVirtualAttributeValueGetterUsesResolvedLookup() throws {
        let doc = try SwiftSoup.parse("<a id='hit' href='/item'></a><a id='miss' href='/other'></a>", "https://example.com")
        for key in ["abs:href", " ABS:href ", "\tabs:href\n"] {
            for _ in 0..<4 {
                XCTAssertEqual(try doc.getElementsByAttributeValue(key, "https://example.com/item").array().map { $0.id() }, ["hit"], key)
            }
        }
    }

    func testDynamicAttributeIndexesRemainCorrectThroughEviction() throws {
        let doc = try SwiftSoup.parse("<p id='a'></p><p id='b'></p>")
        let a = try XCTUnwrap(doc.getElementById("a"))
        let b = try XCTUnwrap(doc.getElementById("b"))
        for index in 0..<20 {
            try a.attr("data-k\(index)", "a")
            try b.attr("data-k\(index)", "b")
        }
        for _ in 0..<3 {
            for index in (0..<20).reversed() {
                let key = "data-k\(index)"
                try assertPaths(doc, "[\(key)=a]", ["a"])
                try a.attr(key, "b")
                try b.attr(key, "a")
                try assertPaths(doc, "[\(key)=a]:not(#absent)", ["b"])
                try a.attr(key, "a")
                try b.attr(key, "b")
                try assertPaths(doc, "p[\(key)=a]", ["a"])
            }
        }
    }

    func testSelectionAfterReparentingRemovalReplacementAndClone() throws {
        let doc = try SwiftSoup.parse("<main><section id='left'><p id='a' class='x x'></p><p id='b' class='y'></p></section><section id='right'><p id='c' class='x'></p></section></main>")
        let left = try XCTUnwrap(doc.getElementById("left"))
        let right = try XCTUnwrap(doc.getElementById("right"))
        let a = try XCTUnwrap(doc.getElementById("a"))
        let b = try XCTUnwrap(doc.getElementById("b"))
        let queries = [".x", #".\78"#, "p:first-child", "p:last-child", "p:nth-child(2)", "p + p", "p ~ p", "section:has(> .x)"]
        func checkAll() throws {
            for root in [doc, left, right, a] {
                for query in queries { try assertPaths(root, query) }
            }
        }
        try checkAll()
        try right.appendChild(a)
        try checkAll()
        try a.remove()
        try checkAll()
        try left.prependChild(a)
        try checkAll()
        let clone = a.copy() as! Element
        try clone.attr("id", "clone")
        try b.replaceWith(clone)
        try checkAll()
        try assertPaths(left, ".x", ["a", "clone"])
    }

    func testCasePreservingAttributeMutationMatchesCaseInsensitivePredicates() throws {
        let doc = try SwiftSoup.parse("<p id='hit'></p><p id='missing'></p>")
        let hit = try XCTUnwrap(doc.getElementById("hit"))
        for key in ["DATA-V", "Data-V", "data-v"] {
            try hit.attr(key, "item42")
            for query in ["[data-v=item42]", "[data-v^=item]", "[data-v$=42]", "[data-v*=tem]", "[data-v~=^item42$]"] {
                try assertPaths(doc, query, ["hit"])
                try assertPaths(doc, query + ":not(#absent)", ["hit"])
            }
            try hit.attr(key, "")
            try assertPaths(doc, "p[data-v='']", ["hit"])
            try assertPaths(doc, "[data-v~=^$]", ["hit"])
            try hit.removeAttr(key)
        }
    }

    func testDeterministicMutationMatrixMatchesIndependentScan() throws {
        let doc = try SwiftSoup.parse("<main><section id='left'></section><section id='right'></section></main>", "https://old.example")
        let left = try XCTUnwrap(doc.getElementById("left"))
        let right = try XCTUnwrap(doc.getElementById("right"))
        var leaves: [Element] = []
        for index in 0..<12 {
            let leaf = try left.appendElement("p")
            try leaf.attr("id", "n\(index)").attr("href", "/item\(index)")
            leaves.append(leaf)
        }
        let queries = ["p", "span", ".x", #".\78"#, ".x.y", #".\e9"#, #".e\301"#,
                       "[data-v='']", "[data-v=item42]", "[data-v^=item]:not(#absent)",
                       "[data-v$=42]", "[data-v*=tem]", "[data-v~=^$]", "[data-v!=item42]",
                       "p:first-child", "p:last-child", "p:nth-child(2n+1)", "p:nth-last-child(2)",
                       "p + p", "p ~ p", "section > .x", ":has(> .x)", ":has(.x)",
                       "p:contains(item)", "p:not(.x)", "p, .x", "[abs:href^=https://new.example]"]
        var seed: UInt32 = 0x51EC70
        for step in 0..<96 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let target = leaves[Int(seed % UInt32(leaves.count))]
            switch step % 8 {
            case 0: try target.attr("class", ["x x y", "y", "é é", "e\u{301} e\u{301}"][Int(seed >> 16) % 4])
            case 1: try target.attr("data-v", (seed & 0x100) == 0 ? "" : "item42")
            case 2: try target.removeAttr("data-v")
            case 3: try ((seed & 0x100) == 0 ? left : right).appendChild(target)
            case 4: try target.tagName((seed & 0x100) == 0 ? "span" : "p")
            case 5: try target.text((seed & 0x100) == 0 ? "item" : "other")
            case 6: try ((seed & 0x100) == 0 ? left : right).setBaseUri("https://new.example")
            default: try target.attr("class", "x y x")
            }
            for root in [doc, left, right] {
                for query in queries { try assertPaths(root, query) }
            }
        }
    }

    func testUnicodeQueriesRemainDistinctAfterCacheEviction() throws {
        let doc = try SwiftSoup.parse("<p id='é' class='é é'></p><p id='e&#x301;' class='e&#x301; e&#x301;'></p>")
        let queries = ["#é", "#e\u{301}", ".é", ".e\u{301}", #"#\e9"#, #"#e\301"#]
        for query in queries { try assertPaths(doc, query) }
        // Exceeds all four default query-cache capacities, including the parser's 300.
        for index in 0..<340 {
            try assertPaths(doc, "p:not(#absent-\(index))", ["é", "e\u{301}"])
        }
        for query in queries.reversed() { try assertPaths(doc, query) }
        XCTAssertTrue(try doc.select("#é").first() !== doc.select("#e\u{301}").first())
    }

    func testGeneratedClassSelectorsRoundTripRepeatedTokensWithoutAnId() throws {
        for value in ["x", "123", "x y", "é", "e\u{301}", "x\u{B}", "x\u{600}"] {
            let doc = try SwiftSoup.parse("<main><p></p><p></p></main>")
            let target = try XCTUnwrap(doc.select("p").first())
            try target.attr("class", value + " " + value)
            let generated = try target.cssSelector()
            for _ in 0..<4 {
                let results = try doc.select(generated)
                XCTAssertEqual(results.size(), 1, generated)
                XCTAssertTrue(results.first() === target, generated)
            }
        }
    }
}
