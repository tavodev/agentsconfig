import Foundation

/// What the official reference says a setting accepts. Generated into
/// `DocsCatalogReference.swift` by `scripts/generate-docs-reference.py`.
struct SettingSpec: Sendable, Equatable {
    enum Kind: String, Sendable { case bool, string, integer, number, array, object, other }
    /// Which settings file a key may live in. `globalConfig` is
    /// `~/.claude.json`, never a settings file.
    enum Scope: String, Sendable { case user, project, local, managed, globalConfig }

    let kind: Kind
    /// Known string values. With `allowsCustom` they are only suggestions.
    let options: [String]
    let allowsCustom: Bool
    /// JSON literal of the documented default (`true`, `"auto"`, `30`), or
    /// nil when the reference documents none (usually "unset").
    let defaultJSON: String?
    let scopes: [Scope]
    let topic: String
    let deprecated: Bool
    let min: Double?
    let max: Double?

    init(kind: Kind, options: [String], allowsCustom: Bool, defaultJSON: String?,
         scopes: [Scope], topic: String, deprecated: Bool, min: Double?, max: Double?) {
        self.kind = kind; self.options = options; self.allowsCustom = allowsCustom
        self.defaultJSON = defaultJSON; self.scopes = scopes; self.topic = topic
        self.deprecated = deprecated; self.min = min; self.max = max
    }

    /// A closed list: the picker offers only these values.
    var isEnum: Bool { kind == .string && !options.isEmpty && !allowsCustom }

    var defaultValue: Any? {
        guard let defaultJSON, let data = defaultJSON.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Value written when the user adds the key: the documented default,
    /// else the first option or an empty value of the right type.
    var initialValue: Any {
        if let value = defaultValue { return value }
        switch kind {
        case .bool: return false
        case .string: return options.first ?? ""
        case .integer: return Int(min ?? 0)
        case .number: return min.map { $0 == $0.rounded() ? Int($0) as Any : $0 as Any } ?? 0
        case .array: return [Any]()
        case .object, .other: return [String: Any]()
        }
    }

    /// Range check for numeric input; nil means valid.
    @MainActor func rangeProblem(_ value: Double) -> String? {
        if let min, value < min { return L("Minimum: %@", Self.format(min)) }
        if let max, value > max { return L("Maximum: %@", Self.format(max)) }
        if kind == .integer, value != value.rounded() { return L("Enter a whole number.") }
        return nil
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }
}

/// One generated reference row: summaries plus the value spec.
struct ReferenceEntry: Sendable {
    let en: String
    let es: String
    let spec: SettingSpec
}

/// A key the "Add setting" sheet can offer for one file.
struct SettingCatalogEntry: Identifiable {
    /// Dotted reference key; `<name>` segments must be filled in by the user.
    let key: String
    let doc: DocsCatalog.KeyDoc
    let spec: SettingSpec
    var id: String { key }
    var segments: [String] { key.split(separator: ".").map(String.init) }
    var placeholders: [String] { segments.filter(Self.isPlaceholder) }

    static func isPlaceholder(_ segment: String) -> Bool {
        segment.hasPrefix("<") && segment.hasSuffix(">")
    }

    /// Replaces each `<name>` segment, in order, with the given values.
    func resolvedPath(_ values: [String]) -> [String] {
        var remaining = values[...]
        return segments.map { Self.isPlaceholder($0) ? (remaining.popFirst() ?? $0) : $0 }
    }
}

extension DocsCatalog {
    /// Settings scope of a file the app can edit, from its location.
    static func settingsScope(filePath: String) -> SettingSpec.Scope? {
        func isUser(_ agentID: String, _ names: [String], _ relative: [String]) -> Bool {
            let root = AgentCatalog.root(for: agentID) as NSString
            return names.contains { filePath == root.appendingPathComponent($0) }
                || relative.contains { ConfigFileContext.isUserFile(filePath, relativePath: $0) }
        }
        switch ConfigFileContext.settingsKind(for: filePath) {
        case .claude:
            if ConfigFileContext.matches(filePath, suffix: ".claude/settings.local.json") { return .local }
            return isUser("claude-code", ["settings.json"], [".claude/settings.json"]) ? .user : .project
        case .codex:
            return isUser("codex", ["config.toml"], [".codex/config.toml"]) ? .user : .project
        case .gemini:
            return isUser("gemini-cli", ["settings.json"], [".gemini/settings.json"]) ? .user : .project
        case .opencode:
            return isUser("opencode", ["opencode.json", "opencode.jsonc"],
                          [".config/opencode/opencode.json", ".config/opencode/opencode.jsonc"]) ? .user : .project
        case nil:
            return nil
        }
    }

    /// Generated reference table for a settings file, if any.
    static func referenceTable(filePath: String) -> [String: ReferenceEntry]? {
        switch ConfigFileContext.settingsKind(for: filePath) {
        case .claude: claudeReference
        case .codex: codexReference
        case .gemini: geminiReference
        case .opencode: opencodeReference
        case nil: nil
        }
    }

    /// Every documented key that may be added to this file, sorted by topic
    /// and key: the official reference plus curated sub-fields that carry a
    /// spec. Nil when no reference covers the file. Deprecated keys, keys for
    /// other scopes and array-of-table members are left out.
    static func settingsCatalog(filePath: String) -> [SettingCatalogEntry]? {
        guard let table = referenceTable(filePath: filePath),
              let scope = settingsScope(filePath: filePath) else { return nil }
        var specs = table.mapValues(\.spec)
        for (key, doc) in curatedKeys(filePath: filePath) where specs[key] == nil {
            if let spec = doc.spec { specs[key] = spec }
        }
        return specs.compactMap { key, spec -> SettingCatalogEntry? in
            guard spec.scopes.contains(scope), !spec.deprecated, spec.kind != .other,
                  !key.contains("[]") else { return nil }
            let path = key.split(separator: ".").map(String.init)
            guard var doc = keyDoc(filePath: filePath, keyPath: path) else { return nil }
            if doc.spec == nil { doc.spec = spec }
            return SettingCatalogEntry(key: key, doc: doc, spec: spec)
        }
        .sorted { ($0.spec.topic, $0.key) < ($1.spec.topic, $1.key) }
    }
}
