import Foundation
import Testing
@testable import VibeCore

struct MarkdownBlocksTests {
    @Test func headingsParagraphsAndRules() {
        let blocks = MarkdownBlocks.parse("# Title\n\nSome text\nthat continues.\n\n---\n\n### Small")
        #expect(blocks == [.heading(level: 1, text: "Title"), .paragraph("Some text\nthat continues."), .rule,
                           .heading(level: 3, text: "Small")])
    }

    @Test func codeFencesKeepTheirTextAndLanguage() {
        let blocks = MarkdownBlocks.parse("Before\n```swift\nlet a = 1\n\n  indented\n```\nAfter")
        #expect(blocks == [.paragraph("Before"), .code(language: "swift", text: "let a = 1\n\n  indented"), .paragraph("After")])
    }

    @Test func anUnterminatedFenceRunsToTheEnd() {
        #expect(MarkdownBlocks.parse("```\nopen\nstill code") == [.code(language: nil, text: "open\nstill code")])
    }

    @Test func listsWithNestingNumbersAndCheckboxes() {
        let blocks = MarkdownBlocks.parse("- one\n  - nested\n- [x] done\n- [ ] todo\n\n3. third\n4. fourth")
        #expect(blocks == [
            .list(ordered: false, start: 1, items: [MDListItem(text: "one", depth: 0), MDListItem(text: "nested", depth: 1),
                                                     MDListItem(text: "done", depth: 0, checked: true),
                                                     MDListItem(text: "todo", depth: 0, checked: false)]),
            .list(ordered: true, start: 3, items: [MDListItem(text: "third", depth: 0), MDListItem(text: "fourth", depth: 0)]),
        ])
    }

    @Test func aListItemContinuesOnIndentedLines() {
        #expect(MarkdownBlocks.parse("1. first line\n   more of it\n2. second") ==
                [.list(ordered: true, start: 1, items: [MDListItem(text: "first line more of it", depth: 0),
                                                        MDListItem(text: "second", depth: 0)])])
    }

    @Test func tablesWithAndWithoutOuterPipes() {
        let expected = MDBlock.table(header: ["Name", "Count"], alignments: [.leading, .trailing],
                                     rows: [["a", "1"], ["b | c", "2"]])
        #expect(MarkdownBlocks.parse("| Name | Count |\n|:---|---:|\n| a | 1 |\n| b \\| c | 2 |") == [expected])
        #expect(MarkdownBlocks.parse("Name | Count\n:--- | ---:\na | 1\nb \\| c | 2") == [expected])
    }

    @Test func aPipeLineWithoutADelimiterRowIsAParagraph() {
        #expect(MarkdownBlocks.parse("a | b\nc | d") == [.paragraph("a | b\nc | d")])
    }

    @Test func quotesAndCRLF() {
        #expect(MarkdownBlocks.parse("> quoted\r\n> more\r\n\r\nplain") == [.quote("quoted\nmore"), .paragraph("plain")])
    }

    @Test func centeredAlignment() {
        #expect(MarkdownBlocks.parse("|a|\n|:-:|\n|x|") == [.table(header: ["a"], alignments: [.center], rows: [["x"]])])
    }
}

struct MarkdownReviewFixTests {
    @Test func aPipeLineBeforeARuleIsNotATable() {
        #expect(MarkdownBlocks.parse("a | b\n---\nafter") == [.paragraph("a | b"), .rule, .paragraph("after")])
    }

    @Test func aFenceInsideAListItemIsACodeBlock() {
        #expect(MarkdownBlocks.parse("1. Run:\n   ```bash\n   swift test\n   ```\n2. Done") == [
            .list(ordered: true, start: 1, items: [MDListItem(text: "Run:", depth: 0)]),
            .code(language: "bash", text: "   swift test"),
            .list(ordered: true, start: 2, items: [MDListItem(text: "Done", depth: 0)]),
        ])
    }
}
