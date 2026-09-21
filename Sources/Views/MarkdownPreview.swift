import SwiftUI
import AppKit
import Yams

/// Rendered markdown for instruction files (CLAUDE.md, AGENTS.md…). Parses
/// full block structure (headings, lists, block quotes, code blocks, rules,
/// GFM tables) via `PresentationIntent`, not just inline emphasis — plain
/// `Text` doesn't style intents on its own, so each block is walked and
/// styled by hand. GFM task lists and YAML frontmatter have no intent
/// representation, so they are handled before/after the intent pass.
struct MarkdownPreview: View {
    let text: String
    var fileExists: Bool = true
    var editSource: () -> Void = {}

    @State private var blocks: [MarkdownBlock] = []
    @State private var renderedText: String?

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack {
                    Menu {
                        ForEach(blocks.filter { $0.headerLevel != nil }) { block in
                            Button(String(repeating: "  ", count: max(0, (block.headerLevel ?? 1) - 1))
                                   + String(block.content.characters)) {
                                withAnimation { proxy.scrollTo(block.id, anchor: .top) }
                            }
                            .accessibilityIdentifier("markdown-toc-\(block.id)")
                        }
                    } label: {
                        Label(L("Contents"), systemImage: "list.bullet.indent")
                    }
                    .disabled(renderedText != text || !blocks.contains { $0.headerLevel != nil })
                    .accessibilityIdentifier("markdown-contents")
                    Spacer()
                    Button(action: editSource) {
                        Label(L("Edit in Source"), systemImage: "square.and.pencil")
                    }
                    .accessibilityIdentifier("markdown-edit-source")
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Card {
                                Label(fileExists ? L("Empty file — edit it in the Source tab.")
                                                 : L("This file doesn't exist on disk yet."),
                                      systemImage: fileExists ? "doc" : "doc.badge.ellipsis")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        } else if renderedText == text {
                            ForEach(blocks) { block in
                                MarkdownBlockView(block: block).id(block.id)
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 800, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onChange(of: text, initial: true) { _, value in
            blocks = MarkdownBlock.parse(value)
            renderedText = value
        }
    }
}

/// A GFM table: header + body rows of inline-styled cells, plus the declared
/// column alignments. Cells missing from a row come back empty.
struct MarkdownTable {
    var columns: [PresentationIntent.TableColumn]
    var header: [AttributedString]
    var rows: [[AttributedString]]
}

/// Document-level YAML frontmatter shown as a compact card. `issue` holds an
/// English source string (localized at display time) when the block exists
/// but its payload could not be decoded.
struct MarkdownFrontmatter {
    var entries: [(key: String, value: String)]
    var issue: String?
}

/// One markdown block (paragraph, heading, list item, quote, code, rule,
/// table, frontmatter…), with its `PresentationIntent` kinds (self +
/// ancestors, e.g. a list item nested two levels deep carries both
/// `.listItem` and both enclosing `.unorderedList`/`.orderedList` kinds).
struct MarkdownBlock: Identifiable {
    enum TaskState: Equatable { case unchecked, checked }

    var id: Int
    let kinds: [PresentationIntent.Kind]
    var listItemID: Int? = nil
    var showsListMarker = true
    var taskState: TaskState? = nil
    var table: MarkdownTable? = nil
    var frontmatter: MarkdownFrontmatter? = nil
    /// Identity of the `.table` intent component — distinct per table, so
    /// adjacent tables never merge. Only meaningful on raw cell blocks.
    var tableID: Int? = nil
    var content: AttributedString

    var headerLevel: Int? {
        for k in kinds { if case .header(let level) = k { return level } }
        return nil
    }
    var isCodeBlock: Bool {
        kinds.contains { if case .codeBlock = $0 { return true }; return false }
    }
    var isBlockQuote: Bool {
        kinds.contains { if case .blockQuote = $0 { return true }; return false }
    }
    var isThematicBreak: Bool {
        kinds.contains { if case .thematicBreak = $0 { return true }; return false }
    }
    var listDepth: Int {
        kinds.filter {
            if case .unorderedList = $0 { return true }
            if case .orderedList = $0 { return true }
            return false
        }.count
    }
    var listOrdinal: Int? {
        for k in kinds { if case .listItem(let ordinal) = k { return ordinal } }
        return nil
    }
    var isOrderedListItem: Bool {
        for kind in kinds {
            if case .orderedList = kind { return true }
            if case .unorderedList = kind { return false }
        }
        return false
    }
    var quoteDepth: Int {
        kinds.filter { if case .blockQuote = $0 { return true }; return false }.count
    }
    var codeLanguage: String? {
        for kind in kinds { if case .codeBlock(let language) = kind { return language } }
        return nil
    }
    var tableCellColumn: Int? {
        for kind in kinds { if case .tableCell(let column) = kind { return column } }
        return nil
    }
    /// Body-row index; nil for header cells and non-table blocks.
    var tableRowIndex: Int? {
        for kind in kinds { if case .tableRow(let row) = kind { return row } }
        return nil
    }
    var isTableHeaderRow: Bool {
        kinds.contains { if case .tableHeaderRow = $0 { return true }; return false }
    }
    var tableColumns: [PresentationIntent.TableColumn] {
        for kind in kinds { if case .table(let columns) = kind { return columns } }
        return []
    }

    /// Splits a full parse into blocks: runs sharing the same (Equatable)
    /// `presentationIntent` — including `nil` for plain inline text outside
    /// any block — belong to the same block. Frontmatter is extracted before
    /// parsing (the intent parser would otherwise show the `---` fences as a
    /// stray rule + heading), and table cell blocks merge afterwards.
    static func parse(_ text: String) -> [MarkdownBlock] {
        let (metadata, body) = splitFrontmatter(text)
        guard let attributed = try? AttributedString(markdown: body, options: .init(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )) else {
            var blocks: [MarkdownBlock] = []
            if let metadata {
                blocks.append(MarkdownBlock(id: 0, kinds: [], frontmatter: metadata,
                                            content: AttributedString()))
            }
            blocks.append(MarkdownBlock(id: blocks.count, kinds: [],
                                        content: AttributedString(body)))
            return blocks
        }
        var result: [MarkdownBlock] = []
        var currentIntent: PresentationIntent??  // double optional: "not started yet" vs "no intent"
        var currentSlice = AttributedString()
        func flush(_ intent: PresentationIntent?) {
            let listID = intent?.components.first(where: {
                if case .listItem = $0.kind { return true }; return false
            })?.identity
            let tableID = intent?.components.first(where: {
                if case .table = $0.kind { return true }; return false
            })?.identity
            result.append(MarkdownBlock(id: result.count,
                                        kinds: intent?.components.map(\.kind) ?? [],
                                        listItemID: listID,
                                        tableID: tableID,
                                        content: currentSlice))
            currentSlice = AttributedString()
        }
        for run in attributed.runs {
            let intent = run.presentationIntent
            if let started = currentIntent, started != intent { flush(started) }
            currentIntent = intent
            currentSlice += attributed[run.range]
        }
        if let started = currentIntent { flush(started) }
        var seenItems = Set<Int>()
        for index in result.indices {
            if let identity = result[index].listItemID {
                result[index].showsListMarker = seenItems.insert(identity).inserted
            }
        }
        for index in result.indices where result[index].showsListMarker && result[index].listDepth > 0 {
            stripTaskMarker(&result[index])
        }
        var merged = mergeTables(result)
        if let metadata {
            merged.insert(MarkdownBlock(id: -1, kinds: [], frontmatter: metadata,
                                        content: AttributedString()), at: 0)
        }
        for index in merged.indices { merged[index].id = index }
        return merged
    }

    /// YAML frontmatter only counts at the very top of the document: first
    /// line `---`, closed by a later `---`/`...` line (same delimiters as
    /// `Frontmatter.parse`). Anything else stays in the body untouched.
    private static func splitFrontmatter(_ text: String) -> (MarkdownFrontmatter?, String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---",
              let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." })
        else { return (nil, text) }
        let yaml = lines[1..<end].joined(separator: "\n")
        let body = lines.dropFirst(end + 1).joined(separator: "\n")
        if yaml.utf8.count > 65_536 {
            return (MarkdownFrontmatter(entries: [], issue: "Frontmatter exceeds 64 KiB."), body)
        }
        return (MarkdownFrontmatter(yaml: yaml), body)
    }

    /// GFM task items (`- [ ]`, `- [x]`) have no intent kind: the marker
    /// arrives as literal text. Only the first paragraph block of a list
    /// item may carry it — a `[ ]` later in the item stays literal text.
    private static func stripTaskMarker(_ block: inout MarkdownBlock) {
        let chars = block.content.characters
        guard chars.count >= 3, chars[chars.startIndex] == "[" else { return }
        let second = chars.index(after: chars.startIndex)
        let state: TaskState
        switch chars[second] {
        case " ": state = .unchecked
        case "x", "X": state = .checked
        default: return
        }
        let third = chars.index(after: second)
        guard chars[third] == "]" else { return }
        var drop = 3
        if chars.count > 3 {
            let fourth = chars.index(after: third)
            guard chars[fourth] == " " else { return }
            drop = 4
        }
        block.taskState = state
        let cut = chars.index(chars.startIndex, offsetBy: drop)
        block.content = AttributedString(block.content[cut..<block.content.endIndex])
    }

    /// The intent parser emits one block per table cell; merge the run of
    /// blocks sharing a `.table` component identity into a single block
    /// carrying rows/columns/alignments. Sparse rows and missing cells are
    /// padded empty; cells beyond the column count are already dropped by
    /// the parser.
    private static func mergeTables(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
        var merged: [MarkdownBlock] = []
        var index = 0
        while index < blocks.count {
            guard let tableID = blocks[index].tableID else {
                merged.append(blocks[index]); index += 1; continue
            }
            var cells: [MarkdownBlock] = []
            var columns = blocks[index].tableColumns
            while index < blocks.count, blocks[index].tableID == tableID {
                if blocks[index].tableColumns.count > columns.count {
                    columns = blocks[index].tableColumns
                }
                cells.append(blocks[index]); index += 1
            }
            let columnCount = max(columns.count,
                                  (cells.compactMap(\.tableCellColumn).max() ?? -1) + 1)
            var header = [AttributedString](repeating: "", count: columnCount)
            var rows: [Int: [AttributedString]] = [:]
            for cell in cells {
                guard let column = cell.tableCellColumn, column < columnCount else { continue }
                if cell.isTableHeaderRow {
                    header[column] = cell.content
                } else if let row = cell.tableRowIndex {
                    var line = rows[row] ?? [AttributedString](repeating: "", count: columnCount)
                    line[column] = cell.content
                    rows[row] = line
                }
            }
            merged.append(MarkdownBlock(
                id: merged.count, kinds: [],
                table: MarkdownTable(columns: columns,
                                     header: header,
                                     rows: rows.keys.sorted().compactMap { rows[$0] }),
                content: AttributedString()))
        }
        return merged
    }
}

/// Any YAML value under a frontmatter key, decoded just deeply enough to
/// print a one-line summary. Order matches the document.
private indirect enum MarkdownValue: Decodable {
    case scalar(String)
    case list([MarkdownValue])
    case mapping([(String, MarkdownValue)])
    case unsupported

    // file-private in effect: the enum itself is private to this file
    struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: DynamicKey.self), !keyed.allKeys.isEmpty {
            self = .mapping(keyed.allKeys.map {
                ($0.stringValue, (try? keyed.decode(MarkdownValue.self, forKey: $0)) ?? .unsupported)
            })
            return
        }
        if var unkeyed = try? decoder.unkeyedContainer() {
            var items: [MarkdownValue] = []
            while !unkeyed.isAtEnd {
                items.append((try? unkeyed.decode(MarkdownValue.self)) ?? .unsupported)
            }
            self = .list(items)
            return
        }
        let single = try decoder.singleValueContainer()
        if let bool = try? single.decode(Bool.self) { self = .scalar(bool ? "true" : "false"); return }
        if let int = try? single.decode(Int.self) { self = .scalar(String(int)); return }
        if let double = try? single.decode(Double.self) { self = .scalar(String(double)); return }
        if let string = try? single.decode(String.self) { self = .scalar(string); return }
        self = .unsupported
    }

