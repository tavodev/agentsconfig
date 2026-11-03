import Foundation

/// What Orca does with each file of its homes, verified against Orca 1.4.246
/// (`claude-profile-provisioning.ts`, `codex-config-mirror.ts`,
/// `codex-managed-home-rules.ts`, `hook-settings.ts`).
///
/// Before each launch Orca rebuilds a Claude profile from the Claude Code
/// config folder (copies loose files, rewrites `CLAUDE.md` as an import, copies
/// `settings.json` and adds its status hooks, merges shared keys of the global
/// state into `.claude.json`) and merges the Codex `config.toml` into each
/// Codex home, keeping only what belongs to that home. Editing those copies
/// here would be lost or would race Orca, so they are read-only; the
/// relation, the source path and the sync status are pure and reusable.
extension OrcaIntegration {
    /// How an Orca-home file relates to the regular Claude Code / Codex folder.
    enum Relation: Equatable, Sendable {
        /// Overwritten from its source on each launch (`settings.json` keeps
        /// Orca's status hooks on top).
        case mirroredCopy
        /// Claude profile `CLAUDE.md`: always rewritten to `@~/.claude/CLAUDE.md`.
        case importStub
        /// Source keys merged in, with parts that belong to this home
        /// (`.claude.json`, Codex `config.toml`).
        case mergedState
        /// No source: the file belongs to this home only.
        case accountOwned
    }

    enum SyncStatus: Equatable, Sendable {
        case synced
        /// The source changed after the copy; Orca refreshes it on its next launch.
        case pending
        /// The copy differs and the source is not newer.
        case differs
        case sourceMissing
        /// Differences Orca may explain (promoted keys, rewritten paths,
        /// account-only state) cannot be told apart from the files alone.
        case undetermined
        case notApplicable
    }

    /// Text and modification date of one side of the comparison; `text == nil`
    /// means the file does not exist.
    struct FileState: Sendable {
        var text: String?
        var modified: Date?
    }

    static let claudeMemoryImport = "@~/.claude/CLAUDE.md\n"
    static let codexGlobalRulePrefix = "_orca-global-"

    /// Claude Code folder Orca copies from. Orca uses `CLAUDE_CONFIG_DIR` or
    /// `~/.claude`; the root chosen in Settings stands for that variable.
    static var claudeSourceRoot: String { AgentCatalog.root(for: "claude-code") }
    /// Codex folder Orca mirrors (`~/.codex` unless another root is chosen).
    static var codexSourceRoot: String { AgentCatalog.root(for: "codex") }

    /// Relation of `path` to its source, or nil when it is not in an Orca home.
    static func relation(for path: String) -> Relation? {
        guard let home = home(containing: path) else { return nil }
        let relative = String(path.dropFirst(home.path.count + 1))
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch home.kind {
        case .claude:
            guard parts.count == 1 else { return .accountOwned }
            switch relative {
            case "settings.json": return .mirroredCopy
            case "CLAUDE.md": return importsClaudeMemory ? .importStub : .mirroredCopy
            case ".claude.json": return .mergedState
            default: return isSharedClaudeEntry(relative) ? .mirroredCopy : .accountOwned
            }
        case .codex:
            if relative == "config.toml" { return .mergedState }
            if relative == "AGENTS.md" { return .mirroredCopy }  // only listed when Orca had to copy it
            if parts.count == 2, parts[0] == "rules", parts[1].hasPrefix(codexGlobalRulePrefix),
               parts[1].count > codexGlobalRulePrefix.count, parts[1].hasSuffix(".rules") {
                return .mirroredCopy
            }
            return .accountOwned
        }
    }

    /// The Claude Code / Codex file Orca regenerates `path` from, or nil for
    /// account-owned files and paths outside Orca homes.
    static func sourcePath(for path: String) -> String? {
        guard let relation = relation(for: path), relation != .accountOwned,
              let home = home(containing: path) else { return nil }
        let relative = String(path.dropFirst(home.path.count + 1))
        switch home.kind {
        case .claude:
            let root = claudeSourceRoot
            if relative == ".claude.json" {
                // Orca reads the state next to CLAUDE_CONFIG_DIR, or ~/.claude.json.
                return isDefaultClaudeRoot ? AppPaths.home + "/.claude.json" : root + "/.claude.json"
            }
            return root + "/" + relative
        case .codex:
            let root = codexSourceRoot
            if relative.hasPrefix("rules/" + codexGlobalRulePrefix) {
                return root + "/rules/" + relative.dropFirst(("rules/" + codexGlobalRulePrefix).count)
            }
            return root + "/" + relative
        }
    }

