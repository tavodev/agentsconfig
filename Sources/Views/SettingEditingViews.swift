import SwiftUI

// MARK: - Value controls driven by the official reference

/// Text value with the documented options: a picker for closed lists, a
/// text field plus a suggestions menu when custom values are allowed. A
/// value outside a closed list is kept and shown as "Custom", never replaced.
struct SettingChoiceField: View {
    let label: String
    let doc: DocsCatalog.KeyDoc?
    @Binding var text: String
    var maxWidth: CGFloat = 380

    private var options: [String] { doc?.suggestedValues ?? [] }

    var body: some View {
        if doc?.spec?.isEnum == true {
            Picker(label, selection: $text) {
                ForEach(options, id: \.self) { option in
                    Text(optionLabel(option)).tag(option)
                }
                if !options.contains(text) {
                    Divider()
                    Text(L("Custom: %@", text)).tag(text)
                }
            }
            .labelsHidden()
            .frame(maxWidth: maxWidth, alignment: .leading)
            .pointerStyle(.link)
        } else {
            HStack(spacing: 4) {
                TextField(label, text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                if !options.isEmpty {
                    Menu {
                        ForEach(options, id: \.self) { option in
                            Button(optionLabel(option)) { text = option }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .pointerStyle(.link)
                    .help(L("Suggested values"))
                    .accessibilityLabel(L("Suggested values"))
                }
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
        }
    }

    private func optionLabel(_ option: String) -> String {
        guard let note = doc?.localizedValues?[option], !note.isEmpty else { return option }
        return option + " — " + note
    }
}

/// Editable list of text values: remove items, add new ones (with the
/// documented options as suggestions) and reorder with the arrows.
struct StringListField: View {
    @AppStorage("maskSecrets", store: AppSettings.defaults) private var maskSecrets = true
    let label: String
    let values: [String]
    let doc: DocsCatalog.KeyDoc?
    let editable: Bool
    let commit: ([String]) -> Void
    @State private var newValue = ""

    private var suggestions: [String] { (doc?.suggestedValues ?? []).filter { !values.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if values.isEmpty {
                Text(L("Empty list")).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                HStack(spacing: 6) {
                    Text(Secrets.displayText(value, path: label, masking: maskSecrets))
                        .font(.system(size: 13, design: .monospaced))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    if editable {
                        iconButton("arrow.up", L("Move up"), disabled: index == 0) { move(index, by: -1) }
                        iconButton("arrow.down", L("Move down"), disabled: index == values.count - 1) { move(index, by: 1) }
                        iconButton("minus.circle", L("Remove %@", value)) {
                            var updated = values
                            updated.remove(at: index)
                            commit(updated)
                        }
                    }
                }
                .padding(.vertical, 1)
                .accessibilityIdentifier("list-item:\(label)[\(index)]")
            }
            if editable {
                HStack(spacing: 6) {
                    TextField(L("Add value…"), text: $newValue)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .onSubmit(add)
                        .accessibilityIdentifier("list-add-field:" + label)
                    if !suggestions.isEmpty {
                        Menu {
                            ForEach(suggestions, id: \.self) { option in
                                Button(option) { newValue = option; add() }
                            }
                        } label: { Image(systemName: "chevron.down.circle") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .pointerStyle(.link)
                            .help(L("Suggested values"))
                    }
                    iconButton("plus.circle.fill", L("Add value to %@", label),
                               disabled: newValue.trimmingCharacters(in: .whitespaces).isEmpty, action: add)
                        .accessibilityIdentifier("list-add:" + label)
                }
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private func iconButton(_ symbol: String, _ label: String, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .pointerStyle(.link)
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard values.indices.contains(target) else { return }
        var updated = values
        updated.swapAt(index, target)
        commit(updated)
    }

    private func add() {
        let value = newValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        commit(values + [value])
        newValue = ""
    }
}

/// Removes the key so the agent falls back to its documented default.
struct ResetToDefaultButton: View {
    let spec: SettingSpec?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(helpText)
        .accessibilityLabel(L("Reset to default"))
        .accessibilityIdentifier("reset-default")
    }

    private var helpText: String {
        if let def = spec?.defaultJSON {
            return L("Reset to default (%@): removes the key from this file.", def)
        }
        return L("Reset to default: removes the key from this file.")
    }
}

/// "Default: x" caption shown next to a documented key.
struct DefaultBadge: View {
    let spec: SettingSpec?
    var body: some View {
        if let def = spec?.defaultJSON {
            Text(L("Default: %@", def))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Add setting sheet

/// Searchable list of every documented key the file can still take,
/// grouped by topic. Adding writes the default (or chosen) value into the
/// edit buffer; saving still goes through the reviewed save.
struct AddSettingSheet: View {
    let entries: [SettingCatalogEntry]
    let isDefined: ([String]) -> Bool
    /// Returns an error message, or nil when the key was added.
    let add: (_ path: [String], _ entry: SettingCatalogEntry, _ value: Any) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: String?
    @State private var names: [String] = []
    @State private var draft = ""
    @State private var draftBool = false
    @State private var error: String?

    private var filtered: [SettingCatalogEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.key.localizedCaseInsensitiveContains(q)
                || $0.doc.summary.localizedCaseInsensitiveContains(q)
                || ($0.doc.summaryES ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    private var topics: [String] {
        var seen: [String] = []
        for entry in filtered where !seen.contains(entry.spec.topic) { seen.append(entry.spec.topic) }
        return seen
    }

    private var selected: SettingCatalogEntry? { entries.first { $0.key == selection } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Add setting")).font(.title3.weight(.semibold))
                Text(L("Documented settings this file can take. Keys you don't set use their default value."))
                    .font(.callout).foregroundStyle(.secondary)
                TextField(L("Search settings"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("add-setting-search")
            }
            .padding(14)
            Divider()
            HSplitView {
                List(selection: $selection) {
                    ForEach(topics, id: \.self) { topic in
                        Section(L(topic)) {
                            ForEach(filtered.filter { $0.spec.topic == topic }) { entry in
                                row(entry).tag(entry.key)
                            }
                        }
                    }
                }
                .frame(minWidth: 300, idealWidth: 340)
                .accessibilityIdentifier("add-setting-list")
                detail
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            HStack {
                Text(L("%@ settings", String(filtered.count)))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 520, idealHeight: 600)
        .onChange(of: selection) { _, _ in prepareDraft() }
    }

    private func row(_ entry: SettingCatalogEntry) -> some View {
        let defined = entry.placeholders.isEmpty && isDefined(entry.segments)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.key)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(defined ? .secondary : .primary)
                if defined {
                    Text(L("Set")).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.2)))
                }
            }
            Text(entry.doc.plainSummary)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("add-setting-row:" + entry.key)
    }

    @ViewBuilder private var detail: some View {
        if let entry = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text(entry.key).font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        KeyDocButton(doc: entry.doc)
                    }
                    Text(entry.doc.attributedSummary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Label(L(kindName(entry.spec.kind)), systemImage: "tag")
                        if let def = entry.spec.defaultJSON {
                            Label(L("Default: %@", def), systemImage: "arrow.uturn.backward")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if let url = entry.doc.docsURL {
                        Link(L("Official docs") + " ↗", destination: url)
                            .font(.callout)
                            .pointerStyle(.link)
                    }
                    Divider()
                    ForEach(Array(entry.placeholders.enumerated()), id: \.offset) { index, placeholder in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Name for %@", placeholder)).font(.caption).foregroundStyle(.secondary)
                            TextField(placeholder, text: nameBinding(index))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13, design: .monospaced))
                                .accessibilityIdentifier("add-setting-name-\(index)")
                        }
                    }
                    valueEditor(entry)
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.red)
                    }
                    HStack {
                        Spacer()
                        Button(L("Add")) { commit(entry) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canAdd(entry))
                            .accessibilityIdentifier("add-setting-confirm")
                    }
                }
                .padding(14)
            }
        } else {
            ContentUnavailableView(L("Select a setting"), systemImage: "slider.horizontal.3",
                                   description: Text(L("Pick a setting to see what it does and add it.")))
        }
    }

    @ViewBuilder private func valueEditor(_ entry: SettingCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Value")).font(.caption).foregroundStyle(.secondary)
            switch entry.spec.kind {
            case .bool:
                Toggle(entry.key, isOn: $draftBool).toggleStyle(.switch).labelsHidden()
                    .accessibilityIdentifier("add-setting-bool")
            case .string:
                SettingChoiceField(label: entry.key, doc: entry.doc, text: $draft)
                    .accessibilityIdentifier("add-setting-value")
            case .integer, .number:
                TextField(entry.key, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(maxWidth: 180)
                    .accessibilityIdentifier("add-setting-value")
                if let problem = numberProblem(entry) {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            case .array:
                Text(L("Added as an empty list. Fill it in afterwards from its card or Source."))
                    .font(.callout).foregroundStyle(.secondary)
            case .object, .other:
                Text(L("Added as an empty table. Fill it in afterwards from Source."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func nameBinding(_ index: Int) -> Binding<String> {
        Binding(get: { index < names.count ? names[index] : "" },
                set: { value in
                    while names.count <= index { names.append("") }
                    names[index] = value
                })
    }

    private func prepareDraft() {
        error = nil
        names = []
        guard let entry = selected else { return }
        let value = entry.spec.initialValue
        draftBool = (value as? Bool) ?? false
        switch value {
        case let s as String: draft = s
        case let n as NSNumber where !(value is Bool): draft = n.stringValue
        default: draft = ""
        }
    }

    private func numberProblem(_ entry: SettingCatalogEntry) -> String? {
        guard let number = Double(draft.trimmingCharacters(in: .whitespaces)), number.isFinite else {
            return draft.isEmpty ? nil : L("Enter a valid number.")
        }
        return entry.spec.rangeProblem(number)
    }

    private func resolvedPath(_ entry: SettingCatalogEntry) -> [String]? {
        let given = entry.placeholders.indices.map { $0 < names.count ? names[$0].trimmingCharacters(in: .whitespaces) : "" }
        guard !given.contains(where: \.isEmpty) else { return nil }
        return entry.resolvedPath(given)
    }

    private func canAdd(_ entry: SettingCatalogEntry) -> Bool {
        guard let path = resolvedPath(entry), !isDefined(path) else { return false }
        switch entry.spec.kind {
        case .integer, .number:
            return Double(draft.trimmingCharacters(in: .whitespaces)) != nil && numberProblem(entry) == nil
        default:
            return true
        }
    }

    private func commit(_ entry: SettingCatalogEntry) {
        guard let path = resolvedPath(entry) else { return }
        let value: Any
        switch entry.spec.kind {
        case .bool: value = draftBool
        case .string: value = draft
        case .integer, .number:
            guard let number = NodeRow.parseNumber(draft.trimmingCharacters(in: .whitespaces)) else { return }
            value = number
        case .array: value = [Any]()
        case .object, .other: value = [String: Any]()
        }
        if let message = add(path, entry, value) {
            error = message
        } else {
            error = nil
            dismiss()
        }
    }

    private func kindName(_ kind: SettingSpec.Kind) -> String {
        switch kind {
        case .bool: "boolean"
        case .string: "text"
        case .integer: "integer"
        case .number: "number"
        case .array: "list"
        case .object, .other: "table"
        }
    }
}

// MARK: - Effective value across layers

/// Warns that another configuration layer decides this key.
struct LayerNoteView: View {
    let note: LayerNote

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(headline).font(.caption.weight(.semibold))
            } icon: {
                Image(systemName: "square.3.layers.3d.down.right")
            }
            if !note.reason.isEmpty {
                Text(L(note.reason)).font(.caption)
            }
            if let value = note.effectiveValue, let source = note.effectiveSource {
                Text(L("Effective value: %@ — from %@", value,
                       source.replacingOccurrences(of: AppPaths.home, with: "~")))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(note.informational ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("layer-note")
    }

    private var headline: String {
        let state = L(note.state)
        if let project = note.project {
            return L("%@ in project %@", state, project)
        }
        return state
    }
}

// MARK: - Documented children of an object

extension SettingCatalogEntry {
    /// Catalog entries under `prefix` (an existing object), with the prefix's
    /// concrete names written over matching `<name>` segments.
    static func children(of prefix: [String], in catalog: [SettingCatalogEntry]) -> [SettingCatalogEntry] {
        catalog.compactMap { entry in
            let segs = entry.segments
            guard segs.count > prefix.count else { return nil }
            for (seg, key) in zip(segs, prefix) where seg != key && !SettingCatalogEntry.isPlaceholder(seg) {
                return nil
            }
            let key = (prefix + segs.dropFirst(prefix.count)).joined(separator: ".")
            return SettingCatalogEntry(key: key, doc: entry.doc, spec: entry.spec)
        }
    }
}

/// "+ field" on an object row: opens the add sheet limited to its documented children.
struct AddChildSettingButton: View {
    let prefix: [String]
    let catalog: [SettingCatalogEntry]
    let isDefined: ([String]) -> Bool
    let add: (_ path: [String], _ entry: SettingCatalogEntry, _ value: Any) -> String?
    @State private var showing = false

    private var children: [SettingCatalogEntry] { SettingCatalogEntry.children(of: prefix, in: catalog) }

    var body: some View {
        if !children.isEmpty {
            Button { showing = true } label: {
                Image(systemName: "plus.circle").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help(L("Add a documented field to %@", prefix.joined(separator: ".")))
            .accessibilityLabel(L("Add a documented field to %@", prefix.joined(separator: ".")))
            .accessibilityIdentifier("add-child:" + prefix.joined(separator: "."))
            .sheet(isPresented: $showing) {
                AddSettingSheet(entries: children, isDefined: isDefined, add: add)
            }
        }
    }
}
