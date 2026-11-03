import Foundation

/// Configuration homes created by Orca, observed on disk on 2026-11-03.
///
/// Orca launches Claude Code and Codex with their own configuration folders
/// instead of `~/.claude` / `~/.codex`:
/// - `claude-profiles/<account>/home` — one Claude Code config dir per Orca
///   account (`settings.json`, `CLAUDE.md`, `.claude.json`, hooks…);
///   `claude-profiles/selected-host` names the one Orca has selected.
/// - `codex-accounts/<account>/home` — one Codex home per account
///   (`.orca-managed-home` marker, `config.toml`, `hooks.json`, rules…).
/// - `codex-runtime-home/home` — a shared Codex runtime home.
///
/// Folders and files Orca links back to `~/.claude` / `~/.codex` (skills,
/// plugins, `AGENTS.md`) already belong to the regular agent and are left
/// out so each file keeps a single document, buffer and history identity.
/// Which home a given terminal uses is not inferred.
enum OrcaIntegration {
    static let idPrefix = ":orca:"
    /// Orca's data folder (`dataRootResolution`: Settings, `ORCA_USER_DATA_PATH`
    /// outside isolated runs, or `~/Library/Application Support/orca`).
    static var root: String { dataRootResolution.path }

    static var isEnabled: Bool {
        AppSettings.defaults.object(forKey: "orcaIntegration") as? Bool ?? true
    }

    enum Kind { case claude, codex }

    struct Home {
        var kind: Kind
        var path: String
        /// Account folder name, or nil for the shared Codex runtime home.
        var account: String?
        var selected: Bool
    }

    /// Orca homes present on disk, in a stable order.
    static func homes() -> [Home] {
        guard isEnabled else { return [] }
        let fm = FileManager.default
        let root = root
        func subfolders(_ relative: String) -> [String] {
            let base = (root as NSString).appendingPathComponent(relative)
            return ((try? fm.contentsOfDirectory(atPath: base)) ?? []).filter { name in
                var isDir: ObjCBool = false
                return !name.hasPrefix(".") && fm.fileExists(atPath: base + "/" + name + "/home", isDirectory: &isDir) && isDir.boolValue
            }.sorted()
        }
        var out: [Home] = subfolders("claude-profiles").map { account in
            let path = root + "/claude-profiles/" + account + "/home"
            return Home(kind: .claude, path: path, account: account, selected: isSelectedClaudeHome(path, root: root))
        }
        out += subfolders("codex-accounts").map {
            Home(kind: .codex, path: root + "/codex-accounts/" + $0 + "/home", account: $0, selected: false)
        }
        let runtime = root + "/codex-runtime-home/home"
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: runtime, isDirectory: &isDir), isDir.boolValue {
            out.append(Home(kind: .codex, path: runtime, account: nil, selected: false))
        }
        return out
    }

    /// Agent definitions for every Orca home, derived from the regular
    /// Claude Code / Codex definitions (before custom roots are applied).
    static func definitions(claude: AgentDefinition, codex: AgentDefinition) -> [AgentDefinition] {
        homes().map { home in
            let template = home.kind == .claude ? claude : codex
            var def = template
            let label = home.account.map { String($0.prefix(8)) } ?? "runtime"
            def.id = template.id + idPrefix + (home.account ?? "runtime")
            def.name = template.name + " · Orca " + label
            def.detectionPaths = [home.path]
            def.localSources = []
            def.mcpDestinationPaths = []
            def.sources = template.sources.compactMap { source in
                guard let path = relocate(source.path, kind: home.kind, home: home.path),
                      !isLinkedOutside(path, home: home.path) else { return nil }
                if home.kind == .codex, source.role == .state { return nil }  // credentials
                var source = source
                source.path = path
                return source
            }
            def.notes = notes(for: home)
            return def
        }
    }

    /// `~/.claude/x` → `<home>/x`; `~/.claude.json` → `<home>/.claude.json`.
    /// Shared sources outside the agent home (`~/.agents/skills`) → nil.
    private static func relocate(_ path: String, kind: Kind, home: String) -> String? {
        let base = kind == .claude ? "~/.claude" : "~/.codex"
        if kind == .claude, path == "~/.claude.json" { return home + "/.claude.json" }
        if path == base { return home }
        if path.hasPrefix(base + "/") { return home + path.dropFirst(base.count) }
        return nil
    }

    /// True when the path, or one of its parents inside the home, is a link
    /// whose target leaves the home (Orca links skills/plugins/AGENTS.md).
    private static func isLinkedOutside(_ path: String, home: String) -> Bool {
        guard let canonicalHome = AppPaths.canonicalPath(home),
              let target = AppPaths.canonicalPath(path) else { return true }
        return target != canonicalHome && !target.hasPrefix(canonicalHome + "/")
    }

    private static func notes(for home: Home) -> String {
        switch (home.kind, home.account, home.selected) {
        case (.claude, _, true):
            return "Claude Code configuration folder managed by Orca for one account — the one Orca has selected. Folders linked to ~/.claude are listed under Claude Code. Not an MCP destination; layer analysis covers ~/.claude only."
        case (.claude, _, false):
            return "Claude Code configuration folder managed by Orca for one account. Folders linked to ~/.claude are listed under Claude Code. Not an MCP destination; layer analysis covers ~/.claude only."
        case (.codex, nil, _):
            return "Shared Codex runtime home managed by Orca. Orca keeps a settings baseline and may reconcile some keys. Not an MCP destination; layer analysis covers ~/.codex only."
        case (.codex, _, _):
            return "Codex home managed by Orca for one account. Orca keeps a settings baseline and may reconcile some keys; files linked to ~/.codex are listed under Codex. Not an MCP destination; layer analysis covers ~/.codex only."
        }
    }

    /// The Orca home containing `path`, if any. Parsed from the path alone
    /// (no disk access): documentation lookups call this per key row.
    static func home(containing path: String) -> Home? {
        let root = root
        guard isEnabled, path.hasPrefix(root + "/") else { return nil }
        let parts = path.dropFirst(root.count + 1).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 2, parts[0] == "codex-runtime-home", parts[1] == "home" {
            return Home(kind: .codex, path: root + "/codex-runtime-home/home", account: nil, selected: false)
        }
        guard parts.count > 3, parts[2] == "home", !parts[1].isEmpty, !parts[1].hasPrefix("."),
              let kind: Kind = parts[0] == "claude-profiles" ? .claude : parts[0] == "codex-accounts" ? .codex : nil
        else { return nil }
        return Home(kind: kind, path: root + "/" + parts[0] + "/" + parts[1] + "/home", account: parts[1], selected: false)
    }

    /// The regular-home path an Orca file corresponds to (for documentation
    /// and settings kind), e.g. `<orca home>/settings.json` → `~/.claude/settings.json`.
    static func equivalentPath(for path: String) -> String? {
        guard let home = home(containing: path) else { return nil }
        let relative = String(path.dropFirst(home.path.count + 1))
        if home.kind == .claude, relative == ".claude.json" { return AppPaths.home + "/.claude.json" }
        return AppPaths.home + (home.kind == .claude ? "/.claude/" : "/.codex/") + relative
    }
}
