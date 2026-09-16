import XCTest
@testable import SwiftSoup

final class ForkCompatibilityTest: XCTestCase {
    func testAsyncHTMLParsingMatchesSyncParsing() async throws {
        let html = "<!doctype html><title>Title &amp; text</title><base href='https://example.test/'>" +
            "<p id='first' data-value='one &amp; two'>Hello <b>world</b></p>" +
            "<table><tr><td>Cell</table><a href='next'>Next</a><script>if (a < b) run()</script>"
        let expected = try SwiftSoup.parseHTML(html)
        let actual = try await SwiftSoup.parse(html)

        XCTAssertEqual(try actual.outerHtml(), try expected.outerHtml())
        XCTAssertEqual(try actual.text(), try expected.text())
        XCTAssertEqual(try actual.getElementById("first")?.attr("data-value"), "one & two")
        XCTAssertEqual(try actual.getElementsByTag("a").first()?.absUrl("href"), "https://example.test/next")
        XCTAssertEqual(actual.sourceBuffer?.bytes, expected.sourceBuffer?.bytes)
    }

    func testAsyncXMLAutoDetectionMatchesSyncParsing() async throws {
        let xml = " \n<?xml version='1.0'?><Root><Item ID='1'/><link>value</link></Root>"
        let expected = try SwiftSoup.parseXML(xml)
        let actual = try await SwiftSoup.parse(xml)

        XCTAssertTrue(actual.parsedAsXml)
        XCTAssertEqual(try actual.outerHtml(), try expected.outerHtml())
        XCTAssertEqual(try actual.getElementsByTag("Root").size(), 1)
    }

    func testAsyncParserPreservesSettingsAndMaterializesPendingAttributes() async throws {
        let parser = Parser.htmlParser()
            .settings(ParseSettings(false, false, false))
            .setTrackErrors(10)
        let html = "<p DATA-VALUE='one &amp; two' data-next='three'>Text</p></invalid>"
        let actual = try await parser.parseInput(html, "https://example.test/")
        let paragraph = try XCTUnwrap(actual.getElementsByTag("p").first())

        XCTAssertNil(actual.sourceBuffer)
        XCTAssertTrue(parser.getTreeBuilder().pendingAttributeElements.isEmpty)
        XCTAssertFalse(parser.getTreeBuilder().isBulkBuilding)
        XCTAssertEqual(paragraph.attributes?.pendingAttributesCount, 0)
        XCTAssertEqual(try paragraph.attr("data-value"), "one & two")
        XCTAssertEqual(try paragraph.attr("data-next"), "three")
        XCTAssertTrue(parser.getTreeBuilder().tracksErrors)
        XCTAssertTrue(parser.getTreeBuilder().errors === parser.getErrors())
    }

    func testAsyncSelectorsMatchSyncEvaluators() async throws {
        let doc = try await SwiftSoup.parse(
            "<section id='root'><p class='first'>One <b>bold</b></p>" +
            "<p data-value='two'>Two</p><aside><p>Three</p></aside></section>"
        )
        for query in ["*", "#root", ".first", "[data-value=two]", "p + p", "section:has(> p)", "p:has(+ p)", "p:nth-child(2)"] {
            let expected = try doc.select(QueryParser.parse(query)).array()
            let actual = try await doc.select(query).array()
            XCTAssertEqual(actual.map(ObjectIdentifier.init), expected.map(ObjectIdentifier.init), query)
        }
    }

    func testCancelledAsyncParsingAndSelectionReturnPartialResults() async throws {
        let task = Task {
            let root = try SwiftSoup.parseHTML("<p>One</p><p>Two</p>")
            withUnsafeCurrentTask { $0?.cancel() }
            let parsed = try await SwiftSoup.parse("<p>Not parsed</p>")
            let selected = try await root.select("p")
            return (parsed.childNodeSize(), selected.size())
        }
        let (nodeCount, matchCount) = try await task.value
        XCTAssertEqual(nodeCount, 0)
        XCTAssertEqual(matchCount, 0)
    }

    func testAsyncParserStopsWhenCancelledDuringTokenProcessing() async throws {
        final class CancellingBuilder: HtmlTreeBuilder {
            var processedCount = 0
            private var processingDepth = 0

            override func process(_ token: Token) throws -> Bool {
                processingDepth += 1
                defer { processingDepth -= 1 }
                let result = try super.process(token)
                if processingDepth == 1 {
                    processedCount += 1
                    if processedCount == 5 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
                return result
            }
        }

        let task = Task {
            let builder = CancellingBuilder()
            let html = String(repeating: "<p data-value='value'>Text</p>", count: 100)
            _ = try await builder.parse(html, "", ParseErrorList.noTracking(), ParseSettings(false, false, false))
            return (builder.processedCount, builder.isBulkBuilding, builder.pendingAttributeElements.isEmpty)
        }
        let (count, isBulkBuilding, hasNoPendingAttributes) = try await task.value
        XCTAssertEqual(count, 5)
        XCTAssertFalse(isBulkBuilding)
        XCTAssertTrue(hasNoPendingAttributes)
    }

    func testAsyncTraversalMatchesSyncOrderAndStopsOnCancellation() async throws {
        final class Visitor: NodeVisitor {
            var events: [String] = []
            let cancelOnHead: Bool

            init(cancelOnHead: Bool = false) {
                self.cancelOnHead = cancelOnHead
            }

            func head(_ node: Node, _ depth: Int) {
                events.append("head:\(node.nodeName()):\(depth)")
                if cancelOnHead {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }

            func tail(_ node: Node, _ depth: Int) {
                events.append("tail:\(node.nodeName()):\(depth)")
            }
        }

        let doc = try SwiftSoup.parseHTML("<p>One<b>Two</b></p><p>Three</p>")
        let expected = Visitor()
        try doc.traverse(expected)
        let actual = Visitor()
        try await NodeTraversor(actual).traverse(doc)
        XCTAssertEqual(actual.events, expected.events)

        let task = Task {
            let root = try SwiftSoup.parseHTML("<p>One<b>Two</b></p>")
            let visitor = Visitor(cancelOnHead: true)
            try await NodeTraversor(visitor).traverse(root)
            return visitor.events
        }
        let cancelledEvents = try await task.value
        XCTAssertEqual(cancelledEvents, ["head:#document:0"])
    }

    func testForkInlineAndWhitespaceFormatting() throws {
        let doc = try SwiftSoup.parse("<div>Text<span>inline</span></div>")
        XCTAssertEqual(try doc.body()?.html(), "<div>\n Text<span>inline</span>\n</div>")

        let pre = try SwiftSoup.parse("<pre><code>  one\n  two</code></pre>")
        XCTAssertEqual(try pre.body()?.html(), "<pre><code>  one\n  two</code></pre>")
    }

    func testEffectivelyFirstIgnoresOnlyLeadingBlankText() throws {
        for (html, expected) in [
            ("<div><span></span></div>", true),
            ("<div> \n<span></span></div>", true),
            ("<div>text<span></span></div>", false),
            ("<div><b></b><span></span></div>", false),
            ("<div> <b></b><span></span></div>", false)
        ] {
            let doc = try SwiftSoup.parse(html)
            let span = try XCTUnwrap(doc.getElementsByTag("span").first())
            XCTAssertTrue(span.isNode("span"))
            XCTAssertFalse(span.isNode("div"))
            XCTAssertEqual(span.isEffectivelyFirst(), expected, html)
        }
    }
}
