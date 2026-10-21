import Testing
import Foundation
import SwiftUI
import AppKit

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

    // MARK: - Second delivery: tables

    @Test func tableCellsMergeIntoSingleTableBlock() throws {
        let blocks = MarkdownBlock.parse("""
        | Name | Value |
        | ---- | ----- |
        | a    | 1     |
        | b    | 2     |

        After table.
        """)
        let tables = blocks.filter { $0.table != nil }
        #expect(tables.count == 1)
        let table = try #require(tables.first?.table)
        #expect(table.columns.count == 2)
        #expect(table.header.map { String($0.characters) } == ["Name", "Value"])
        #expect(table.rows.map { $0.map { String($0.characters) } } == [["a", "1"], ["b", "2"]])
        #expect(blocks.last?.table == nil)
        #expect(String(blocks.last.map { String($0.content.characters) } ?? "").contains("After table."))
    }

    @Test func adjacentTablesStaySeparateBlocks() throws {
        let blocks = MarkdownBlock.parse("""
        | A | B |
        | - | - |
        | 1 | 2 |

        | C | D |
        | - | - |
        | 3 | 4 |
        """)
        let tables = blocks.compactMap(\.table)
        #expect(tables.count == 2)
        #expect(tables[0].header.map { String($0.characters) } == ["A", "B"])
        #expect(tables[1].header.map { String($0.characters) } == ["C", "D"])
        #expect(Set(blocks.map(\.id)).count == blocks.count)
    }

    @Test func tableColumnAlignmentsArePreserved() throws {
        let blocks = MarkdownBlock.parse("""
        | L | C | R |
        |:--|:-:|--:|
        | a | b | c |
        """)
        let table = try #require(blocks.first?.table)
        #expect(table.columns.count == 3)
        #expect(table.columns.map { String(describing: $0.alignment) }
            == ["left", "center", "right"])
    }

    @Test func sparseTableRowsPadMissingCells() throws {
        let blocks = MarkdownBlock.parse("""
        | A | B | C |
        |---|---|---|
        | 1 |
        | 2 | 3 | 4 |
        """)
        let table = try #require(blocks.first?.table)
        #expect(table.rows.count == 2)
        #expect(table.rows[0].count == 3)
        #expect(String(table.rows[0][0].characters) == "1")
        #expect(table.rows[0].dropFirst().allSatisfy { $0.characters.isEmpty })
        #expect(table.rows[1].map { String($0.characters) } == ["2", "3", "4"])
    }

    // MARK: - Lists followed by paragraphs (#8)

    private func texts(_ blocks: [MarkdownBlock]) -> [String] {
        blocks.map { String($0.content.characters) }
    }

    @Test func paragraphAfterBlankLineLeavesTheList() {
        let blocks = MarkdownBlock.parse("- one\n- two\n\nAfter the list.\n\nSecond paragraph.")
        #expect(texts(blocks) == ["one", "two", "After the list.", "Second paragraph."])
        #expect(blocks.map(\.listDepth) == [1, 1, 0, 0])
        let ordered = MarkdownBlock.parse("1. one\n2. two\n\nAfter")
        #expect(texts(ordered) == ["one", "two", "After"])
        #expect(ordered.map(\.listDepth) == [1, 1, 0])
        let crlf = MarkdownBlock.parse("- one\r\n- two\r\n\r\nAfter")
        #expect(texts(crlf) == ["one", "two", "After"])
        #expect(crlf.map(\.listDepth) == [1, 1, 0])
    }

    /// CommonMark lazy continuation: an unindented line right after an item
    /// (no blank line) continues that item's paragraph. This is standard
    /// behavior (GitHub renders it the same way), not issue #8.
    @Test func lazyContinuationLineStaysInLastItem() {
        let blocks = MarkdownBlock.parse("- one\n- two\nlazy line\n\nAfter")
        #expect(texts(blocks) == ["one", "two lazy line", "After"])
        #expect(blocks.map(\.listDepth) == [1, 1, 0])
        #expect(blocks.map(\.showsListMarker) == [true, true, true])
        let nested = MarkdownBlock.parse("- outer\n  - inner\nlazy")
        #expect(texts(nested) == ["outer", "inner lazy"])
        #expect(nested.map(\.listDepth) == [1, 2])
    }

    @Test func paragraphIndentedLessThanItemContentLeavesTheList() {
        // "1. " puts item content at column 3: two spaces are not enough.
        let blocks = MarkdownBlock.parse("1. one\n\n  After")
        #expect(texts(blocks) == ["one", "After"])
        #expect(blocks.map(\.listDepth) == [1, 0])
        // At the content column it is a continuation paragraph instead.
        let inside = MarkdownBlock.parse("1. one\n\n   Inside")
        #expect(inside.map(\.listDepth) == [1, 1])
        #expect(inside.map(\.showsListMarker) == [true, false])
    }

    @Test func paragraphAfterNestedListsLeavesEveryLevel() {
        let blocks = MarkdownBlock.parse("- a\n  - b\n    1. c\n\nAfter")
        #expect(texts(blocks) == ["a", "b", "c", "After"])
        #expect(blocks.map(\.listDepth) == [1, 2, 3, 0])
        let quoted = MarkdownBlock.parse("> - a\n>\n> After")
        #expect(texts(quoted) == ["a", "After"])
        #expect(quoted.map(\.listDepth) == [1, 0])
        #expect(quoted.map(\.quoteDepth) == [1, 1])
    }

    @Test func fencedCodeWithListAndTableLookalikesStaysVerbatim() throws {
        let code = "- item\nnot a lazy line\n| A | B |\n|---|---|\n| 1 | 2 | 3 |\n"
        let source = "- real item\n\n```text\n" + code + "```\n\nAfter"
        #expect(MarkdownTableWidening.widen(source) == nil)
        let blocks = MarkdownBlock.parse(source)
        #expect(blocks.count == 3)
        #expect(blocks[0].listDepth == 1)
        let block = try #require(blocks.first { $0.isCodeBlock })
        #expect(String(block.content.characters) == code)
        #expect(block.listDepth == 0)
        #expect(!blocks.contains { $0.table != nil })
        #expect(blocks.last.map { String($0.content.characters) } == "After")
    }

    // MARK: - Table cells beyond the header (#9)

    @Test func surplusCellsBecomeColumnsWithEmptyHeader() throws {
        let blocks = MarkdownBlock.parse("""
        | A | B |
        |---|---|
        | 1 | 2 | 3 | 4 |
        | 5 | 6 |
        """)
        #expect(blocks.count == 1)
        let table = try #require(blocks.first?.table)
        #expect(table.columns.count == 4)
        #expect(table.header.map { String($0.characters) } == ["A", "B", "", ""])
        #expect(table.rows.map { $0.map { String($0.characters) } }
            == [["1", "2", "3", "4"], ["5", "6", "", ""]])
    }

    @Test func surplusAndMissingCellsInTheSameTable() throws {
        let blocks = MarkdownBlock.parse("""
        | A | B | C |
        |:--|:-:|--:|
        | 1 |
        | 2 | 3 | 4 | 5 |
        """)
        let table = try #require(blocks.first?.table)
        #expect(table.header.map { String($0.characters) } == ["A", "B", "C", ""])
        #expect(table.rows.map { $0.map { String($0.characters) } }
            == [["1", "", "", ""], ["2", "3", "4", "5"]])
        // Declared alignments survive; the added column uses the default.
        #expect(table.columns.prefix(3).map { String(describing: $0.alignment) }
            == ["left", "center", "right"])
    }

    @Test func surplusCellsWithoutBorderPipesAndWithCRLF() throws {
        let blocks = MarkdownBlock.parse("A | B\r\n--- | ---\r\n1 | 2 | 3\r\n\r\nAfter\r\n")
        let table = try #require(blocks.first?.table)
        #expect(table.header.map { String($0.characters) } == ["A", "B", ""])
        #expect(table.rows.map { $0.map { String($0.characters) } } == [["1", "2", "3"]])
        #expect(blocks.last.map { String($0.content.characters) } == "After")
    }

    @Test func escapedPipeIsNotACellBoundary() throws {
        let blocks = MarkdownBlock.parse("""
        | A | B |
        |---|---|
        | a \\| b | c | d |
        """)
        let table = try #require(blocks.first?.table)
        #expect(table.rows.map { $0.map { String($0.characters) } } == [["a | b", "c", "d"]])
        #expect(table.header.count == 3)
    }

    @Test func surplusCellsInQuotedAndListedTables() throws {
        let quoted = MarkdownBlock.parse("> | A |\n> |---|\n> | 1 | 2 |")
        let quotedTable = try #require(quoted.first?.table)
        #expect(quotedTable.rows.map { $0.map { String($0.characters) } } == [["1", "2"]])
        let listed = MarkdownBlock.parse("- item\n\n  | A |\n  |---|\n  | 1 | 2 |")
        let listedTable = try #require(listed.compactMap(\.table).first)
        #expect(listedTable.header.map { String($0.characters) } == ["A", ""])
        #expect(listedTable.rows.map { $0.map { String($0.characters) } } == [["1", "2"]])
    }

    @Test func indentedCodeLookingLikeATableIsNeverRewritten() throws {
        let source = "Intro\n\n    | A |\n    |---|\n    | 1 | 2 |\n"
        // The line scanner proposes a rewrite, but the parse check rejects
        // it because the code block text would change.
        #expect(MarkdownTableWidening.widen(source) != nil)
        let blocks = MarkdownBlock.parse(source)
        let code = try #require(blocks.first { $0.isCodeBlock })
        #expect(String(code.content.characters) == "| A |\n|---|\n| 1 | 2 |\n")
        #expect(!blocks.contains { $0.table != nil })
    }

    @Test func wideningOnlyTouchesHeaderAndDelimiterRows() throws {
        let source = "| A | B |\n|---|---|\n| 1 | 2 | 3 |\n\nText | with | pipes\n"
        let widened = try #require(MarkdownTableWidening.widen(source))
        #expect(widened == "| A | B | |\n|---|---| --- |\n| 1 | 2 | 3 |\n\nText | with | pipes\n")
        #expect(MarkdownTableWidening.widen("| A | B |\n|---|---|\n| 1 | 2 |\n| 3 |") == nil)
    }

    // MARK: - Second delivery: task lists

    @Test func taskItemsExposeStateAndStripMarker() {
        let blocks = MarkdownBlock.parse("- [ ] unchecked item\n- [x] checked item\n- plain item")
        #expect(blocks.count == 3)
        #expect(blocks.map(\.taskState) == [.unchecked, .checked, nil])
        #expect(blocks.map(\.listDepth) == [1, 1, 1])
        #expect(blocks.map { String($0.content.characters) }
            == ["unchecked item", "checked item", "plain item"])
    }

    @Test func taskMarkerRequiresBracketSpaceAndFirstParagraph() {
        // "- [ ]no-space" is literal text in GFM, not a task.
        let literal = MarkdownBlock.parse("- [ ]no-space")
        #expect(literal.first?.taskState == nil)
        #expect(String(literal.first.map { String($0.content.characters) } ?? "").hasPrefix("[ ]"))
        // A continuation paragraph's "[ ]" is not a checkbox either.
        let blocks = MarkdownBlock.parse("- [x] first\n\n  [ ] continuation\n\n- [ ] second")
        #expect(blocks.map(\.taskState) == [.checked, nil, .unchecked])
        #expect(String(blocks[1].content.characters).hasPrefix("[ ] continuation"))
    }

    @Test func orderedTaskItemKeepsListContext() {
        let blocks = MarkdownBlock.parse("1. [x] done")
        #expect(blocks.count == 1)
        #expect(blocks[0].taskState == .checked)
        #expect(blocks[0].isOrderedListItem)
        #expect(String(blocks[0].content.characters) == "done")
    }

    // MARK: - Second delivery: YAML frontmatter

    @Test func frontmatterBecomesMetadataCard() throws {
        let blocks = MarkdownBlock.parse("""
        ---
        name: fixture-doc
        description: hello world
        allowed-tools: [Bash, Read]
        nested:
          flag: true
        ---

        # Heading

        Body.
        """)
        let card = try #require(blocks.first?.frontmatter)
        #expect(card.issue == nil)
        #expect(card.entries.map { $0.key } == ["name", "description", "allowed-tools", "nested"])
        #expect(card.entries.first { $0.key == "name" }?.value == "fixture-doc")
        #expect(card.entries.first { $0.key == "allowed-tools" }?.value == "[Bash, Read]")
        #expect(card.entries.first { $0.key == "nested" }?.value == "{flag: true}")
        // The fences must not leak into the body as rule/heading blocks.
        #expect(!blocks.contains { $0.isThematicBreak })
        #expect(blocks.filter { $0.headerLevel != nil }.map { String($0.content.characters) } == ["Heading"])
        #expect(String(blocks.last.map { String($0.content.characters) } ?? "").contains("Body."))
    }

    @Test func frontmatterClosedByDotsAndCRLF() throws {
        let blocks = MarkdownBlock.parse("---\r\nname: dots\r\n...\r\n\r\nBody\r\n")
        let card = try #require(blocks.first?.frontmatter)
        #expect(card.issue == nil)
        #expect(card.entries.first?.key == "name")
        #expect(String(blocks.last.map { String($0.content.characters) } ?? "").contains("Body"))
    }

    @Test func invalidFrontmatterShowsIssueCard() throws {
        let blocks = MarkdownBlock.parse("---\n[unclosed\n---\n\nBody text\n")
        let card = try #require(blocks.first?.frontmatter)
        #expect(card.issue != nil)
        #expect(card.entries.isEmpty)
        #expect(!blocks.contains { $0.isThematicBreak })
        #expect(String(blocks.last.map { String($0.content.characters) } ?? "").contains("Body text"))
    }

    @Test func frontmatterOnlyAppliesAtDocumentStart() {
        // `---` mid-document keeps the existing rule/heading behavior.
        let blocks = MarkdownBlock.parse("# Doc\n\n---\nnot: at start\n---\n\nmore\n")
        #expect(blocks.allSatisfy { $0.frontmatter == nil })
        #expect(blocks.first?.headerLevel == 1)
        // No closing fence at all: the `---` stays a thematic break.
        let unclosed = MarkdownBlock.parse("---\nname: x\n\nmore\n")
        #expect(unclosed.allSatisfy { $0.frontmatter == nil })
        #expect(unclosed.contains { $0.isThematicBreak })
    }

    // MARK: - Second delivery: TOC ids & copy payload

    @Test func allBlockIDsUniqueWithMixedSecondDeliveryContent() {
        let blocks = MarkdownBlock.parse("""
        ---
        name: x
        ---

        # Top

        | A | B |
        |---|---|
        | 1 | 2 |

        - [ ] task

        ## Bottom
        """)
        #expect(Set(blocks.map(\.id)).count == blocks.count)
        // TOC is fed by headerLevel: table/frontmatter/task blocks stay out.
        let toc = blocks.filter { $0.headerLevel != nil }
        #expect(toc.map { String($0.content.characters) } == ["Top", "Bottom"])
    }

    @Test func copyPayloadIsExactCodeBlockText() throws {
        let blocks = MarkdownBlock.parse("```swift\nlet x = 1\nlet y = 2\n```\n")
        let code = try #require(blocks.first { $0.isCodeBlock })
        // This exact string is what the Copy button writes to the pasteboard.
        #expect(String(code.content.characters) == "let x = 1\nlet y = 2\n")
    }

    // MARK: - Second delivery: isolated render check

    /// Offscreen NSHostingView render in light + dark — never launches the app.
    /// PNGs land in /tmp as durable evidence; the assertion only requires the
    /// surface to paint more than a single flat color.
    @Test @MainActor func previewRendersInLightAndDark() throws {
        let headingOnly = "# Heading"
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let hosting = NSHostingView(rootView: MarkdownPreview(text: headingOnly))
            hosting.appearance = NSAppearance(named: appearance)
            hosting.frame = NSRect(x: 0, y: 0, width: 760, height: 400)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            // The heading must contrast with the page: light text in dark
            // mode, dark text in light mode — a `presentationIntent`-derived
            // color would silently render dark-on-dark here. colorAt() y is
            // top-down: skip the top ~60pt (120px at 2x) toolbar band so only
            // the heading counts.
            var maxChannel = 0.0
            var minChannel = 1.0
            for x in stride(from: 40, to: bitmap.pixelsWide - 40, by: 4) {
                for y in stride(from: 120, to: bitmap.pixelsHigh - 20, by: 2) {
                    if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.5 {
                        maxChannel = max(maxChannel, color.redComponent)
                        minChannel = min(minChannel, color.redComponent)
                    }
                }
            }
            if appearance == .darkAqua {
                #expect(maxChannel > 0.5, "heading rendered dark-on-dark in darkAqua")
            } else {
                #expect(minChannel < 0.5, "heading rendered light-on-light in aqua")
            }
        }

        let doc = """
        ---
        name: fixture-doc
        tags: [one, two]
        ---

        # Title

        - [ ] pending
        - [x] done

        | Key | Val |
        |----:|-----|
        | a   | 1   |

        ```text
        FAKE-CODE
        ```
        """
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let hosting = NSHostingView(rootView: MarkdownPreview(text: doc))
            hosting.appearance = NSAppearance(named: appearance)
            hosting.frame = NSRect(x: 0, y: 0, width: 760, height: 900)
            hosting.layoutSubtreeIfNeeded()
            // Let the onChange(initial:) parse commit before rasterizing.
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            var colors = Set<NSColor>()
            for x in stride(from: 20, to: 740, by: 60) {
                for y in stride(from: 20, to: 880, by: 60) {
                    if let color = bitmap.colorAt(x: x, y: y) { colors.insert(color) }
                }
            }
            #expect(colors.count > 1, "preview painted a flat surface in \(appearance.rawValue)")
            let name = appearance == .aqua ? "markdown2-light" : "markdown2-dark"
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
            }
        }
    }
}
}