    /// Static, localizable explanation for a regenerated file (nil when the
    /// file belongs to the home). No paths: notes are translated by exact string.
    static func note(for path: String) -> String? {
        guard let relation = relation(for: path), let home = home(containing: path) else { return nil }
        let name = (path as NSString).lastPathComponent
        switch (relation, home.kind) {
        case (.accountOwned, _): return nil
        case (.importStub, _):
            return "Orca rewrites this file before each launch so it only imports the global CLAUDE.md. Edit the original; read-only here."
        case (.mirroredCopy, .claude) where name == "settings.json":
            return "Copy of the Claude Code user settings that Orca refreshes before each launch and extends with its own status hooks. Edit the original; read-only here."
        case (.mirroredCopy, .claude):
            return "Copy of the matching file in the Claude Code configuration folder; Orca overwrites it before each launch. Edit the original; read-only here."
        case (.mirroredCopy, .codex):
            return "Copy of the matching file in the Codex configuration folder; Orca refreshes it before each launch. Edit the original; read-only here."
        case (.mergedState, .claude):
            return "Orca merges the shared keys of the global Claude Code state (MCP servers, projects…) into this file before each launch; account keys stay here. Read-only to avoid racing Orca."
        case (.mergedState, .codex):
            return "Orca merges the Codex config into this file before each launch, keeping only this home's project and hook trust, own MCP servers and daemon guard. Model, reasoning effort, approval policy, sandbox mode and some TUI keys changed here are copied back to the Codex config. Edit the original; read-only here."
        }
    }

    /// Marks regenerated files read-only with their explanation.
    static func annotate(_ file: TrackedFile) -> TrackedFile {
        guard let note = note(for: file.path) else { return file }
        var file = file
        file.readOnly = true
        file.note = note
        return file
    }

    // MARK: - Sync status

    /// Reads the copy and its source from disk and compares them.
    static func syncStatus(for path: String) -> SyncStatus {
        guard let relation = relation(for: path), let home = home(containing: path) else { return .notApplicable }
        guard relation != .accountOwned, let source = sourcePath(for: path) else { return .notApplicable }
        return syncStatus(relation: relation, kind: home.kind, fileName: (path as NSString).lastPathComponent,
                          copy: readState(path), source: readState(source))
    }

    /// Pure comparison of a copy with its source.
    static func syncStatus(relation: Relation, kind: Kind, fileName: String,
                           copy: FileState, source: FileState) -> SyncStatus {
        if relation == .accountOwned { return .notApplicable }
        if relation == .importStub {
            guard let text = copy.text else { return source.text == nil ? .notApplicable : .pending }
            if source.text == nil { return .sourceMissing }
            return text == claudeMemoryImport ? .synced : .differs
        }
        guard let sourceText = source.text else { return copy.text == nil ? .notApplicable : .sourceMissing }
        guard let copyText = copy.text else { return .pending }
        let sourceIsNewer: Bool = {
            guard let s = source.modified, let c = copy.modified else { return false }
            return s > c
        }()
        let equal: Bool?
        switch (relation, kind) {
        case (.mirroredCopy, .claude) where fileName == "settings.json":
            equal = settingsMatch(copy: copyText, source: sourceText) ?? (copyText == sourceText)
        case (.mirroredCopy, _):
            equal = copyText == sourceText
        case (.mergedState, .claude):
            equal = claudeStateMatches(copy: copyText, source: sourceText)
        case (.mergedState, .codex):
            equal = codexConfigMatches(copy: copyText, source: sourceText)
        default:
            equal = nil
        }
        switch equal {
        case true?: return .synced
        case _ where sourceIsNewer: return .pending
        case false? where relation == .mirroredCopy: return .differs
        default: return .undetermined
        }
    }

    private static func readState(_ path: String) -> FileState {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard attributes != nil, let text = try? Parsers.readText(at: path, limit: Parsers.maximumBackgroundBytes) else {
            return FileState(text: nil, modified: nil)
        }
        return FileState(text: text, modified: attributes?[.modificationDate] as? Date)
    }

    // MARK: - Claude settings.json

    /// Same comparison Orca uses before recopying: both sides without Orca's
    /// managed hooks. nil when either side is not a JSON object.
    static func settingsMatch(copy: String, source: String) -> Bool? {
        guard let copy = jsonObject(copy), let source = jsonObject(source) else { return nil }
        return isEqual(removingManagedHooks(copy), removingManagedHooks(source))
    }

