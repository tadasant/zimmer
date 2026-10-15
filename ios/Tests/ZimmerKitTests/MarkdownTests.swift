import XCTest
@testable import ZimmerKit

/// A message's markdown cut into the blocks the web UI draws: what an agent's report is made of.
final class MarkdownTests: XCTestCase {
    private func blocks(_ text: String) -> [MarkdownBlock] { MarkdownBlock.blocks(of: text) }

    func testHeadingsAtEveryLevelAndNotAnIssueNumber() {
        XCTAssertEqual(blocks("# One\n## Two ##\n###### Six\n####### Seven\n#1293 is open"), [
            .heading(level: 1, text: "One"),
            .heading(level: 2, text: "Two"),
            .heading(level: 6, text: "Six"),
            .paragraph("####### Seven\n#1293 is open"),
        ])
        XCTAssertEqual(blocks("Title\n=====\n\nSubtitle\n---"), [.heading(level: 1, text: "Title"), .heading(level: 2, text: "Subtitle")])
    }

    func testParagraphsKeepTheirLineBreaksAndSplitOnBlankLines() {
        XCTAssertEqual(blocks("First line\n  second line\n\n\nThird."), [.paragraph("First line\nsecond line"), .paragraph("Third.")])
        XCTAssertEqual(blocks(""), [])
        XCTAssertEqual(blocks("Just **words** with `code`."), [.paragraph("Just **words** with `code`.")])
    }

    func testFencedCodeIsKeptAsWrittenWithItsLanguage() {
        let text = "Two ways:\n\n```sh\nbin/rails db:upgrade\n  --target 16\n```\n\nWhich?"
        XCTAssertEqual(blocks(text), [
            .paragraph("Two ways:"),
            .code("bin/rails db:upgrade\n  --target 16", language: "sh"),
            .paragraph("Which?"),
        ])
        XCTAssertEqual(blocks("~~~ ruby linenos\n# not a heading\n~~~"), [.code("# not a heading", language: "ruby")])
        XCTAssertEqual(blocks("````\n```\ninner\n```\n````"), [.code("```\ninner\n```", language: nil)], "a longer fence holds a shorter one")
        XCTAssertEqual(blocks("Look:\n```\nx = 1\ny = 2"), [.paragraph("Look:"), .code("x = 1\ny = 2", language: nil)], "an unclosed fence runs to the end")
        XCTAssertEqual(blocks("```\n```"), [.code("", language: nil)], "an empty block is still a block")
        XCTAssertEqual(blocks("Text\n\n    indented code\n\n    more\n\nAfter"), [
            .paragraph("Text"), .code("indented code\n\nmore", language: nil), .paragraph("After"),
        ])
    }

    func testToolTrafficAsTheServerWritesIt() {
        XCTAssertEqual(blocks("**Using tool: Bash**\n```\ngh pr checks 1261\n```"), [
            .paragraph("**Using tool: Bash**"), .code("gh pr checks 1261", language: nil),
        ])
    }

    func testListsNestAndKeepTheirNumbers() {
        let text = "Steps:\n1. Lift it\n   - above the safe area\n   - as the web does\n2. Re-shoot\n\n- one\n* two\n+ three"
        XCTAssertEqual(blocks(text), [
            .paragraph("Steps:"),
            .list(MarkdownList(ordered: true, items: [
                [.paragraph("Lift it"), .list(MarkdownList(ordered: false, items: [[.paragraph("above the safe area")], [.paragraph("as the web does")]]))],
                [.paragraph("Re-shoot")],
            ])),
            .list(MarkdownList(ordered: false, items: [[.paragraph("one")], [.paragraph("two")], [.paragraph("three")]])),
        ])
        XCTAssertEqual(blocks("3. three\n4) four"), [.list(MarkdownList(ordered: true, start: 3, items: [[.paragraph("three")], [.paragraph("four")]]))])
        XCTAssertEqual(MarkdownList(ordered: true, start: 3, items: [[], []]).marker(at: 1), "4.")
        XCTAssertEqual(MarkdownList(ordered: false, items: [[]]).marker(at: 0, depth: 1), "◦")
    }

    func testAListNestsByTwoSpacesUnderANumberAndANumberMidParagraphIsProse() {
        XCTAssertEqual(blocks("1. foo\n  - bar\n2. baz"), [
            .list(MarkdownList(ordered: true, items: [
                [.paragraph("foo"), .list(MarkdownList(ordered: false, items: [[.paragraph("bar")]]))],
                [.paragraph("baz")],
            ])),
        ])
        XCTAssertEqual(blocks("Shipped in\n2024. The next one\n1. first"), [
            .paragraph("Shipped in\n2024. The next one"),
            .list(MarkdownList(ordered: true, items: [[.paragraph("first")]])),
        ])
        XCTAssertEqual(blocks("```ruby\tlinenos\nx\n```"), [.code("x", language: "ruby")])
    }

