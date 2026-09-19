import SwiftUI
import AppKit

struct DiagnosticsView: View {
    let configuration: ConfigurationAnalysis
    let diagnostics: [AuditDiagnostic]
    struct ExportSnapshot: Identifiable {
        let id = UUID()
        let configuration: ConfigurationAnalysis
        let diagnostics: [AuditDiagnostic]
    }
    @State private var snapshot: ExportSnapshot?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Diagnostics")).font(.title3.bold())
                Spacer()
                Button(L("Review export…")) {
                    snapshot = ExportSnapshot(configuration: configuration, diagnostics: diagnostics)
                }.accessibilityIdentifier("review-diagnostic-export")
            }.padding(.horizontal, 20).padding(.top, 16)
            Text(L("Static checks only. A clean report does not verify runtime permissions, authentication or connectivity."))
                .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 20)
            List(diagnostics) { item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(item.code).font(.caption.monospaced())
                        Text(L(item.severity)).font(.caption).foregroundStyle(item.severity == "error" ? .red : .secondary)
                    }
                    Text(item.message).font(.callout)
                    Text(item.source).font(.caption.monospaced()).textSelection(.enabled)
                }
            }.listStyle(.inset)
        }
        .sheet(item: $snapshot) { request in
            DiagnosticExportReview(configuration: request.configuration, diagnostics: request.diagnostics)
        }
    }
}

private struct DiagnosticExportReview: View {
    let configuration: ConfigurationAnalysis
    let diagnostics: [AuditDiagnostic]
    @Environment(ConfigStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var anonymize = true
    @State private var values = false
    @State private var markdown = false
    @State private var error: String?
    private var content: String? {
        try? DiagnosticReportBuilder.serialize(DiagnosticReportBuilder.make(configuration: configuration,
            diagnostics: diagnostics, anonymizePaths: anonymize, includeValues: values), markdown: markdown)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Review diagnostic export")).font(.title2.bold())
            Toggle(L("Anonymize paths and omit free-form diagnostic details"), isOn: $anonymize)
            Toggle(L("Include redacted setting values"), isOn: $values).disabled(anonymize)
            Toggle(L("Markdown format"), isOn: $markdown)
            Text(L("This preview is a fixed snapshot. Inspect the exact content before saving. No report is uploaded."))
                .font(.callout).foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) { Text(content ?? L("Could not generate report.")).font(.caption.monospaced()).textSelection(.enabled) }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Save report…")) {
                    guard let content else { return }
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = markdown ? "agentsconfig-diagnostics.md" : "agentsconfig-diagnostics.json"
                    guard panel.runModal() == .OK, let path = panel.url?.path else { return }
                    guard !store.agents.flatMap(\.files).contains(where: { AppPaths.canonicalPath($0.path) == AppPaths.canonicalPath(path) }) else {
                        error = L("Choose a destination outside tracked configuration files."); return
                    }
                    do { try AtomicWriter.writePreservingPermissions(content, toPath: path); dismiss() }
                    catch { self.error = L("Could not save the report.") }
                }.disabled(content == nil).accessibilityIdentifier("save-diagnostic-report")
            }
        }.padding(20).frame(minWidth: 660, idealWidth: 800, minHeight: 520)
    }
}

struct CatalogSearchView: View {
    @Environment(ConfigStore.self) private var store
    @State private var query = ""
    @State private var hits: [CatalogSearchHit] = []
    @State private var loading = false
    var body: some View {
        VStack(alignment: .leading) {
            Text(L("Search all inspected files")).font(.title2.bold()).padding([.top, .horizontal], 20)
            Text(L("Search uses redacted content from loaded files up to 2 MB. Results are limited to 100 files."))
                .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 20)
            if loading { ProgressView().padding(.horizontal, 20) }
            List(hits) { hit in
                Button { store.openFile(hit.path) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(hit.path).font(.body.monospaced()).lineLimit(2)
                        Text(hit.excerpt).font(.caption).lineLimit(3).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }.listStyle(.inset)
        }
        .navigationTitle(L("Search"))
        .searchable(text: $query, prompt: L("Search names, keys and redacted content"))
        .task(id: query + String(store.analysisRevision)) {
            loading = true
            let result = await store.searchCatalog(query)
            guard !Task.isCancelled else { return }
            hits = result; loading = false
        }
    }
}
struct CatalogSearchHit: Identifiable {
    var id: String { path }
    let path: String
    let excerpt: String
}
