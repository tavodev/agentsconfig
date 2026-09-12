import SwiftUI

enum EditorTab: String, CaseIterable {
    case structured = "Structured"
    case source = "Source"
    case history = "History"
}

struct EditorView: View {
    @AppStorage("maskSecrets", store: AppSettings.defaults) private var maskSecrets = true
    @Environment(ConfigStore.self) private var store
    @State private var tab: EditorTab = .structured
    @State private var showDiff = false
    @State private var showAddMcp = false

    private var path: String? { store.selectedPath }

    var body: some View {
        @Bindable var store = store
        if let path {
            VStack(spacing: 0) {
                header(path: path)
                Divider()
                banners(path: path)
                content(path: path)
                    .id(path)
                Divider()
                footer(path: path)
            }
            .navigationTitle(windowTitle)
            .onChange(of: store.requestedTab) { _, t in
                if let t { tab = t; store.requestedTab = nil }
            }
            .onChange(of: store.selectedPath) { _, newPath in
                showAddMcp = false
                // formats with nothing to inspect → land directly on Source
                if let p = newPath {
                    let f = store.format(for: p)
                    if f != .json && f != .jsonc && f != .toml && f != .markdown
                        && tab == .structured {
                        tab = .source
                    }
                }
            }
            .inspector(isPresented: $store.showInspector) {
                FileInspectorView(path: path)
            }
            .sheet(isPresented: $showDiff) {
                if let change = store.externalChanges[path] {
                    DiffSheet(path: path, change: change)
                }
            }
        } else {
            ContentUnavailableView(
                L("Select a file"),
                systemImage: "doc.text.magnifyingglass",
                description: Text(L("Pick an agent and a config file to inspect it."))
            )
        }
    }

    private var windowTitle: String {
        guard let path else { return "AgentsConfig" }
        return "\(URL(fileURLWithPath: path).lastPathComponent) — AgentsConfig"
    }

    // MARK: header

