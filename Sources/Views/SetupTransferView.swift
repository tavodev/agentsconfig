import SwiftUI
import AppKit

/// Export the setup as a redacted folder with a manifest (issue #24).
struct SetupExportSheet: View {
    @Environment(ConfigStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var includeProjects = true
    @State private var includeSensitive = false
    @State private var result: String?
    @State private var error: String?

    private var options: SetupExportOptions { .init(includeProjects: includeProjects, includeSensitive: includeSensitive) }

    var body: some View {
        let candidates = store.setupExportCandidates(options)
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Export setup")).font(.title2.bold())
            Toggle(L("Include registered projects"), isOn: $includeProjects)
            Toggle(L("Include state and files excluded from history"), isOn: $includeSensitive)
            Text(L("Values that look like secrets are replaced with ••••••••. Redaction is best-effort: a secret without a recognizable key, URL or argument position can remain. Review the folder before sharing it. Structured files are normalized (comments are removed)."))
                .font(.callout).foregroundStyle(.orange)
            Text(L("%d files", candidates.count)).font(.headline)
            List(candidates, id: \.file.path) { candidate in
                HStack {
                    Text(candidate.agent).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                    Text((candidate.project.map { $0 + "/" } ?? "~/") + candidate.relative).font(.caption.monospaced())
                        .lineLimit(1).truncationMode(.middle)
                }
            }.listStyle(.inset).frame(minHeight: 200)
            if let result { Text(result).font(.callout).textSelection(.enabled) }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button(L("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Export to folder…")) { export() }
                    .disabled(candidates.isEmpty).accessibilityIdentifier("export-setup")
            }
        }.padding(20).frame(minWidth: 620, minHeight: 520)
    }

    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = L("Export here")
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = parent.appendingPathComponent("AgentsConfig-setup-" + formatter.string(from: Date()), isDirectory: true)
        do {
            let manifest = try store.exportSetup(to: folder, options: options)
            error = nil
            result = L("Exported %d files to %@", manifest.files.count, folder.path)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch { self.error = L("Could not export the setup."); result = nil }
    }
}

/// Import preview: one reviewed operation per file. Staging a file closes
/// this sheet so the review can open; nothing is written before it.
struct SetupImportSheet: View {
    @Environment(ConfigStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let directory: URL
    @State private var items: [SetupImportItem] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Import setup")).font(.title2.bold())
            Text(directory.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Text(L("Each file opens a diff review. Redacted values never replace real ones: they keep the local value or are left out."))
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            List(items) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text((item.file.project.map { $0 + "/" } ?? "~/") + item.file.path).font(.callout.monospaced())
                            .lineLimit(1).truncationMode(.middle)
                        Text(item.file.agent + (item.file.redacted ? " · " + L("contains redacted values") : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(L(item.status.rawValue)).font(.caption)
                        .foregroundStyle(item.status == .tampered || item.status == .unmapped ? Color.orange : Color.secondary)
                    Button(L("Review")) {
                        if store.stageSetupImport(item, from: directory) { dismiss() }
                    }
                    .disabled(![.new, .differs].contains(item.status))
                    .accessibilityIdentifier("import-setup:" + item.id)
                }
            }.listStyle(.inset).frame(minHeight: 240)
            HStack {
                Button(L("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
            }
        }
        .padding(20).frame(minWidth: 640, minHeight: 480)
        .onAppear {
            do { items = try store.setupImportItems(from: directory) }
            catch { self.error = L("This folder has no readable AgentsConfig manifest.") }
        }
    }
}
