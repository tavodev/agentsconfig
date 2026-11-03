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
                Text(L("Edit existing text, boolean, numeric and text-list values here, or add documented settings with Add setting. Comments and surrounding formatting are preserved. Use Source for dates, tables and lists with comments."))
                    .font(.callout).foregroundStyle(.secondary)
                if let fields = try? TOMLScalarEditor.fields(in: text) {
                    if fields.isEmpty {
                        Text(L("No supported scalar values. Use Source to edit this document."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(Array(fields.prefix(200))) { field in
                        TOMLScalarValueRow(path: path, sourceText: text, field: field)
                    }
                    if let lists = try? TOMLScalarEditor.stringLists(in: text) {
                        ForEach(Array(lists.prefix(100))) { list in
                            TOMLListRow(path: path, sourceText: text, field: list)
                        }
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
    @Environment(\.layerNotes) private var layerNotes
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
    private var doc: DocsCatalog.KeyDoc? { DocsCatalog.keyDoc(filePath: path, keyPath: field.path) }
    private var kindLabel: String {
        field.value.kind == .bool ? "boolean" : field.value.kind.rawValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(displayLabel).font(.callout.monospaced()).textSelection(.enabled)
                if let doc {
                    KeyDocButton(doc: doc)
                    DefaultBadge(spec: doc.spec)
                }
                Spacer()
                Text(L(kindLabel)).font(.caption).foregroundStyle(.secondary)
                if let doc, doc.spec != nil {
                    ResetToDefaultButton(spec: doc.spec) { reset() }
                        .disabled(blocked)
                }
            }
            if let doc {
                Text(doc.attributedSummary)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = layerNotes[field.path.joined(separator: ".")] {
                LayerNoteView(note: note)
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
        } else if field.value.kind == .string, let doc, !doc.suggestedValues.isEmpty {
            SettingChoiceField(label: displayLabel, doc: doc, text: $draft, maxWidth: .infinity)
        } else {
            TextField(displayLabel, text: $draft, axis: .vertical)
                .lineLimit(1...6).textFieldStyle(.roundedBorder)
        }
    }

    private func reset() {
        guard !blocked else { return }
        guard store.text(for: path) == sourceText else {
            error = L("The document changed. Review the current value before applying.")
            return
        }
        do {
            store.updateEdit(path: path, text: try TOMLScalarEditor.removing(in: sourceText, path: field.path))
            error = nil
        } catch { self.error = L(error.localizedDescription) }
    }

    private func apply() {
        guard !blocked else { return }
        guard store.text(for: path) == sourceText else {
            error = L("The document changed. Review the current value before applying.")
            return
        }
        do {
            if field.value.kind == .integer || field.value.kind == .float,
               let number = Double(draft.trimmingCharacters(in: .whitespaces)),
               let problem = doc?.spec?.rangeProblem(number) {
                error = problem
                return
            }
            let proposed = try TOMLScalarEditor.replacing(in: sourceText, path: field.path, input: draft)
            let canonical = try TOMLScalarEditor.fields(in: proposed).first { $0.path == field.path }?.value.text
            store.updateEdit(path: path, text: proposed)
            draft = canonical ?? draft
            error = nil
        } catch { self.error = L(error.localizedDescription) }
    }
}

/// A string array edited in place; the array text is rewritten and validated.
private struct TOMLListRow: View {
    let path: String
    let sourceText: String
    let field: TOMLScalarEditor.ListField
    @Environment(ConfigStore.self) private var store
    @Environment(\.layerNotes) private var layerNotes
    @State private var error: String?

    private var doc: DocsCatalog.KeyDoc? { DocsCatalog.keyDoc(filePath: path, keyPath: field.path) }
    private var blocked: Bool {
        store.isReadOnly(path) || store.savingPaths.contains(path) || store.loadingPaths.contains(path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(field.label).font(.callout.monospaced()).textSelection(.enabled)
                if let doc { KeyDocButton(doc: doc) }
                Spacer()
                Text(L("list")).font(.caption).foregroundStyle(.secondary)
                if let doc, doc.spec != nil {
                    ResetToDefaultButton(spec: doc.spec) { apply { try TOMLScalarEditor.removing(in: $0, path: field.path) } }
                        .disabled(blocked)
                }
            }
            if let doc {
                Text(doc.attributedSummary)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = layerNotes[field.path.joined(separator: ".")] {
                LayerNoteView(note: note)
            }
            StringListField(label: field.label, values: field.values, doc: doc, editable: !blocked) { values in
                apply { try TOMLScalarEditor.replacingStringList(in: $0, path: field.path, with: values) }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
            }
        }
    }

    private func apply(_ edit: (String) throws -> String) {
        guard !blocked else { return }
        guard store.text(for: path) == sourceText else {
            error = L("The document changed. Review the current value before applying.")
            return
        }
        do {
            store.updateEdit(path: path, text: try edit(sourceText))
            error = nil
        } catch { self.error = L(error.localizedDescription) }
    }
}
