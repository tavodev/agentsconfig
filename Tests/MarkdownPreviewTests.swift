import Testing
import Foundation

extension AgentsConfigTestSuite {
@Suite("Markdown preview")
struct MarkdownPreviewTests {
    @Test func mixedListsUseNearestContainer() {
        let blocks = MarkdownBlock.parse("1. Parent\n   - Child\n     1. Grandchild")
        #expect(blocks.count == 3)
        #expect(blocks.map(\.isOrderedListItem) == [true, false, true])
        #expect(blocks.map(\.listDepth) == [1, 2, 3])
    }

    @Test func continuationParagraphDoesNotRepeatMarker() {
        let blocks = MarkdownBlock.parse("- First paragraph\n\n  Second paragraph\n\n- Next item")
        #expect(blocks.count == 3)
        #expect(blocks.map(\.showsListMarker) == [true, false, true])
    }

    @Test func nestedQuoteRetainsCodeLanguageAndContent() {
        let blocks = MarkdownBlock.parse("> > ```swift\n> > let value = 1\n> > ```")
        #expect(blocks.count == 1)
        #expect(blocks.first?.quoteDepth == 2)
        #expect(blocks.first?.codeLanguage == "swift")
        #expect(blocks.first?.isCodeBlock == true)
        #expect(String(blocks[0].content.characters).contains("let value = 1"))
    }

    @Test func duplicateHeadingsHaveDistinctNavigationIDs() {
        let blocks = MarkdownBlock.parse("# Same\n\nText with **emphasis**.\n\n# Same")
        let headings = blocks.filter { $0.headerLevel != nil }
        #expect(headings.count == 2)
        #expect(Set(headings.map(\.id)).count == 2)
        #expect(blocks.count == 3)
    }
}
}