    /// Mirrors Orca's `removeManagedHooks`: drops hook entries whose command
    /// (or an `args` element) runs Orca's `agent-hooks/claude-hook` script or
    /// its native launcher, and events left empty. An empty `hooks` object is
    /// dropped too, because Orca compares `{}` and a missing key alike.
    static func removingManagedHooks(_ settings: [String: Any]) -> [String: Any] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return settings }
        var next = hooks
        for (event, value) in hooks {
            guard let definitions = value as? [Any] else { continue }
            let cleaned = definitions.compactMap(removingManagedCommands)
            if cleaned.isEmpty { next.removeValue(forKey: event) } else { next[event] = cleaned }
        }
        var result = settings
        if next.isEmpty { result.removeValue(forKey: "hooks") } else { result["hooks"] = next }
        return result
    }

    /// One hook definition without Orca-managed commands; nil when nothing
    /// else remains (`removeManagedCommands` in Orca's installer utils).
    private static func removingManagedCommands(_ value: Any) -> Any? {
        guard let definition = value as? [String: Any] else { return value }
        let directKeys = ["command", "bash", "powershell"]
        let managedDirect = directKeys.filter { isManagedHookCommand(definition[$0] as? String) }
        let nested = definition["hooks"] as? [Any]
        let hasManagedNested = nested?.contains { hookHasManagedCommand($0) } ?? false
        if managedDirect.isEmpty && !hasManagedNested { return definition }
        var next = definition
        for key in managedDirect { next.removeValue(forKey: key) }
        if hasManagedNested, let nested {
            let kept = nested.filter { !hookHasManagedCommand($0) }
            if kept.isEmpty { next.removeValue(forKey: "hooks") } else { next["hooks"] = kept }
        }
        let remains = directKeys.contains { next[$0] is String } || !((next["hooks"] as? [Any])?.isEmpty ?? true)
        return remains ? next : nil
    }

    private static func hookHasManagedCommand(_ value: Any) -> Bool {
        guard let hook = value as? [String: Any] else { return false }
        let args = hook["args"] as? [Any] ?? []
        return isManagedHookCommand(hook["command"] as? String)
            || args.contains { isManagedHookCommand($0 as? String) }
    }

    /// Orca's `createManagedCommandMatcher("claude-hook.sh")`: any platform
    /// suffix of the script under `agent-hooks/`, the Windows native launcher
    /// with the `claude` agent, also inside a PowerShell `-EncodedCommand`.
    static func isManagedHookCommand(_ command: String?) -> Bool {
        guard let command, !command.isEmpty else { return false }
        var search = command
        if let decoded = decodedPowerShellCommand(command) { search += "\n" + decoded }
        let normalized = search.replacingOccurrences(of: "\\", with: "/")
        let needles = ["sh", "cmd", "ps1"].map { "agent-hooks/claude-hook." + $0 }
        if needles.contains(where: normalized.contains) { return true }
        let native = "agent-hooks/orca-agent-hook.exe claude "
        return normalized.split(separator: "\n", omittingEmptySubsequences: false).contains { ($0 + " ").contains(native) }
    }

    private static func decodedPowerShellCommand(_ command: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\s-EncodedCommand\s+(\S+)"#, options: .caseInsensitive),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let range = Range(match.range(at: 1), in: command),
              let data = Data(base64Encoded: String(command[range])) else { return nil }
        return String(data: data, encoding: .utf16LittleEndian)
    }

    // MARK: - Claude .claude.json

    /// True when every shared source key is already in the copy as Orca
    /// would merge it (`projects`/`mcpServers` per entry; account-bound keys
    /// ignored; trust accepted in the account is kept). nil when unparsable.
    static func claudeStateMatches(copy: String, source: String) -> Bool? {
        guard let copy = jsonObject(copy), let source = jsonObject(source) else { return nil }
        for (key, value) in source where !isAccountBoundState(key) {
            if key == "projects" || key == "mcpServers",
               let entries = value as? [String: Any], let own = copy[key] as? [String: Any] {
                for (name, entry) in entries {
                    var expected = entry
                    if key == "projects", var project = entry as? [String: Any],
                       (own[name] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true {
                        project["hasTrustDialogAccepted"] = true
                        expected = project
                    }
                    guard let current = own[name], isEqual(current, expected) else { return false }
                }
            } else if let current = copy[key] {
                if !isEqual(current, value) { return false }
            } else {
                return false
            }
        }
        return true
    }

    /// Orca's `isAccountBoundState` (logout keys, identity, caches).
    static func isAccountBoundState(_ key: String) -> Bool {
        accountBoundStateKeys.contains(key) || key.contains("Cache") || key.hasPrefix("cached") || key.hasPrefix("passes")
    }

    private static let accountBoundStateKeys: Set<String> = [
        "oauthAccount", "additionalModelOptionsCache", "additionalModelOptionsAnsweredAt",
        "additionalModelCostsCache", "modelAccessCache", "orgModelDefaultCache", "cachedArtifactRoster",
        "artifactRosterDenied", "lastSeenOrgDefaultUpdatedAt", "clientDataCache", "clientDataCacheSlots",
        "autoCompactWindowsCache", "cachedUsageUtilization", "metricsStatusCache",
        "metricsStatusCacheByPrincipal", "githubWebConnectionStatusCache", "startupPrefetchedAt",
        "subscriptionNoticeCount", "hasAvailableSubscription",
        "userID", "machineID", "firstStartTime", "firstStartVersion", "primaryApiKey", "claudeCodeFirstTokenDate",
    ]

    // MARK: - Codex config.toml

    /// Compares the keys Orca mirrors, leaving out what the home owns
    /// (`projects`, `hooks` trust, `features.daemon_auto_start`, MCP servers
    /// absent from the source). Conservative: Orca also rewrites relative
    /// paths and promotes some keys back, so a mismatch is not a verdict.
    static func codexConfigMatches(copy: String, source: String) -> Bool? {
        guard case let (copyTree?, _) = Parsers.parseInBackground(copy, format: .toml),
              case let (sourceTree?, _) = Parsers.parseInBackground(source, format: .toml),
              let copyTable = copyTree as? [String: Any], let sourceTable = sourceTree as? [String: Any]
        else { return nil }
        let sourceServers = sourceTable["mcp_servers"] as? [String: Any] ?? [:]
        func shared(_ table: [String: Any], isCopy: Bool) -> [String: Any] {
            var table = table
            table.removeValue(forKey: "projects")
            table.removeValue(forKey: "hooks")
            if var features = table["features"] as? [String: Any] {
                features.removeValue(forKey: "daemon_auto_start")
                table["features"] = features.isEmpty ? nil : features
            }
            if isCopy, let servers = table["mcp_servers"] as? [String: Any] {
                let mirrored = servers.filter { sourceServers[$0.key] != nil }
                table["mcp_servers"] = mirrored.isEmpty ? nil : mirrored
            }
            return table
        }
        return isEqual(shared(copyTable, isCopy: true), shared(sourceTable, isCopy: false))
    }

    // MARK: - Helpers

    /// Orca imports `~/.claude/CLAUDE.md` only when the source folder is the
    /// default one; a custom CLAUDE_CONFIG_DIR gets a plain copy.
    private static var importsClaudeMemory: Bool { isDefaultClaudeRoot }

    private static var isDefaultClaudeRoot: Bool {
        (claudeSourceRoot as NSString).standardizingPath == ((AppPaths.home + "/.claude") as NSString).standardizingPath
    }

    /// Orca's `isSharedEntry` for loose files at the top of the Claude folder.
    static func isSharedClaudeEntry(_ name: String) -> Bool {
        !unsharedClaudeEntries.contains(name) && !name.hasPrefix(".") && !name.hasPrefix("daemon")
            && !name.hasPrefix("agent-memory")
    }

    /// Runtime state, settings and history Orca never copies (Orca's
    /// `CLAUDE_RUNTIME_STATE_ENTRIES` + `settings.json` + history dirs).
    private static let unsharedClaudeEntries: Set<String> = [
        ".claude.json", ".claude.json.backup", ".credentials.json", ".session_ingress_token", "active-time.json",
        "antproto.json", "api-dumps", "backups", "bridge-spawn", "cache", "ccr", "ccr-home-seed.json", "chrome",
        "computer-use.lock", "daemon", "debug", "downloads", "dump-prompts", "feedback", "feedback-bundles",
        "file-history", "file-transfers", "gh-pr-status-cache.json", "hfi-auth.json", "history.jsonl", "ide",
        "image-cache", "jobs", "local", "local-settings", "logs", "loop.md", "mcp-discovery-cache",
        "mcp-needs-auth-cache.json", "mcp-skill-archives", "paste-cache", "plans", "policy-limits.json",
        "project-settings", "projects", "remote", "remote-control", "remote-settings.json", "scratch", "seed-admin",
        "server-sessions.json", "server.lock", "session-env", "sessions", "shares", "shell-snapshots", "startup-perf",
        "state", "stats-cache.json", "statsig", "storage-v2", "systemd", "tasks", "teams", "telemetry", "todos",
        "traces", "uploads", "usage-data", "settings.json",
    ]

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func isEqual(_ a: Any, _ b: Any) -> Bool {
        (a as AnyObject).isEqual(b as AnyObject)
    }
}
