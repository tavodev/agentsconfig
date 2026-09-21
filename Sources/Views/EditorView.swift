import SwiftUI

enum EditorTab: String, CaseIterable {
    case structured = "Structured"
    case source = "Source"
    case history = "History"
}

struct EditorView: View {
    @AppStorage("maskSecrets", store: AppSettings.defaults) private var maskSecrets = true
    @Environment(ConfigStore.self) private var store
    @AppStorage("editorMode", store: AppSettings.defaults) private var tab: EditorTab = .structured
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $store.showInspector) {
                        Label(L("File information"), systemImage: "sidebar.trailing")
                    }
                    .toggleStyle(.button)
                    .help(L("File information") + " (⌥⌘0)")
                    .accessibilityIdentifier("file-inspector")
                }
            }
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
            .adaptiveInspector(isPresented: $store.showInspector, title: L("File information")) {
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: fileInfo(path)?.role.icon ?? "doc")
                    .font(.title3).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("editor-filename")
                    Text(fileContext(path))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("editor-context")
                }
                Spacer(minLength: 8)
                Menu {
                    Button(L("Show in Finder")) { store.revealInFinder(path) }
                    Button(L("Copy path")) { store.copyPath(path) }
                    Button(L("Open with default app")) { store.openInDefaultApp(path) }
                } label: {
                    Label(L("File actions"), systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .labelStyle(.iconOnly)
                .help(L("File actions"))
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    modePicker
                    Spacer(minLength: 12)
                    mcpAction(path)
                }
                VStack(alignment: .leading, spacing: 8) {
                    modePicker
                    mcpAction(path)
                }
            }
        }
        .padding(16)
    }

    private var modePicker: some View {
        Picker(L("Editor mode"), selection: $tab) {
            ForEach(EditorTab.allCases, id: \.self) { t in
                Text(L(t == .structured && path.map { store.format(for: $0) == .markdown } == true
                       ? "Preview" : t.rawValue)).tag(t)
            }
        }
        .pickerStyle(.segmented).labelsHidden()
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier("editor-mode")
    }

    @ViewBuilder private func mcpAction(_ path: String) -> some View {
        if store.isMcpDestination(path) {
            Button(L("Add MCP server"), systemImage: "plus") { showAddMcp = true }
                .accessibilityIdentifier("add-mcp")
                .popover(isPresented: $showAddMcp, arrowEdge: .trailing) {
                    McpAddForm(path: path) { showAddMcp = false }
                }
        }
    }

    private func fileInfo(_ path: String) -> TrackedFile? {
        store.agents.lazy.flatMap(\.files).first { $0.path == path }
    }

    private func fileContext(_ path: String) -> String {
        // Resolve ownership from the file, never from the sidebar's current filter.
        let owners = store.agents.filter { $0.files.contains { $0.path == path } }
        guard let agent = owners.first else {
            return path.replacingOccurrences(of: AppPaths.home, with: "~")
        }
        let name = owners.map { $0.name.components(separatedBy: " (").first ?? $0.name }.joined(separator: " / ")
        guard let project = agent.projectRoot else { return name + " · " + L("Global") }
        return [name, L("Project") + " " + URL(fileURLWithPath: project).lastPathComponent,
                agent.submodulePath ?? L("Project root")].joined(separator: " · ")
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
                                fileExists: fileInfo(path)?.exists ?? FileManager.default.fileExists(atPath: path),
                                editSource: { tab = .source })
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
                    refreshToken: doc.map { $0.hash.hashValue ^ $0.loadedAt.hashValue } ?? 0,
                    findToken: store.findRequest
                )
            } else {
                Label(L("Source shows real values, including secrets. Edits are saved exactly as entered."), systemImage: "eye.trianglebadge.exclamationmark")
                    .font(.callout).foregroundStyle(.orange).padding(8)
                CodeEditor(
                    documentID: path,
                    text: Binding(
                        get: { store.text(for: path) },
                        set: { store.updateEdit(path: path, text: $0) }
                    ),
                    format: format,
                    readOnly: store.savingPaths.contains(path),
                    refreshToken: doc.map { $0.hash.hashValue ^ $0.loadedAt.hashValue } ?? 0,
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
        VStack(alignment: .leading, spacing: 8) {
            if let err = store.saveErrors[path] {
                Label(err, systemImage: "exclamationmark.octagon.fill")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if store.dirtyPaths.contains(path) {
                        Button(L("Retry")) { store.requestSave(path: path) }
                    }
                    Button(L("Dismiss")) { store.clearSaveError(path: path) }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    fileStatus(path)
                    Spacer(minLength: 12)
                    saveActions(path)
                }
                VStack(alignment: .leading, spacing: 8) {
                    fileStatus(path)
                    saveActions(path)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background { WorkspaceBarBackground() }
    }

    @ViewBuilder private func fileStatus(_ path: String) -> some View {
        Group {
            if store.conflicts.contains(path) {
                Label(L("Conflict with disk"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if store.dirtyPaths.contains(path) {
                Label(L("Unsaved"), systemImage: "circle.fill")
            } else if let error = store.document(for: path)?.parseError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if fileInfo(path)?.exists == false {
                Label(L("Not found on disk"), systemImage: "questionmark.circle")
            } else if store.saveErrors[path] == nil {
                Label(L("In sync with disk"), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .accessibilityIdentifier("editor-status")
    }

    @ViewBuilder private func saveActions(_ path: String) -> some View {
        HStack(spacing: 10) {
            if store.savingPaths.contains(path) { ProgressView().controlSize(.small) }
            if store.preparingSavePath == path {
                ProgressView(L("Preparing review…")).controlSize(.small)
                Button(L("Cancel")) { store.cancelSaveReview() }
            } else if store.dirtyPaths.contains(path) {
                Button(L("Discard")) { store.discardEdit(path: path) }
                    .disabled(store.savingPaths.contains(path))
                Button(L("Review and save…")) { store.requestSave(path: path) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("review-save")
                    .disabled(store.savingPaths.contains(path))
            }
            if let file = fileInfo(path), !file.issues.isEmpty {
                IssuesButton(issues: file.issues)
            }
        }
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
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(L("What is this file?"))
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(doc.localizedTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(doc.localizedBody)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = doc.docsURL {
                    Link(L("Official docs") + " ↗", destination: url)
                        .font(.callout)
                }
            }
            .padding(14)
            .frame(maxWidth: 380)
        }
    }
}

// MARK: - Structured-tab fallbacks

/// Dead-end card for formats without a structured view.
struct NonStructuredHint: View {
    let format: ConfigFormat
    let goToSource: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "doc.plaintext")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(L("No structured view for %@", format.badge))
                .font(.system(size: 14, weight: .semibold))
            Text(L("This format is edited as text."))
                .font(.callout)
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
                    .font(.system(size: 13, weight: .semibold))
                Text("\(L(DiffEngine.summary(change.changes))) · \(change.date, style: .relative)")
                    .font(.callout)
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
                Image(systemName: "xmark").font(.callout)
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
                    .font(.system(size: 13, weight: .semibold))
                Text(deleted
                     ? L("The file was deleted on disk while you had unsaved edits.")
                     : L("The file changed on disk while you had unsaved edits."))
                    .font(.callout)
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
                    .font(.system(size: 13, weight: .semibold))
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                    Text("\(b.owner) — \(b.detail)")
                        .font(.callout)
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
                .font(.callout)
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
                        Text(issue.message).font(.callout)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: 420)
        }
    }
}