    func testAListItemHoldsCodeAndLazyLinesAndFourSpaceNesting() {
        let text = "- Run:\n\n  ```sh\n  bin/ci\n  ```\n- a long item\nthat wraps lazily\n    - nested by four"
        XCTAssertEqual(blocks(text), [
            .list(MarkdownList(ordered: false, items: [
                [.paragraph("Run:"), .code("bin/ci", language: "sh")],
                [.paragraph("a long item\nthat wraps lazily"), .list(MarkdownList(ordered: false, items: [[.paragraph("nested by four")]]))],
            ])),
        ])
        XCTAssertEqual(blocks(text).containsCode, true, "a Copy button inside a list is still reachable")
        XCTAssertEqual(blocks("- one\n\nAfter the list."), [
            .list(MarkdownList(ordered: false, items: [[.paragraph("one")]])), .paragraph("After the list."),
        ])
    }

    func testRulesAreNotListsAndAreNotHeadingsAfterABlankLine() {
        XCTAssertEqual(blocks("Above\n\n---\n\n* * *\n___"), [.paragraph("Above"), .rule, .rule, .rule])
    }

    func testQuotesHoldBlocksAndLazyLines() {
        XCTAssertEqual(blocks("> Fix the overlay first;\nthe nits can wait.\n>\n> - one\n\nAfter"), [
            .quote([.paragraph("Fix the overlay first;\nthe nits can wait."), .list(MarkdownList(ordered: false, items: [[.paragraph("one")]]))]),
            .paragraph("After"),
        ])
        XCTAssertEqual(blocks(">> nested"), [.quote([.quote([.paragraph("nested")])])])
    }

    func testTablesWithAlignmentsEscapedPipesAndRaggedRows() {
        let text = "Summary:\n| Check | Result | Count |\n| :--- | :---: | ---: |\n| Build | `a\\|b` | 1 |\n| UI \\| tests | 2 failed |\n\nAfter"
        XCTAssertEqual(blocks(text), [
            .paragraph("Summary:"),
            .table(MarkdownTable(header: ["Check", "Result", "Count"], alignments: [.leading, .center, .trailing], rows: [
                ["Build", "`a|b`", "1"],
                ["UI | tests", "2 failed", ""],
            ])),
            .paragraph("After"),
        ])
        XCTAssertEqual(blocks("a | b\n--- | ---\n1 | 2"), [
            .table(MarkdownTable(header: ["a", "b"], alignments: [.leading, .leading], rows: [["1", "2"]])),
        ], "pipes at the ends are optional")
        XCTAssertEqual(blocks("a | b\n| --- |"), [.paragraph("a | b\n| --- |")], "a header must have as many cells as its delimiter row")
    }

    func testATableWiderThanThePhoneWrapsItsWidestColumnsThenScrolls() {
        XCTAssertEqual(MarkdownTable.columnWidths(natural: [40, 60], available: 340), [40, 300], "a table that fits spans its box, the last column stretched")
        XCTAssertEqual(MarkdownTable.columnWidths(natural: [40, 300, 200], available: 340), [40, 150, 150], "the wide columns share what is left")
        XCTAssertEqual(MarkdownTable.columnWidths(natural: Array(repeating: 100, count: 6), available: 340), Array(repeating: 72, count: 6),
                       "no column under the floor; the table scrolls")
        XCTAssertEqual(MarkdownTable.columnWidths(natural: [500], available: 0), [500], "before the width is known, the natural one")
    }

    func testTheFixtureReviewIsEveryKindOfBlock() {
        let review = FakeZimmerAPI.sampleConversations(now: Date())[1048]!.last!.content
        let kinds = blocks(review).map { block -> String in
            switch block {
            case let .heading(level, _): return "h\(level)"
            case .paragraph: return "p"
            case .code: return "code"
            case .list: return "list"
            case .quote: return "quote"
            case .table: return "table"
            case .rule: return "rule"
            }
        }
        XCTAssertEqual(kinds, ["h2", "p", "h3", "p", "code", "list", "table", "quote", "p"])
        XCTAssertTrue(blocks(review).containsLink)
    }

    func testAParagraphWithALinkIsFoundHoweverDeep() {
        XCTAssertTrue(blocks("See [the diff](https://example.com).").containsLink)
        XCTAssertTrue(blocks("- one\n  > at https://maps.example.com/x").containsLink)
        XCTAssertFalse(blocks("No links.\n\n```\ncurl https://example.com\n```\n\n# https://heading.example.com").containsLink,
                       "code and headings are drawn as text, with no link menu to reach")
    }

    func testBareURLsAreFoundWithoutTheirClosingPunctuation() {
        let text = "See https://github.com/tadasant/zimmer/pull/1293. Also (https://example.com/a_(b)) and http://x.io/y?z=1,"
        let matches = MarkdownAutolink.matches(in: text)
        XCTAssertEqual(matches.map(\.url.absoluteString), [
            "https://github.com/tadasant/zimmer/pull/1293",
            "https://example.com/a_(b)",
            "http://x.io/y?z=1",
        ])
        let first = matches[0]
        let start = text.index(text.startIndex, offsetBy: first.offset)
        XCTAssertEqual(String(text[start...].prefix(first.length)), "https://github.com/tadasant/zimmer/pull/1293")
        XCTAssertEqual(MarkdownAutolink.matches(in: "émoji 🎉 https://a.io"), [MarkdownAutolink.Match(offset: 8, length: 12, url: URL(string: "https://a.io")!)],
                       "offsets count characters, as an AttributedString's do")
        XCTAssertEqual(MarkdownAutolink.matches(in: "no links, just https:// alone"), [])
    }
}
