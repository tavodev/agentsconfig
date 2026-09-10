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

    private var canWriteStructured: Bool {
        format == .json || format == .jsonc || format == .toml
    }

    private var editable: Bool { !readOnly && canWriteStructured && root != nil }

    private var root: [String: Any]? {
        Parsers.parse(store.text(for: path), format: format).tree as? [String: Any]
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
                if let err = doc?.parseError {
                    Card {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Text(L("Fix the error in the Source tab to enable the structured view."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else if root == nil {
                    Card {
                        Label(L("This file is not a structured JSON/TOML object."),
                              systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if readOnly {
                        Card {
                            Label(L("Read-only structured view — edit in the Source tab (%@ format).", format.badge),
                                  systemImage: "lock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if format == .toml {
                        Card {
                            Label(L("Structured editing rewrites the TOML — comments and formatting are normalized on save."),
                                  systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    specialCards
                    GenericInspector(filePath: path, root: root ?? [:],
                                     editable: editable, mutate: mutate)
                }
            }
            .padding(14)
        }
    }

    // MARK: special sections

    @ViewBuilder
    private var specialCards: some View {
        if let r = root {
            if let mcpKey = ["mcpServers", "mcp", "mcp_servers"].first(where: { r[$0] is [String: Any] }),
               let servers = r[mcpKey] as? [String: Any] {
                MCPCard(keyPath: [Seg.key(mcpKey)], servers: servers,
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
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )
    }
}

struct CardHeader: View {
    let title: String
    let icon: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(title).font(.system(size: 12.5, weight: .semibold))
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
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help(doc.localizedSummary)
        .popover(isPresented: $show, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(doc.localizedSummary)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if let values = doc.localizedValues, !values.isEmpty {
                    Divider()
                    ForEach(values.keys.sorted(), id: \.self) { v in
                        HStack(alignment: .top, spacing: 8) {
                            Text(v)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .frame(minWidth: 110, alignment: .leading)
                            Text(values[v] ?? "")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let def = doc.defaultValue {
                    Divider()
                    Text(L("Default: %@", def))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: 340)
        }
    }
}

// MARK: - MCP servers card

struct MCPCard: View {
    let keyPath: [Seg]
    let servers: [String: Any]
    let editable: Bool
    let mutate: ((inout [String: Any]) -> Void) -> Void
    @State private var showAdd = false
    @State private var newName = ""
    @State private var newCommand = ""
    @State private var newArgs = ""
    @State private var newURL = ""

    private var names: [String] { servers.keys.sorted() }

    var body: some View {
        Card {
            HStack {
                CardHeader(title: L("MCP servers"), icon: "network")
                if editable {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showAdd) { addForm }
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

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nuevo servidor MCP").font(.headline)
            TextField(L("Name"), text: $newName)
            TextField(L("Command (e.g. npx)"), text: $newCommand)
            TextField(L("Args (space-separated)"), text: $newArgs)
            TextField(L("or remote URL (http…)"), text: $newURL)
            HStack {
                Spacer()
                Button(L("Add")) {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    mutate { r in
                        var spec: [String: Any] = [:]
                        if !newURL.isEmpty {
                            spec["url"] = newURL
                        } else {
                            spec["command"] = newCommand
                            if !newArgs.isEmpty {
                                spec["args"] = newArgs.split(separator: " ").map(String.init)
                            }
                        }
                        setAt(&r, keyPath + [.key(name)], spec)
                    }
                    newName = ""; newCommand = ""; newArgs = ""; newURL = ""
                    showAdd = false
                }
                .disabled(newName.isEmpty || (newCommand.isEmpty && newURL.isEmpty))
            }
        }
        .padding(12)
        .frame(width: 320)
        .textFieldStyle(.roundedBorder)
    }
}

struct MCPServerRow: View {
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
    private var summary: String {
        if let url = dict["url"] as? String ?? dict["httpUrl"] as? String ?? dict["serverUrl"] as? String {
            return url
        }
        let cmd = dict["command"] as? String ?? ""
        let args = (dict["args"] as? [Any])?.compactMap { "\($0)" }.joined(separator: " ") ?? ""
        return [cmd, args].filter { !$0.isEmpty }.joined(separator: " ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(enabled ? Color.green : Color.gray)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12, weight: .medium))
                Text(summary)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if dict["enabled"] != nil || dict["disabled"] != nil {
                Toggle("", isOn: Binding(
                    get: { enabled },
                    set: { onToggleEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(!editable)
            }
            if editable {
                Button(action: onDelete) {
                    Image(systemName: "trash")
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
                    Text("defaultMode").font(.caption).foregroundStyle(.secondary)
                    Text(mode).font(.system(size: 11, design: .monospaced))
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
    let title: String
    let keyPath: [Seg]
    let values: [Any]
    @Binding var newValue: String
    let editable: Bool
    let mutate: ((inout [String: Any]) -> Void) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                HStack(spacing: 6) {
                    Text(String(describing: v))
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    if editable {
                        Button {
                            mutate { r in removeAt(&r, keyPath + [.idx(i)]) }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
            if editable {
                HStack(spacing: 6) {
                    TextField(L("Add rule…"), text: $newValue)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit(add)
                    Button(action: add) { Image(systemName: "plus.circle.fill") }
                        .buttonStyle(.plain)
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
                    Text(event).font(.system(size: 11, weight: .semibold))
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
            Text(command)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(missingPaths.isEmpty ? Color.primary : Color.red)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .help(missingPaths.isEmpty ? L("Command available") : L("Missing path: %@", missingPaths.joined(separator: ", ")))
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
                    .font(.system(size: 11))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!editable)
                }
            }
        }
    }
}

// MARK: - String map card (env)

struct StringMapCard: View {
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
                HStack(spacing: 8) {
                    Text(k)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .frame(minWidth: 140, alignment: .leading)
                    TextField(L("value"), text: Binding(
                        get: { map[k] as? String ?? "\(map[k] ?? "")" },
                        set: { v in mutate { r in setAt(&r, keyPath + [.key(k)], v) } }
                    ))
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!editable)
                }
            }
        }
    }
}

// MARK: - Generic inspector

struct GenericInspector: View {
    let filePath: String
    let root: [String: Any]
    let editable: Bool
    let mutate: ((inout [String: Any]) -> Void) -> Void

    var body: some View {
        Card {
            CardHeader(title: L("All keys"), icon: "list.bullet.indent")
            OutlineGroup(nodes, children: \.children) { node in
                NodeRow(node: node, filePath: filePath, editable: editable, mutate: mutate)
            }
        }
    }

    private var nodes: [TreeNode] {
        root.keys.sorted().map { k in
            TreeNode.build(key: k, value: root[k] ?? NSNull(), segs: [.key(k)])
        }
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
    let node: TreeNode
    let filePath: String
    let editable: Bool
    let mutate: ((inout [String: Any]) -> Void) -> Void
    @State private var draft: String = ""

    private var doc: DocsCatalog.KeyDoc? {
        DocsCatalog.keyDoc(filePath: filePath, keyPath: node.segs.compactMap {
            if case .key(let k) = $0 { return k }; return nil
        })
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(node.label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            if let doc {
                KeyDocButton(doc: doc)
            }
            Spacer()
            valueView
        }
        .onAppear { draft = scalarText(node.value) }
    }

    @ViewBuilder
    private var valueView: some View {
        let v = node.value
        if isBool(v) {
            Toggle("", isOn: Binding(
                get: { (v as? NSNumber)?.boolValue ?? false },
                set: { n in mutate { r in setAt(&r, node.segs, n) } }
            ))
            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            .disabled(!editable)
        } else if v is NSNull {
            Text("null").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
        } else if let s = v as? String {
            if AppSettings.maskSecrets && Secrets.isSecretKey(node.label) {
                SecretValueRow(value: s, editable: editable) { n in
                    mutate { r in setAt(&r, node.segs, n) }
                }
            } else {
                TextField("", text: Binding(
                    get: { s },
                    set: { n in mutate { r in setAt(&r, node.segs, n) } }
                ))
                .font(.system(size: 11, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 380)
                .disabled(!editable)
            }
        } else if let n = v as? NSNumber {
            TextField("", text: Binding(
                get: { n.stringValue },
                set: { txt in
                    if let d = Double(txt) {
                        mutate { r in setAt(&r, node.segs, txt.contains(".") ? d : Int(d)) }
                    }
                }
            ))
            .font(.system(size: 11, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 140)
            .disabled(!editable)
        } else {
            Text(DiffEngine.display(v))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
        }
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
                TextField("", text: Binding(get: { value }, set: { n in
                    MainActor.assumeIsolated { onChange(n) }
                }))
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .disabled(!editable)
            } else {
                Text("••••••••")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Button { revealed.toggle() } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }
}