    /// One-line rendering: `scalar`, `[a, b]` for lists, `{k: v}` for maps,
    /// `—` for anything undecodable. Nested content is capped per element.
    var description: String {
        switch self {
        case .scalar(let string): return string
        case .list(let items): return "[" + items.map(\.short).joined(separator: ", ") + "]"
        case .mapping(let pairs):
            return "{" + pairs.map { "\($0.0): \($0.1.short)" }.joined(separator: ", ") + "}"
        case .unsupported: return "—"
        }
    }
    private var short: String {
        let text = description
        return text.count > 60 ? String(text.prefix(59)) + "…" : text
    }
}

private extension MarkdownFrontmatter {
    /// Decodes the YAML block as a flat key→summary list. A top-level scalar
    /// or sequence is still valid YAML but not displayable as rows, so it
    /// reports an issue instead of pretending to be a mapping.
    init(yaml: String) {
        struct TopMap: Decodable {
            var pairs: [(String, MarkdownValue)]
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: MarkdownValue.DynamicKey.self)
                pairs = container.allKeys.map {
                    ($0.stringValue, (try? container.decode(MarkdownValue.self, forKey: $0)) ?? .unsupported)
                }
            }
        }
        if yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entries = []; issue = "Empty frontmatter."
            return
        }
        do {
            let top = try YAMLDecoder().decode(TopMap.self, from: yaml)
            entries = top.pairs.map { ($0.0, $0.1.description) }
            issue = entries.isEmpty ? "Empty frontmatter." : nil
        } catch {
            entries = []; issue = "Invalid YAML frontmatter."
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    @State private var wrapCode = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(0..<block.quoteDepth, id: \.self) { _ in
                Rectangle().fill(.tertiary).frame(width: 3)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if block.listDepth > 0 {
                    marker
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 20, alignment: .trailing)
                }
                blockContent.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(max(0, block.listDepth - 1)) * 20)
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .padding(.vertical, block.listDepth > 0 ? 3 : 7)
    }

    @ViewBuilder private var marker: some View {
        if let state = block.taskState {
            Image(systemName: state == .checked ? "checkmark.square.fill" : "square")
                .accessibilityLabel(state == .checked ? L("Completed task") : L("Pending task"))
        } else {
            Text(block.showsListMarker ? (block.isOrderedListItem ? "\(block.listOrdinal ?? 1)." : "•") : "")
        }
    }

    @ViewBuilder private var blockContent: some View {
        if let metadata = block.frontmatter {
            frontmatterCard(metadata)
        } else if let table = block.table {
            tableCard(table)
        } else if block.isThematicBreak {
            Rectangle().fill(.quaternary).frame(height: 1).padding(.vertical, 8)
        } else if block.isCodeBlock {
            codeBlock
        } else if let level = block.headerLevel {
            Text(block.content)
                .font(.system(size: level == 1 ? 28 : level == 2 ? 22 : level == 3 ? 18 : 15,
                              weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.top, level <= 2 ? 18 : 10)
                .padding(.bottom, 5)
                .accessibilityAddTraits(.isHeader)
        } else {
            Text(block.content)
                .font(.system(size: 15))
                .lineSpacing(5)
                .foregroundStyle(block.isBlockQuote ? .secondary : .primary)
        }
    }

    private var codeBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(block.codeLanguage?.isEmpty == false ? block.codeLanguage! : L("Code"))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Toggle(isOn: $wrapCode) {
                    Label(L("Wrap lines"), systemImage: "arrow.turn.down.left")
                }
                .toggleStyle(.button).labelStyle(.iconOnly)
                .help(L("Wrap lines"))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(block.content.characters), forType: .string)
                } label: {
                    Label(L("Copy code"), systemImage: "doc.on.doc")
                }
                .labelStyle(.iconOnly).help(L("Copy code"))
                .accessibilityIdentifier("markdown-copy-code-\(block.id)")
            }
            .textSelection(.disabled)
            .padding(10)
            Divider()
            if wrapCode {
                codeText.fixedSize(horizontal: false, vertical: true).padding(12)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    codeText.fixedSize(horizontal: true, vertical: false).padding(12)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 0.5))
    }

    private var codeText: some View {
        Text(block.content).font(.system(size: 13, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Compact card replacing the raw `---` fences: key rows plus an issue
    /// line when the YAML could not be decoded.
    private func frontmatterCard(_ metadata: MarkdownFrontmatter) -> some View {
        Card {
            CardHeader(title: L("Metadata"), icon: "info.circle")
            if !metadata.entries.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                    ForEach(Array(metadata.entries.prefix(8).enumerated()), id: \.offset) { _, entry in
                        GridRow {
                            Text(entry.key)
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(minWidth: 80, alignment: .trailing)
                            Text(entry.value)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if metadata.entries.count > 8 {
                    Text(L("+%d more keys", metadata.entries.count - 8))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let issue = metadata.issue {
                Label(L(issue), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
    }

    /// GFM table: bordered card, bold header row, declared column alignments.
    /// Wide tables scroll horizontally like code blocks instead of clipping.
    private func tableCard(_ table: MarkdownTable) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                        tableCell(cell, column: column, table: table, header: true)
                    }
                }
                Divider()
                ForEach(Array(table.rows.enumerated()), id: \.offset) { row, cells in
                    GridRow {
                        ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                            tableCell(cell, column: column, table: table, header: false)
                        }
                    }
                    if row != table.rows.count - 1 { Divider() }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(4)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 0.5))
    }

    private func tableCell(_ cell: AttributedString, column: Int,
                           table: MarkdownTable, header: Bool) -> some View {
        Text(cell)
            .font(.system(size: 13, weight: header ? .semibold : .regular))
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: alignment(of: column, in: table))
            .padding(.horizontal, 12).padding(.vertical, header ? 7 : 6)
    }

    private func alignment(of column: Int, in table: MarkdownTable) -> Alignment {
        guard column < table.columns.count else { return .leading }
        switch table.columns[column].alignment {
        case .right: return .trailing
        case .center: return .center
        default: return .leading
        }
    }
}