    private func header(path: String) -> some View {
        HStack(spacing: 10) {
            let file = fileInfo(path)
            Image(systemName: file?.role.icon ?? "doc")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.system(size: 14, weight: .semibold))
                    if let file {
                        Text(file.format.badge)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(file.format.badgeColor.opacity(0.15))
                            .foregroundStyle(file.format.badgeColor)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    if let fd = DocsCatalog.fileDoc(for: path) {
                        FileDocButton(doc: fd)
                    }
                }
                HStack(spacing: 6) {
                    Text(path.replacingOccurrences(of: AppPaths.home, with: "~"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let note = file?.note {
                        Text("· \(L(note))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            Button { store.revealInFinder(path) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("Show in Finder"))
            if store.isMcpDestination(path) {
                Button(L("Add MCP server")) { showAddMcp = true }
                    .accessibilityIdentifier("add-mcp")
                    .controlSize(.small)
                    .popover(isPresented: $showAddMcp) {
                        McpAddForm(path: path) { showAddMcp = false }
                    }
            }
            metaLabels(path: path)
            Picker("", selection: $tab) {
                ForEach(EditorTab.allCases, id: \.self) { t in
                    Text(L(t.rawValue)).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func fileInfo(_ path: String) -> TrackedFile? {
        for agent in store.agents {
            if let f = agent.files.first(where: { $0.path == path }) { return f }
        }
        return nil
    }

    @ViewBuilder
    private func metaLabels(path: String) -> some View {
        if let f = fileInfo(path) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))
                    .font(.caption2).foregroundStyle(.secondary)
                if let m = f.mtime {
                    Text(m, style: .relative)
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: banners

    @ViewBuilder
    private func banners(path: String) -> some View {
        if store.conflicts.contains(path) {
            ConflictBanner(
                deleted: store.externalChanges[path]?.isDeletion ?? false,
                onKeepMine: { store.requestSave(path: path, overwrite: true) },
                onTakeDisk: { store.resolveConflictUseDisk(path: path) }
            )
        } else if let change = store.externalChanges[path] {
            ExternalBanner(
                change: change,
                volatile: fileInfo(path)?.volatile ?? false,
                onDiff: { showDiff = true },
                onRevert: { store.requestRevertExternal(path) },
                onDismiss: { store.acknowledgeExternal(path: path) }
            )
        }
        if let file = fileInfo(path), !file.managedBlocks.isEmpty {
            ManagedBanner(blocks: file.managedBlocks)
        }
    }

    // MARK: content

    @ViewBuilder
    private func content(path: String) -> some View {
        let doc = store.document(for: path)
        let format = store.format(for: path)
        if store.loadingPaths.contains(path) && doc == nil {
            ProgressView(L("Loading and validating file…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
        switch tab {
        case .structured:
            if store.usesBackgroundProcessing(path) {
                VStack(spacing: 12) {
                    Text(L("Large files use Source editing. Validation and saving run in the background; structured inspection and MCP indexing are omitted."))
                        .font(.callout).multilineTextAlignment(.center)
                    Button(L("Go to Source")) { tab = .source }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if format == .markdown {
                MarkdownPreview(text: Secrets.maskText(store.text(for: path), format: .markdown, masking: maskSecrets),
                                fileExists: fileInfo(path)?.exists ?? FileManager.default.fileExists(atPath: path))
            } else if format != .json && format != .jsonc && format != .toml {
                NonStructuredHint(format: format) { tab = .source }
            } else {
                StructuredView(path: path, doc: doc, format: format,
                               readOnly: store.isReadOnly(path) || format == .toml)
            }
        case .source:
            if store.usesBackgroundProcessing(path) {
                LargeSourceEditor(path: path, readOnly: store.isReadOnly(path))
            } else if store.isReadOnly(path) {
                // read-only: show masked text — never editable
                CodeEditor(
                    documentID: path,
                    text: .constant(store.usesBackgroundProcessing(path) && maskSecrets
                        ? Secrets.maskedValue : Secrets.maskText(doc?.text ?? "", format: format, masking: maskSecrets)),
                    format: format,
                    readOnly: true,
                    refreshToken: doc.map { $0.hash.hashValue } ?? 0,
                    findToken: store.findRequest
                )
            } else {
                Label(L("Source shows real values, including secrets. Edits are saved exactly as entered."), systemImage: "eye.trianglebadge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange).padding(8)
                CodeEditor(
                    documentID: path,
                    text: Binding(
                        get: { store.text(for: path) },
                        set: { store.updateEdit(path: path, text: $0) }
                    ),
                    format: format,
                    readOnly: store.savingPaths.contains(path),
                    refreshToken: doc.map { $0.hash.hashValue } ?? 0,
                    findToken: store.findRequest
                )
            }
        case .history:
            HistoryView(path: path)
        }
        }
    }

    // MARK: footer

    private func footer(path: String) -> some View {
        HStack(spacing: 12) {
            if store.savingPaths.contains(path) { ProgressView().controlSize(.small) }
            if store.preparingSavePath == path {
                ProgressView(L("Preparing review…")).controlSize(.small)
                Button(L("Cancel")) { store.cancelSaveReview() }
            }
            // errors are shown independently of the dirty flag and can be
            // retried (when there is still something to save) or dismissed
            if let err = store.saveErrors[path] {
                Label(err, systemImage: "exclamationmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                if store.dirtyPaths.contains(path) {
                    Button(L("Retry")) { store.requestSave(path: path) }
                        .controlSize(.small)
                }
                Button(L("Dismiss")) { store.clearSaveError(path: path) }
                    .controlSize(.small)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            if store.dirtyPaths.contains(path) {
                Label(L("Unsaved"), systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button(L("Save")) { store.requestSave(path: path) }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(store.savingPaths.contains(path))
                Button(L("Discard")) { store.discardEdit(path: path) }
                    .controlSize(.small).disabled(store.savingPaths.contains(path))
            } else if store.saveErrors[path] == nil {
                let doc = store.document(for: path)
                if let err = doc?.parseError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if fileInfo(path)?.exists == false {
                    // never claim "in sync" for a file we couldn't read
                    Label(L("Not found on disk"), systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label(L("In sync with disk"), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Spacer()
            if let file = fileInfo(path), !file.issues.isEmpty {
                IssuesButton(issues: file.issues)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - File doc popover

/// ⓘ "¿Qué es este archivo?" — explains purpose + links official docs.
struct FileDocButton: View {
    let doc: DocsCatalog.FileDoc
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(L("What is this file?"))
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(doc.localizedTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(doc.localizedBody)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = doc.docsURL {
                    Link(L("Official docs") + " ↗", destination: url)
                        .font(.caption)
                }
            }
            .padding(14)
            .frame(maxWidth: 380)
        }
    }
}

// MARK: - Structured-tab fallbacks

/// Rendered markdown for instruction files (CLAUDE.md, AGENTS.md…). Parses
/// full block structure (headings, lists, block quotes, code blocks, rules)
/// via `PresentationIntent`, not just inline emphasis — plain `Text` doesn't
/// style intents on its own, so each block is walked and styled by hand.
struct MarkdownPreview: View {
    let text: String
    var fileExists: Bool = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Card {
                        Label(fileExists ? L("Empty file — edit it in the Source tab.")
                                         : L("This file doesn't exist on disk yet."),
                              systemImage: fileExists ? "doc" : "doc.badge.ellipsis")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(MarkdownBlock.parse(text)) { block in
                        MarkdownBlockView(block: block)
                    }
                    Label(L("Rendered preview — edit in the Source tab."),
                          systemImage: "eye")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 10)
                }
            }
            .padding(18)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One markdown block (paragraph, heading, list item, quote, code, rule…),
/// with its `PresentationIntent` kinds (self + ancestors, e.g. a list item
/// nested two levels deep carries both `.listItem` and both enclosing
/// `.unorderedList`/`.orderedList` kinds).
private struct MarkdownBlock: Identifiable {
    let id: Int
    let kinds: [PresentationIntent.Kind]
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
        listOrdinal != nil && kinds.contains { if case .orderedList = $0 { return true }; return false }
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
                result.append(MarkdownBlock(id: result.count, kinds: started?.components.map(\.kind) ?? [], content: currentSlice))
                currentSlice = AttributedString()
            }
            currentIntent = intent
            currentSlice += attributed[run.range]
        }
        if let started = currentIntent {
            result.append(MarkdownBlock(id: result.count, kinds: started?.components.map(\.kind) ?? [], content: currentSlice))
        }
        return result
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        if block.isThematicBreak {
            Divider().padding(.vertical, 8)
        } else if block.isCodeBlock {
            codeBlock
        } else if let level = block.headerLevel {
            heading(level: level)
        } else if block.listDepth > 0 {
            listItem
        } else if block.isBlockQuote {
            blockQuote
        } else {
            paragraph
        }
    }

    private func heading(level: Int) -> some View {
        Text(block.content)
            .font(headingFont(level))
            .padding(.top, level <= 2 ? 16 : 10)
            .padding(.bottom, 4)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 22, weight: .bold)
        case 2: return .system(size: 17, weight: .bold)
        case 3: return .system(size: 15, weight: .semibold)
        default: return .system(size: 13, weight: .semibold)
        }
    }

    private var paragraph: some View {
        Text(block.content)
            .font(.system(size: 13))
            .lineSpacing(4)
            .textSelection(.enabled)
            .padding(.vertical, 3)
    }

    private var listItem: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(block.isOrderedListItem ? "\(block.listOrdinal ?? 1)." : "•")
                .font(.system(size: 13, weight: block.isOrderedListItem ? .regular : .bold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)
            Text(block.content)
                .font(.system(size: 13))
                .lineSpacing(3)
                .textSelection(.enabled)
        }
        .padding(.leading, CGFloat(max(0, block.listDepth - 1)) * 18)
        .padding(.vertical, 2)
    }

    private var blockQuote: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(.tertiary).frame(width: 3)
            Text(block.content)
                .font(.system(size: 13))
                .italic()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    private var codeBlock: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(block.content)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .padding(.vertical, 5)
    }
}

/// Dead-end card for formats without a structured view.
struct NonStructuredHint: View {
    let format: ConfigFormat
    let goToSource: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "doc.plaintext")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(L("No structured view for %@", format.badge))
                .font(.system(size: 14, weight: .semibold))
            Text(L("This format is edited as text."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(L("Go to Source"), action: goToSource)
                .controlSize(.regular)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Banners

struct ExternalBanner: View {
    let change: ExternalChange
    var volatile: Bool
    var onDiff: () -> Void
    var onRevert: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Modified outside the app"))
                    .font(.system(size: 12, weight: .semibold))
                Text("\(L(DiffEngine.summary(change.changes))) · \(change.date, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !change.changes.isEmpty {
                Button(L("View diff"), action: onDiff).controlSize(.small)
            }
            if !volatile, change.previousContent != nil {
                Button(L("Revert"), action: onRevert).controlSize(.small)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.blue.opacity(0.08))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct ConflictBanner: View {
    var deleted = false
    var onKeepMine: () -> Void
    var onTakeDisk: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Edit conflict"))
                    .font(.system(size: 12, weight: .semibold))
                Text(deleted
                     ? L("The file was deleted on disk while you had unsaved edits.")
                     : L("The file changed on disk while you had unsaved edits."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Keep mine"), action: onKeepMine).controlSize(.small)
            Button(L("Use disk version"), action: onTakeDisk).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }
}

struct ManagedBanner: View {
    let blocks: [ManagedBlock]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Managed by a third party"))
                    .font(.system(size: 12, weight: .semibold))
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                    Text("\(b.owner) — \(b.detail)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.purple.opacity(0.07))
    }
}

struct IssuesButton: View {
    let issues: [FileIssue]
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            Label("\(issues.count)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Issues detected")).font(.headline)
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: issue.severity == .error ? "xmark.octagon.fill" :
                                        issue.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .foregroundStyle(issue.severity == .error ? .red :
                                                issue.severity == .warning ? .orange : .blue)
                        Text(issue.message).font(.caption)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: 420)
        }
    }
}
