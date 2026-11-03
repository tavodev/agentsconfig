import SwiftUI
import AppKit

// MARK: - Key-path helpers for mutating JSON trees

enum Seg: Hashable {
    case key(String)
    case idx(Int)

    var pathComponent: String {
        switch self {
        case .key(let k): return k
        case .idx(let i): return "[\(i)]"
        }
    }
}

func pathLabel(_ segs: [Seg]) -> String {
    var out = ""
    for s in segs {
        switch s {
        case .key(let k): out = out.isEmpty ? k : "\(out).\(k)"
        case .idx(let i): out += "[\(i)]"
        }
    }
    return out
}

func getAt(_ root: Any?, _ segs: [Seg]) -> Any? {
    var cur = root
    for s in segs {
        switch s {
        case .key(let k): cur = (cur as? [String: Any])?[k]
        case .idx(let i):
            guard let a = cur as? [Any], i < a.count else { return nil }
            cur = a[i]
        }
    }
    return cur
}

func setAt(_ root: inout [String: Any], _ segs: [Seg], _ value: Any?) {
    guard let first = segs.first else { return }
    if segs.count == 1 {
        switch first {
        case .key(let k): root[k] = value
        case .idx: break
        }
        return
    }
    guard case .key(let k) = first else { return }
    var child = root[k]
    setAtAny(&child, Array(segs.dropFirst()), value)
    root[k] = child
}

private func setAtAny(_ node: inout Any?, _ segs: [Seg], _ value: Any?) {
    guard let first = segs.first else { node = value; return }
    switch first {
    case .key(let k):
        var dict = node as? [String: Any] ?? [:]
        var child = dict[k]
        setAtAny(&child, Array(segs.dropFirst()), value)
        dict[k] = child
        node = dict
    case .idx(let i):
        var arr = node as? [Any] ?? []
        while arr.count <= i { arr.append(NSNull()) }
        var child: Any? = arr[i]
        setAtAny(&child, Array(segs.dropFirst()), value)
        arr[i] = child as Any
        node = arr
    }
}

func removeAt(_ root: inout [String: Any], _ segs: [Seg]) {
    func rec(_ node: inout Any?, _ remaining: ArraySlice<Seg>) {
        guard let first = remaining.first else { return }
        switch first {
        case .key(let k):
            var dict = node as? [String: Any] ?? [:]
            if remaining.count == 1 {
                dict.removeValue(forKey: k)
            } else {
                var child = dict[k]
                rec(&child, remaining.dropFirst())
                dict[k] = child
            }
            node = dict
        case .idx(let i):
            var arr = node as? [Any] ?? []
            if remaining.count == 1 {
                if i < arr.count { arr.remove(at: i) }
            } else if i < arr.count {
                var child: Any? = arr[i]
                rec(&child, remaining.dropFirst())
                arr[i] = child as Any
            }
            node = arr
        }
    }
    var any: Any? = root
    rec(&any, segs[...])
    if let d = any as? [String: Any] { root = d }
}

/// Plain lists of text (empty lists included), editable as one field.
func isStringList(_ list: [Any]) -> Bool {
    list.count <= 500 && list.allSatisfy { $0 is String }
}

