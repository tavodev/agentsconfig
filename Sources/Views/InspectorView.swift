import SwiftUI
import AppKit

/// Right-edge inspector (Xcode-style): metadata, issues and quick actions
/// for the selected file, using the system inspector presentation.
struct FileInspectorView: View {
    let path: String?
    @Environment(ConfigStore.self) private var store

    private var file: TrackedFile? {
        guard let path else { return nil }
        for agent in store.agents {
            if let f = agent.files.first(where: { $0.path == path }) { return f }
        }
        return nil
    }

    var body: some View {
        if let path, let file {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let fd = DocsCatalog.fileDoc(for: path) {
                        aboutSection(fd)
                    }
                    metaSection(path: path, file: file)
                    if let source = OrcaIntegration.sourcePath(for: path) {
                        OrcaSyncSection(path: path, sourcePath: source, copyModified: file.mtime)
                    }
                    if !file.issues.isEmpty { issuesSection(file) }
                    if !file.managedBlocks.isEmpty { managedSection(file) }
                    actionsSection(path: path)
                }
                .padding(14)
            }
        } else {
            ContentUnavailableView(L("No selection"), systemImage: "sidebar.trailing")
        }
    }

    private func aboutSection(_ doc: DocsCatalog.FileDoc) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(doc.localizedTitle, systemImage: "questionmark.circle")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(doc.localizedBody)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = doc.docsURL {
                Link(L("Official docs") + " ↗", destination: url)
                    .font(.callout)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)

    }

    private func metaSection(path: String, file: TrackedFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Metadata")).font(.headline)
                .foregroundStyle(.secondary)
            Text(path.replacingOccurrences(of: AppPaths.home, with: "~"))
                .font(.callout.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            metaRow(L("Format"), file.format.badge)
            metaRow(L("Role"), L(file.role.label))
            metaRow(L("Size"), ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
            if let m = file.mtime {
                metaRow(L("Modified"), m.formatted(date: .abbreviated, time: .shortened))
            }
            if let perms = posixPerms(path) { metaRow(L("Permissions"), perms) }
            if file.volatile { metaRow(L("Type"), L("volatile (state)")) }
            if file.readOnly { metaRow(L("Access"), L("read-only")) }
            if let note = file.note { Text(L(note)).font(.callout).foregroundStyle(.secondary) }
        }
    }

    private func issuesSection(_ file: TrackedFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Issues")).font(.headline)
                .foregroundStyle(.secondary)
            ForEach(Array(file.issues.enumerated()), id: \.offset) { _, i in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: i.severity == .error ? "xmark.octagon.fill" :
                                    i.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .font(.callout)
                        .foregroundStyle(i.severity == .error ? .red :
                                            i.severity == .warning ? .orange : .blue)
                    Text(i.message).font(.callout)
                }
            }
        }
    }

    private func managedSection(_ file: TrackedFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Managed by third parties")).font(.headline)
                .foregroundStyle(.secondary)
            ForEach(Array(file.managedBlocks.enumerated()), id: \.offset) { _, b in
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.owner).font(.caption.bold())
                    Text(b.detail).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func actionsSection(path: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Actions")).font(.headline)
                .foregroundStyle(.secondary)
            InspectorAction(icon: "folder", label: L("Show in Finder")) {
                store.revealInFinder(path)
            }
            InspectorAction(icon: "app.badge", label: L("Open with default app")) {
                store.openInDefaultApp(path)
            }
            InspectorAction(icon: "doc.on.doc", label: L("Copy path")) {
                store.copyPath(path)
            }
            InspectorAction(icon: "arrow.uturn.backward", label: L("Restore previous version")) {
                store.requestRestorePrevious(path)
            }
            .disabled(store.history(for: path).isEmpty || store.isReadOnly(path))
        }
    }

    private func metaRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    private func posixPerms(_ path: String) -> String? {
        guard let n = try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        else { return nil }
        return String(format: "%o", n)
    }
}

struct InspectorAction: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.primary)
        .padding(.vertical, 2)
    }
}

/// Origin and sync status of a file Orca regenerates from ~/.claude / ~/.codex.
/// Recomputed off the main actor when either side changes on disk.
private struct OrcaSyncSection: View {
    let path: String
    let sourcePath: String
    let copyModified: Date?
    @Environment(ConfigStore.self) private var store
    @State private var status: OrcaIntegration.SyncStatus?

    private var sourceFile: TrackedFile? {
        for agent in store.agents {
            if let f = agent.files.first(where: { $0.path == sourcePath }) { return f }
        }
        return nil
    }

    private struct Key: Equatable { var path: String; var copy: Date?; var source: Date?; var exists: Bool? }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Orca copy")).font(.headline)
                .foregroundStyle(.secondary)
            HStack {
                Text(L("Generated from")).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text(sourcePath.replacingOccurrences(of: AppPaths.home, with: "~"))
                    .font(.caption.monospaced()).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint).font(.callout)
                Text(status.map { L(Self.label($0)) } ?? L("Comparing…"))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            InspectorAction(icon: "arrow.right.doc.on.clipboard", label: L("Open source")) {
                store.openFile(sourcePath)
            }
            .disabled(sourceFile == nil)
            .help(sourceFile == nil ? L("The source file is not listed in the app") : "")
        }
        .task(id: Key(path: path, copy: copyModified, source: sourceFile?.mtime, exists: sourceFile?.exists)) {
            let path = path
            status = nil
            status = await Task.detached(priority: .utility) { OrcaIntegration.syncStatus(for: path) }.value
        }
    }

    private var icon: String {
        switch status {
        case .synced?: "checkmark.circle.fill"
        case .pending?: "clock.arrow.circlepath"
        case .differs?, .sourceMissing?: "exclamationmark.triangle.fill"
        default: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch status {
        case .synced?: .green
        case .differs?, .sourceMissing?: .orange
        default: .secondary
        }
    }

    static func label(_ status: OrcaIntegration.SyncStatus) -> String {
        switch status {
        case .synced: "In sync with the source."
        case .pending: "The source changed after this copy; Orca updates it on its next launch."
        case .differs: "Differs from the source with no newer source change to explain it; Orca overwrites it on its next launch."
        case .sourceMissing: "The source file does not exist; Orca leaves this copy as it is."
        case .undetermined: "Differs from the source, but Orca may explain it (account-only keys, promoted settings or rewritten paths); not determined."
        case .notApplicable: "Not compared."
        }
    }
}
