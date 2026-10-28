import SwiftUI

/// Native scalar edits patch the current buffer. Saving still uses the
/// editor's normal reviewed save; unsupported TOML values stay in Source.
struct TOMLScalarEditingView: View {
    let path: String
    let text: String
    @Environment(ConfigStore.self) private var store

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("Edit TOML values")).font(.headline)
                Text(L("Edit existing text, boolean and numeric values here. Comments and surrounding formatting are preserved. Use Source for arrays, dates, tables and new keys."))
                    .font(.callout).foregroundStyle(.secondary)
                if let fields = try? TOMLScalarEditor.fields(in: text) {
                    if fields.isEmpty {
                        Text(L("No supported scalar values. Use Source to edit this document."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(Array(fields.prefix(200))) { field in
                        TOMLScalarValueRow(path: path, sourceText: text, field: field)
                    }
                    if fields.count > 200 {
                        Text(L("Showing the first 200 values. Use Source for the remaining values."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Text(L("This TOML syntax requires editing in Source."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct TOMLScalarValueRow: View {
    let path: String
    let sourceText: String
    let field: TOMLScalarEditor.Field
    @Environment(ConfigStore.self) private var store
    @AppStorage("maskSecrets", store: AppSettings.defaults) private var maskSecrets = true
    @State private var draft: String
    @State private var error: String?

    init(path: String, sourceText: String, field: TOMLScalarEditor.Field) {
        self.path = path
        self.sourceText = sourceText
        self.field = field
        _draft = State(initialValue: field.value.text)
    }

    private var isSecret: Bool {
        Secrets.isSensitive(field.value.text, path: field.path.joined(separator: "."))
            || Secrets.isSensitive(draft, path: field.path.joined(separator: "."))
    }
    private var displayLabel: String { Secrets.displayText(field.label, masking: maskSecrets) }
    private var controlID: String { SnapshotStore.sha256(field.label) }
    private var blocked: Bool {
        store.isReadOnly(path) || store.savingPaths.contains(path) || store.loadingPaths.contains(path)
    }
    private var kindLabel: String {
        field.value.kind == .bool ? "boolean" : field.value.kind.rawValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(displayLabel).font(.callout.monospaced()).textSelection(.enabled)
                Spacer()
                Text(L(kindLabel)).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                valueControl
                    .accessibilityLabel(displayLabel)
                    .accessibilityIdentifier("toml-value:" + controlID)
                Button(L("Apply")) { apply() }
                    .disabled(draft == field.value.text || blocked)
                    .accessibilityLabel(L("Apply value for %@", displayLabel))
                    .accessibilityIdentifier("toml-apply:" + controlID)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
            }
        }
        .disabled(blocked)
        .onChange(of: field.value.text) { _, value in draft = value; error = nil }
        .onChange(of: field.value.kind) { _, _ in draft = field.value.text; error = nil }
    }

    @ViewBuilder private var valueControl: some View {
        if maskSecrets && isSecret {
            SecureField(displayLabel, text: $draft).textFieldStyle(.roundedBorder)
        } else if field.value.kind == .bool {
            Picker(displayLabel, selection: $draft) {
                Text("true").tag("true")
                Text("false").tag("false")
            }.labelsHidden().pickerStyle(.segmented)
        } else {
            TextField(displayLabel, text: $draft, axis: .vertical)
                .lineLimit(1...6).textFieldStyle(.roundedBorder)
        }
    }

    private func apply() {
        guard !blocked else { return }
        guard store.text(for: path) == sourceText else {
            error = L("The document changed. Review the current value before applying.")
            return
        }
        do {
            let proposed = try TOMLScalarEditor.replacing(in: sourceText, path: field.path, input: draft)
            let canonical = try TOMLScalarEditor.fields(in: proposed).first { $0.path == field.path }?.value.text
            store.updateEdit(path: path, text: proposed)
            draft = canonical ?? draft
            error = nil
        } catch { self.error = L(error.localizedDescription) }
    }
}