func isBool(_ v: Any) -> Bool {
    (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? (v is Bool)
}

// MARK: - Structured view

struct StructuredView: View {
    let path: String
    let doc: ConfigDocument?
    let format: ConfigFormat
    var readOnly: Bool

    @Environment(ConfigStore.self) private var store
    @State private var showingAddSetting = false
    @State private var layerNotes: [String: LayerNote] = [:]

    private var canWriteStructured: Bool {
        format == .json || format == .jsonc
    }

    private var editable: Bool { !readOnly && canWriteStructured && root != nil }

    private var editableTOMLPaths: Set<[String]> {
        guard format == .toml, !readOnly,
              let fields = try? TOMLScalarEditor.fields(in: store.text(for: path)) else { return [] }
        let lists = (try? TOMLScalarEditor.stringLists(in: store.text(for: path))) ?? []
        return Set(fields.prefix(200).map(\.path) + lists.prefix(100).map(\.path))
    }

    private var root: [String: Any]? {
        Parsers.parse(store.text(for: path), format: format).tree as? [String: Any]
    }

    /// An empty TOML parses to an empty (non-nil) table and an empty JSON
    /// string parses to nil/an error — either way there's nothing to show,
    /// so this is checked first and short-circuits both of those cases with
    /// one clear message instead of a confusing blank card or parse error.
    private var isEmptyOrMissing: Bool {
        store.text(for: path).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var fileExists: Bool {
        for agent in store.agents {
            if let f = agent.files.first(where: { $0.path == path }) { return f.exists }
        }
        return FileManager.default.fileExists(atPath: path)
    }

    private func mutate(_ block: (inout [String: Any]) -> Void) {
        var r = root ?? [:]
        block(&r)
        let s: String? = switch format {
        case .toml: Parsers.serializeTOML(r)
        default: Parsers.serializeJSON(r)
        }
        if let s { store.updateEdit(path: path, text: s) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !isEmptyOrMissing && root?.isEmpty == true {
                    ContentUnavailableView(L("No settings yet"), systemImage: "slider.horizontal.3",
                        description: Text(store.isMcpDestination(path)
                            ? L("This configuration is empty. Add an MCP server or use Source to add settings.")
                            : L("This configuration contains no settings.")))
                } else if isEmptyOrMissing {
                    Card {
                        Label(fileExists ? L("Empty file — nothing to show yet.")
                                         : L("This file doesn't exist on disk yet."),
                              systemImage: fileExists ? "doc" : "doc.badge.ellipsis")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if let err = doc?.parseError {
                    Card {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                        Text(L("Fix the error in the Source tab to enable the structured view."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else if root == nil {
                    Card {
                        Label(L("This file is not a structured JSON/TOML object."),
                              systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if readOnly {
                        Card {
                            Label(L("Read-only structured view — edit in the Source tab (%@ format).", format.badge),
                                  systemImage: "lock")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    addSettingBar
                    if !readOnly && format == .toml {
                        TOMLScalarEditingView(path: path, text: store.text(for: path))
                    }
                    specialCards
                    GenericInspector(filePath: path, root: root ?? [:],
                                     editable: editable, excludedKeys: handledTopLevelKeys,
                                     excludedPaths: editableTOMLPaths, mutate: mutate,
                                     addContext: addContext)
                }
            }
            .padding(14)
        }
        .environment(\.layerNotes, layerNotes)
        .task(id: path + "|" + (doc?.hash ?? "") + "|" + store.preferredAnalysisProject) {
            layerNotes = store.layerNotes(for: path)
        }
    }

    // MARK: add setting

    private var addContext: AddSettingContext? {
        guard canAddSettings, let catalog = DocsCatalog.settingsCatalog(filePath: path) else { return nil }
        return AddSettingContext(catalog: catalog,
                                 isDefined: { keys in getAt(root, keys.map(Seg.key)) != nil },
                                 add: { keys, entry, value in addSetting(keys, entry: entry, value: value) })
    }

    private var canAddSettings: Bool {
        !readOnly && root != nil && (canWriteStructured || format == .toml)
            && !store.isReadOnly(path) && !store.savingPaths.contains(path) && !store.loadingPaths.contains(path)
    }

    @ViewBuilder
    private var addSettingBar: some View {
        if canAddSettings, let catalog = DocsCatalog.settingsCatalog(filePath: path) {
            HStack {
                Button {
                    showingAddSetting = true
                } label: {
                    Label(L("Add setting"), systemImage: "plus.circle")
                }
                .pointerStyle(.link)
                .accessibilityIdentifier("add-setting")
                Text(L("%@ documented settings available", String(catalog.count)))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .sheet(isPresented: $showingAddSetting) {
                AddSettingSheet(entries: catalog,
                                isDefined: { keys in getAt(root, keys.map(Seg.key)) != nil },
                                add: { keys, entry, value in addSetting(keys, entry: entry, value: value) })
                    .environment(store)
            }
        }
    }

    /// Writes a new key into the edit buffer. JSON goes through the tree;
    /// TOML is inserted as text so comments and formatting survive.
    private func addSetting(_ keys: [String], entry: SettingCatalogEntry, value: Any) -> String? {
        guard canAddSettings else { return L("This file can't be edited right now.") }
        let segs = keys.map(Seg.key)
        guard getAt(root, segs) == nil else { return L("This setting is already set in this file.") }
        for length in 1..<keys.count {
            if let parent = getAt(root, Array(segs.prefix(length))), !(parent is [String: Any]) {
                return L("“%@” isn't a table, so this setting can't go inside it. Use Source.",
                         keys.prefix(length).joined(separator: "."))
            }
        }
        if format == .toml {
            let newValue: TOMLScalarEditor.NewValue
            switch value {
            case let b as Bool: newValue = .scalar(.bool(b))
            case let s as String: newValue = .scalar(.string(s))
            case let i as Int: newValue = .scalar(.integer(Int64(i)))
            case let d as Double: newValue = .scalar(.float(d))
            case is [Any]: newValue = .emptyArray
            default: newValue = .table
            }
            do {
                store.updateEdit(path: path, text: try TOMLScalarEditor.inserting(in: store.text(for: path), path: keys, value: newValue))
            } catch {
                return L(error.localizedDescription)
            }
        } else {
            mutate { r in setAt(&r, segs, value) }
        }
        return nil
    }

    // MARK: special sections

    /// Top-level keys already rendered by a card in `specialCards` — kept
    /// out of the generic "All keys" tree below so nothing shows twice.
    private var handledTopLevelKeys: Set<String> {
        guard let r = root else { return [] }
        var keys: Set<String> = []
        if let mcpKey = ["mcpServers", "mcp", "mcp_servers"].first(where: { r[$0] is [String: Any] }) {
            keys.insert(mcpKey)
        }
        if r["permissions"] is [String: Any] { keys.insert("permissions") }
        if r["hooks"] is [String: Any] { keys.insert("hooks") }
        if r["enabledPlugins"] is [String: Any] { keys.insert("enabledPlugins") }
        if r["env"] is [String: Any] { keys.insert("env") }
        return keys
    }

    @ViewBuilder
    private var specialCards: some View {
        if let r = root {
            if let mcpKey = ["mcpServers", "mcp", "mcp_servers"].first(where: { r[$0] is [String: Any] }),
               let servers = r[mcpKey] as? [String: Any] {
                MCPCard(filePath: path, keyPath: [Seg.key(mcpKey)], servers: servers,
                        editable: editable, mutate: mutate)
            }
            if let perms = r["permissions"] as? [String: Any] {
                PermissionsCard(keyPath: [.key("permissions")], perms: perms,
                                editable: editable, mutate: mutate)
            }
            if let hooks = r["hooks"] as? [String: Any] {
                HooksCard(hooks: hooks)
            }
            if let plugins = r["enabledPlugins"] as? [String: Any] {
                BoolMapCard(title: L("Enabled plugins"), icon: "puzzlepiece",
                            keyPath: [.key("enabledPlugins")], map: plugins,
                            editable: editable, mutate: mutate)
            }
            if let env = r["env"] as? [String: Any] {
                StringMapCard(title: L("Environment variables"), icon: "terminal",
                              keyPath: [.key("env")], map: env,
                              editable: editable, mutate: mutate)
            }
        }
    }
}

// MARK: - Card container

struct Card<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(contrast == .increased ? Color.primary : Color.secondary.opacity(0.2),
                                  lineWidth: contrast == .increased ? 1 : 0.5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            )
    }
}

struct CardHeader: View {
    let title: String
    let icon: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Spacer()
        }
    }
}

/// ⓘ button → popover explaining what a config key does.
struct KeyDocButton: View {
    let doc: DocsCatalog.KeyDoc
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(doc.plainSummary)
        .accessibilityLabel(doc.plainSummary)
        .accessibilityIdentifier("key-doc")
        .popover(isPresented: $show, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(doc.attributedSummary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let values = doc.localizedValues, !values.isEmpty {
                    Divider()
                    ForEach(values.keys.sorted(), id: \.self) { v in
                        HStack(alignment: .top, spacing: 8) {
                            Text(v)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .frame(minWidth: 110, alignment: .leading)
                            Text(values[v] ?? "")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let def = doc.defaultValue {
                    Divider()
                    Text(L("Default: %@", def))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let url = doc.docsURL {
                    Divider()
                    Link(L("Official docs") + " ↗", destination: url)
                        .font(.callout)
                        .pointerStyle(.link)
                        .help(url.absoluteString)
                        .accessibilityIdentifier("key-doc-link")
                }
            }
            .padding(12)
            .frame(maxWidth: 340)
        }
    }
}

// MARK: - MCP servers card

struct MCPCard: View {
    let filePath: String
    @Environment(ConfigStore.self) private var store
    let keyPath: [Seg]
    let servers: [String: Any]
    let editable: Bool
    let mutate: ((inout [String: Any]) -> Void) -> Void
    @State private var showAdd = false
    private var names: [String] { servers.keys.sorted() }

    var body: some View {
        Card {
            HStack {
                CardHeader(title: L("MCP servers"), icon: "network")
                if store.isMcpDestination(filePath) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Add MCP server"))
                    .popover(isPresented: $showAdd) { McpAddForm(path: filePath) { showAdd = false } }
                }
            }
            ForEach(names, id: \.self) { name in
                MCPServerRow(name: name, spec: servers[name],
                             editable: editable,
                             onToggleEnabled: { enabled in
                                 mutate { r in
                                     var sp = getAt(r, keyPath + [.key(name)]) as? [String: Any] ?? [:]
                                     if sp["enabled"] != nil { sp["enabled"] = enabled }
                                     if sp["disabled"] != nil { sp["disabled"] = !enabled }
                                     setAt(&r, keyPath + [.key(name)], sp)
                                 }
                             },
                             onDelete: {
                                 mutate { r in removeAt(&r, keyPath + [.key(name)]) }
                             })
            }
        }
    }

}

struct MCPServerRow: View {
    @AppStorage("maskSecrets", store: AppSettings.defaults) private var maskSecrets = true
    let name: String
    let spec: Any?
    let editable: Bool
    var onToggleEnabled: (Bool) -> Void
    var onDelete: () -> Void

    private var dict: [String: Any] { spec as? [String: Any] ?? [:] }
    private var enabled: Bool {
        if let e = dict["enabled"] as? Bool { return e }
        if let d = dict["disabled"] as? Bool { return !d }
        return true
    }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: enabled ? "checkmark.circle" : "minus.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel(L(enabled ? "enabled" : "disabled"))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .medium))
                Text(Secrets.mcpEndpoint(dict, masking: maskSecrets))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if dict["enabled"] != nil || dict["disabled"] != nil {
                Toggle(L("Enable server %@", name), isOn: Binding(
                    get: { enabled },
                    set: { onToggleEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(!editable)
            }
            if editable {
                Button(action: onDelete) {
                    Label(L("Remove server %@", name), systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Permissions card

struct PermissionsCard: View {
    let keyPath: [Seg]
    let perms: [String: Any]
    let editable: Bool
    let mutate: ((inout [String: Any]) -> Void) -> Void
    @State private var newAllow = ""
    @State private var newDeny = ""

    var body: some View {
        Card {
            CardHeader(title: L("Permissions"), icon: "lock.shield")
            if let mode = perms["defaultMode"] as? String {
                HStack {
                    Text("defaultMode").font(.callout).foregroundStyle(.secondary)
                    Text(mode).font(.system(size: 13, design: .monospaced))
                }
            }
            StringListEditor(title: "allow", keyPath: keyPath + [.key("allow")],
                             values: perms["allow"] as? [Any] ?? [],
                             newValue: $newAllow, editable: editable, mutate: mutate)
            StringListEditor(title: "deny", keyPath: keyPath + [.key("deny")],
                             values: perms["deny"] as? [Any] ?? [],
                             newValue: $newDeny, editable: editable, mutate: mutate)
        }
    }
}

struct StringListEditor: View {
    @AppStorage("maskSecrets", store: AppSettings.defaults) private var maskSecrets = true
    let title: String
    let keyPath: [Seg]
    let values: [Any]
    @Binding var newValue: String
    let editable: Bool
    let mutate: ((inout [String: Any]) -> Void) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                HStack(spacing: 6) {
                    Text(Secrets.displayText(String(describing: v), path: pathLabel(keyPath), masking: maskSecrets))
                        .font(.system(size: 13, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    if editable {
                        Button {
                            mutate { r in removeAt(&r, keyPath + [.idx(i)]) }
                        } label: {
                            Image(systemName: "minus.circle").frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .accessibilityLabel(L("Remove rule %d from %@", i + 1, title))
                    }
                }
            }
            if editable {
                HStack(spacing: 6) {
                    TextField(L("Add rule…"), text: $newValue)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .onSubmit(add)
                    Button(action: add) {
                        Image(systemName: "plus.circle.fill").frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L("Add rule to %@", title))
                        .disabled(newValue.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func add() {
        let v = newValue.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        mutate { r in
            var arr = getAt(r, keyPath) as? [Any] ?? []
            arr.append(v)
            setAt(&r, keyPath, arr)
        }
        newValue = ""
    }
}

// MARK: - Hooks health card (read-only)

struct HooksCard: View {
    let hooks: [String: Any]

    private var events: [String] { hooks.keys.sorted() }

    var body: some View {
        Card {
            CardHeader(title: L("Hooks"), icon: "hook")
            ForEach(events, id: \.self) { event in
                VStack(alignment: .leading, spacing: 3) {
                    Text(event).font(.system(size: 13, weight: .semibold))
                    ForEach(Array(commands(for: event).enumerated()), id: \.offset) { _, cmd in
                        HookCommandRow(command: cmd)
                    }
                }
            }
        }
    }

    private func commands(for event: String) -> [String] {
        var out: [String] = []
        func walk(_ v: Any) {
            switch v {
            case let d as [String: Any]:
                for (k, val) in d {
                    if k == "command", let s = val as? String { out.append(s) }
                    else { walk(val) }
                }
            case let a as [Any]: a.forEach(walk)
            default: break
            }
        }
        walk(hooks[event] ?? [])
        return out
    }
}

struct HookCommandRow: View {
    @AppStorage("maskSecrets", store: AppSettings.defaults) private var maskSecrets = true
    let command: String

    private var missingPaths: [String] {
        Linter.referencedPaths(in: command)
            .filter { !FileManager.default.fileExists(atPath: $0) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(missingPaths.isEmpty ? Color.green : Color.red)
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            Text(Secrets.displayText(command, path: "command", masking: maskSecrets))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(missingPaths.isEmpty ? Color.primary : Color.red)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .help(missingPaths.isEmpty ? L("Command available") : L("Missing path: %@", Secrets.displayText(missingPaths.joined(separator: ", "), masking: maskSecrets)))
    }
}

// MARK: - Bool map card (plugins, features)

struct BoolMapCard: View {
    let title: String
    let icon: String
    let keyPath: [Seg]
    let map: [String: Any]
    let editable: Bool
    let mutate: ((inout [String: Any]) -> Void) -> Void

    private var boolKeys: [String] {
        map.keys.filter { isBool(map[$0]!) }.sorted()
    }

    var body: some View {
        Card {
            CardHeader(title: title, icon: icon)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(boolKeys, id: \.self) { k in
                    Toggle(k, isOn: Binding(
                        get: { (map[k] as? NSNumber)?.boolValue ?? false },
                        set: { v in mutate { r in setAt(&r, keyPath + [.key(k)], v) } }
                    ))
                    .font(.system(size: 13))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!editable)
                }
            }
        }
    }
}

// MARK: - String map card (env)

struct StringMapCard: View {
    @AppStorage("maskSecrets", store: AppSettings.defaults) private var maskSecrets = true
    let title: String
    let icon: String
    let keyPath: [Seg]
    let map: [String: Any]
    let editable: Bool
    let mutate: ((inout [String: Any]) -> Void) -> Void

    var body: some View {
        Card {
            CardHeader(title: title, icon: icon)
            ForEach(map.keys.sorted(), id: \.self) { k in
                VStack(alignment: .leading, spacing: 6) {
                    Text(k)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .frame(minWidth: 140, alignment: .leading)
                    let value = map[k] as? String ?? "\(map[k] ?? "")"
                    if maskSecrets && Secrets.isSensitive(value, path: pathLabel(keyPath + [.key(k)])) {
                        SecretValueRow(value: value, editable: editable) { v in
                            mutate { r in setAt(&r, keyPath + [.key(k)], v) }
                        }
                    } else {
                        TextField(k, text: Binding(
                            get: { value },
                            set: { v in mutate { r in setAt(&r, keyPath + [.key(k)], v) } }
                        ))
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .disabled(!editable)
                    }
                }
            }
        }
    }
}

// MARK: - Generic inspector

/// What a row needs to add documented keys below an existing object.
struct AddSettingContext {
    let catalog: [SettingCatalogEntry]
    let isDefined: ([String]) -> Bool
    let add: (_ path: [String], _ entry: SettingCatalogEntry, _ value: Any) -> String?
}

struct GenericInspector: View {
    let filePath: String
    let root: [String: Any]
    let editable: Bool
    var excludedKeys: Set<String> = []
    var excludedPaths: Set<[String]> = []
    let mutate: ((inout [String: Any]) -> Void) -> Void
    var addContext: AddSettingContext? = nil

    var body: some View {
        // Top-level keys a special card above already displays (MCP servers,
        // permissions, hooks, plugins, env) are left out here so the same
        // data isn't shown twice; nothing left means no card at all.
        Group {
            if !nodes.isEmpty {
                Card {
                    CardHeader(title: L("All keys"), icon: "list.bullet.indent")
                    OutlineGroup(nodes, children: \.children) { node in
                        NodeRow(node: node, filePath: filePath, editable: editable, mutate: mutate,
                                addContext: addContext)
                    }
                }
            }
        }
    }

    private var nodes: [TreeNode] {
        root.keys.sorted().filter { !excludedKeys.contains($0) }.compactMap { k in
            pruned(TreeNode.build(key: k, value: root[k] ?? NSNull(), segs: [.key(k)]))
        }
    }

    private func pruned(_ node: TreeNode) -> TreeNode? {
        let keys = node.segs.compactMap { if case .key(let key) = $0 { return key }; return nil }
        if keys.count == node.segs.count && excludedPaths.contains(keys) { return nil }
        guard let children = node.children, !children.isEmpty else { return node }
        let kept = children.compactMap(pruned)
        guard !kept.isEmpty else { return nil }
        var copy = node
        copy.children = kept
        return copy
    }
}

struct TreeNode: Identifiable {
    var id: String { pathLabel(segs) }
    let label: String
    let segs: [Seg]
    let value: Any
    var children: [TreeNode]?

    static func build(key: String, value: Any, segs: [Seg]) -> TreeNode {
        if let d = value as? [String: Any] {
            let kids = d.keys.sorted().map {
                TreeNode.build(key: $0, value: d[$0] ?? NSNull(), segs: segs + [.key($0)])
            }
            return TreeNode(label: key, segs: segs, value: value, children: kids)
        }
        // Lists of text are edited in place as one row (StringListField).
        if let a = value as? [Any], isStringList(a) {
            return TreeNode(label: key, segs: segs, value: value, children: nil)
        }
        if let a = value as? [Any] {
            let kids = a.enumerated().map {
                TreeNode.build(key: "[\($0.offset)]", value: $0.element, segs: segs + [.idx($0.offset)])
            }
            return TreeNode(label: key, segs: segs, value: value, children: kids)
        }
        return TreeNode(label: key, segs: segs, value: value, children: nil)
    }
}

struct NodeRow: View {
    @AppStorage("maskSecrets", store: AppSettings.defaults) private var maskSecrets = true
    let node: TreeNode
    let filePath: String
    let editable: Bool
    let mutate: ((inout [String: Any]) -> Void) -> Void
    var addContext: AddSettingContext? = nil
    @Environment(\.layerNotes) private var layerNotes
    @State private var draft: String = ""
    @State private var numberProblem: String?

    private var keyPath: [String]? {
        let keys = node.segs.compactMap { if case .key(let k) = $0 { return k }; return nil }
        return keys.count == node.segs.count ? keys : nil
    }

    private var doc: DocsCatalog.KeyDoc? {
        DocsCatalog.keyDoc(filePath: filePath, keyPath: node.segs.compactMap {
            if case .key(let k) = $0 { return k }; return nil
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(Secrets.displayText(node.label, masking: maskSecrets))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let doc {
                    KeyDocButton(doc: doc)
                    DefaultBadge(spec: doc.spec)
                }
                Spacer(minLength: 0)
                if let addContext, let keyPath, node.value is [String: Any] {
                    AddChildSettingButton(prefix: keyPath, catalog: addContext.catalog,
                                          isDefined: addContext.isDefined, add: addContext.add)
                }
                if editable, let doc, doc.spec != nil, keyPath != nil {
                    ResetToDefaultButton(spec: doc.spec) {
                        mutate { r in removeAt(&r, node.segs) }
                    }
                }
            }
            if let doc {
                Text(doc.attributedSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let keyPath, let note = layerNotes[keyPath.joined(separator: ".")] {
                LayerNoteView(note: note)
            }
            valueView
                .padding(.top, 4)
        }
        .padding(.vertical, 5)
        .onAppear { draft = scalarText(node.value) }
    }

    @ViewBuilder
    private var valueView: some View {
        let v = node.value
        if maskSecrets && Secrets.isSensitive(v, path: pathLabel(node.segs)), !(v is String) {
            Text(Secrets.maskedValue).font(.system(size: 13, design: .monospaced))
        } else if isBool(v) {
            Toggle(Secrets.displayText(pathLabel(node.segs), masking: maskSecrets), isOn: Binding(
                get: { (v as? NSNumber)?.boolValue ?? false },
                set: { n in mutate { r in setAt(&r, node.segs, n) } }
            ))
            .toggleStyle(.switch).controlSize(.small).labelsHidden()
            .disabled(!editable)
        } else if let list = v as? [Any], isStringList(list) {
            StringListField(label: pathLabel(node.segs), values: list.compactMap { $0 as? String },
                            doc: doc, editable: editable) { updated in
                mutate { r in setAt(&r, node.segs, updated) }
            }
        } else if v is NSNull {
            Text("null").font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
        } else if let s = v as? String {
            if maskSecrets && Secrets.isSensitive(s, path: pathLabel(node.segs)) {
                SecretValueRow(value: s, editable: editable) { n in
                    mutate { r in setAt(&r, node.segs, n) }
                }
            } else {
                SettingChoiceField(label: Secrets.displayText(pathLabel(node.segs), masking: maskSecrets),
                                   doc: doc,
                                   text: Binding(
                                       get: { s },
                                       set: { n in mutate { r in setAt(&r, node.segs, n) } }
                                   ))
                .disabled(!editable)
            }
        } else if let n = v as? NSNumber {
            TextField(Secrets.displayText(pathLabel(node.segs), masking: maskSecrets), text: Binding(
                get: { n.stringValue },
                set: { txt in
                    guard let v = NodeRow.parseNumber(txt) else { return }
                    if let problem = doc?.spec?.rangeProblem((v as? NSNumber)?.doubleValue ?? 0) {
                        numberProblem = problem
                        return
                    }
                    numberProblem = nil
                    mutate { r in setAt(&r, node.segs, v) }
                }
            ))
            .font(.system(size: 13, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 140)
            .disabled(!editable)
            if let numberProblem {
                Text(numberProblem).font(.caption).foregroundStyle(.red)
            }
        } else {
            Text(DiffEngine.display(v))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    /// Int only when the value is finite, integral and in Int64 range;
    /// everything else stays a Double. `Int(d)` would trap on "1e300"/"inf".
    static func parseNumber(_ txt: String) -> Any? {
        if let integer = Int(txt) { return integer }
        guard let d = Double(txt), d.isFinite else { return nil }
        return d
    }

    private func scalarText(_ v: Any) -> String {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }
}

/// Masked value with reveal + copy + edit.
struct SecretValueRow: View {
    let value: String
    let editable: Bool
    let onChange: @MainActor (String) -> Void
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 6) {
            if revealed {
                TextField(L("Secret value"), text: Binding(get: { value }, set: { n in
                    MainActor.assumeIsolated { onChange(n) }
                }))
                    .font(.system(size: 13, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .disabled(!editable)
            } else {
                Text("••••••••")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Button { revealed.toggle() } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .help(revealed ? L("Hide value") : L("Reveal value"))
            .accessibilityLabel(revealed ? L("Hide value") : L("Reveal value"))
            .accessibilityIdentifier("reveal-secret")
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .help(L("Copy value"))
            .accessibilityLabel(L("Copy value"))
        }
    }
}
