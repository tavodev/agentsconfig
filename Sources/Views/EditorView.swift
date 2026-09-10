import SwiftUI

enum EditorTab: String, CaseIterable {
    case structured = "Estructurado"
    case source = "Fuente"
    case history = "Historial"
}

struct EditorView: View {
    @Environment(ConfigStore.self) private var store
    @State private var tab: EditorTab = .structured
    @State private var showDiff = false

    private var path: String? { store.selectedPath }

    var body: some View {
        @Bindable var store = store
        if let path {
            VStack(spacing: 0) {
                header(path: path)
                Divider()
                banners(path: path)
                content(path: path)
                Divider()
                footer(path: path)
            }
            .navigationTitle(windowTitle)
            .onChange(of: store.requestedTab) { _, t in
                if let t { tab = t; store.requestedTab = nil }
            }
            .onChange(of: store.selectedPath) { _, newPath in
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
                "Selecciona un archivo",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Elige un agente y un archivo de configuración para inspeccionarlo.")
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
                }
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { store.revealInFinder(path) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Mostrar en Finder")
            metaLabels(path: path)
            Picker("", selection: $tab) {
                ForEach(EditorTab.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
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
                onKeepMine: { store.resolveConflictKeepMine(path: path) },
                onTakeDisk: { store.discardEdit(path: path) }
            )
        } else if let change = store.externalChanges[path] {
            ExternalBanner(
                change: change,
                volatile: fileInfo(path)?.volatile ?? false,
                onDiff: { showDiff = true },
                onRevert: { store.revertExternal(path: path) },
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
        switch tab {
        case .structured:
            if format == .markdown {
                MarkdownPreview(text: store.text(for: path))
            } else if format != .json && format != .jsonc && format != .toml {
                NonStructuredHint(format: format) { tab = .source }
            } else {
                StructuredView(path: path, doc: doc, format: format,
                               readOnly: fileInfo(path)?.readOnly ?? false)
            }
        case .source:
            if fileInfo(path)?.readOnly ?? false {
                // read-only: show masked text — never editable
                CodeEditor(
                    text: .constant(Secrets.maskText(doc?.text ?? "", format: format)),
                    format: format,
                    readOnly: true,
                    refreshToken: doc.map { $0.hash.hashValue } ?? 0,
                    findToken: store.findRequest
                )
            } else {
                CodeEditor(
                    text: Binding(
                        get: { store.text(for: path) },
                        set: { store.updateEdit(path: path, text: $0) }
                    ),
                    format: format,
                    readOnly: false,
                    refreshToken: doc.map { $0.hash.hashValue } ?? 0,
                    findToken: store.findRequest
                )
            }
        case .history:
            HistoryView(path: path)
        }
    }

    // MARK: footer

    private func footer(path: String) -> some View {
        HStack(spacing: 12) {
            if store.dirtyPaths.contains(path) {
                Label("Sin guardar", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Guardar") { store.save(path: path) }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Descartar") { store.discardEdit(path: path) }
                    .controlSize(.small)
            } else if let err = store.saveErrors[path] {
                Label(err, systemImage: "exclamationmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                let doc = store.document(for: path)
                if let err = doc?.parseError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Label("Sincronizado con disco", systemImage: "checkmark.circle.fill")
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

// MARK: - Structured-tab fallbacks

/// Rendered markdown for instruction files (CLAUDE.md, AGENTS.md…).
struct MarkdownPreview: View {
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Card {
                        Label("Archivo vacío — edítalo en la pestaña Fuente.",
                              systemImage: "doc")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(parsingMarkdown())
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: 720, alignment: .leading)
                    Label("Vista previa renderizada — edita en la pestaña Fuente.",
                          systemImage: "eye")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func parsingMarkdown() -> AttributedString {
        (try? AttributedString(markdown: text,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
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
            Text("Sin vista estructurada para \(format.badge)")
                .font(.system(size: 14, weight: .semibold))
            Text("Este formato se edita como texto.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Ir a Fuente", action: goToSource)
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
                Text("Modificado fuera de la app")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(DiffEngine.summary(change.changes)) · \(change.date, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !change.changes.isEmpty {
                Button("Ver diff", action: onDiff).controlSize(.small)
            }
            if !volatile, change.previousContent != nil {
                Button("Revertir", action: onRevert).controlSize(.small)
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
    var onKeepMine: () -> Void
    var onTakeDisk: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Conflicto de edición")
                    .font(.system(size: 12, weight: .semibold))
                Text("El archivo cambió en disco mientras tenías ediciones sin guardar.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Mantener mi versión", action: onKeepMine).controlSize(.small)
            Button("Usar la de disco", action: onTakeDisk).controlSize(.small)
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
                Text("Contenido gestionado por terceros")
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
                Text("Problemas detectados").font(.headline)
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
