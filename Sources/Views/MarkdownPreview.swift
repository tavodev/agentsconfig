import SwiftUI
import AppKit

/// Rendered markdown for instruction files (CLAUDE.md, AGENTS.md…). Parses
/// full block structure (headings, lists, block quotes, code blocks, rules)
/// via `PresentationIntent`, not just inline emphasis — plain `Text` doesn't
/// style intents on its own, so each block is walked and styled by hand.
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

/// One markdown block (paragraph, heading, list item, quote, code, rule…),
/// with its `PresentationIntent` kinds (self + ancestors, e.g. a list item
/// nested two levels deep carries both `.listItem` and both enclosing
/// `.unorderedList`/`.orderedList` kinds).
struct MarkdownBlock: Identifiable {
    let id: Int
    let kinds: [PresentationIntent.Kind]
    var listItemID: Int? = nil
    var showsListMarker = true
    let content: AttributedString

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


    /// Splits a full parse into blocks: runs sharing the same (Equatable)
    /// `presentationIntent` — including `nil` for plain inline text outside
    /// any block — belong to the same block.
    static func parse(_ text: String) -> [MarkdownBlock] {
        guard let attributed = try? AttributedString(markdown: text, options: .init(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )) else {
            return [MarkdownBlock(id: 0, kinds: [], content: AttributedString(text))]
        }
        var result: [MarkdownBlock] = []
        var currentIntent: PresentationIntent??  // double optional: "not started yet" vs "no intent"
        var currentSlice = AttributedString()
        for run in attributed.runs {
            let intent = run.presentationIntent
            if let started = currentIntent, started != intent {
                result.append(MarkdownBlock(id: result.count, kinds: started?.components.map(\.kind) ?? [], listItemID: started?.components.first(where: { if case .listItem = $0.kind { return true }; return false })?.identity, content: currentSlice))
                currentSlice = AttributedString()
            }
            currentIntent = intent
            currentSlice += attributed[run.range]
        }
        if let started = currentIntent {
            result.append(MarkdownBlock(id: result.count, kinds: started?.components.map(\.kind) ?? [], listItemID: started?.components.first(where: { if case .listItem = $0.kind { return true }; return false })?.identity, content: currentSlice))
        }
        var seenItems = Set<Int>()
        for index in result.indices {
            if let identity = result[index].listItemID {
                result[index].showsListMarker = seenItems.insert(identity).inserted
            }
        }
        return result
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
                    Text(block.showsListMarker ? (block.isOrderedListItem ? "\(block.listOrdinal ?? 1)." : "•") : "")
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

    @ViewBuilder private var blockContent: some View {
        if block.isThematicBreak {
            Rectangle().fill(.quaternary).frame(height: 1).padding(.vertical, 8)
        } else if block.isCodeBlock {
            codeBlock
        } else if let level = block.headerLevel {
            Text(block.content)
                .font(.system(size: level == 1 ? 28 : level == 2 ? 22 : level == 3 ? 18 : 15,
                              weight: .semibold))
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
}
