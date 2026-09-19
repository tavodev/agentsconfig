import Foundation

/// Detects issues and managed blocks inside a config file:
/// - parse errors
/// - hook commands pointing to files that no longer exist (e.g. stale Orca hooks)
/// - marker sections written by third-party tools (orca-managed, gk hooks, state blocks)
@MainActor enum Linter {

    static func lint(path: String, text: String, tree: Any?, parseError: String?,
                     format: ConfigFormat) -> (issues: [FileIssue], managed: [ManagedBlock]) {
        var issues: [FileIssue] = []
        var managed: [ManagedBlock] = []
        let kind = ConfigFileContext.settingsKind(for: path)

        if let parseError {
            issues.append(.init(severity: .error, message: parseError))
        }

        // --- managed marker blocks in text, e.g. "# >>> orca-managed-kimi-hooks ..."
        scanManagedMarkers(text: text, into: &managed, issues: &issues)

        // --- hook commands that reference missing files
        if let dict = tree as? [String: Any] {
            let commands = collectHookCommands(dict)
            for cmd in commands {
                for ref in referencedPaths(in: cmd) {
                    if !FileManager.default.fileExists(atPath: ref) {
                        issues.append(.init(
                            severity: .warning,
                            message: L("Hook points to a missing file: %@", ref)
                        ))
                    }
                }
            }
            detectManagedKeys(dict, path: path, kind: kind, into: &managed)
        }

        // --- orphan orca references in plain text (TOML hook strings etc.)
        if format == .toml || format == .json || format == .jsonc {
            if text.contains("/.orca/") {
                if !FileManager.default.fileExists(atPath: AppPaths.home + "/.orca") {
                    issues.append(.init(
                        severity: .warning,
                        message: L("Orca hooks detected but ~/.orca no longer exists — they are inert.")
                    ))
                }
            }
        }

        // --- empty instruction files
        if (format == .markdown || format == .text) &&
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(severity: .info, message: L("Empty file.")))
        }

        // --- unknown top-level keys (typo / deprecated)
        if let dict = tree as? [String: Any], let known = knownKeys(for: kind) {
            for k in dict.keys.sorted() where !known.contains(k) {
                issues.append(.init(severity: .info,
                                    message: L("Uncatalogued key: «%@» — check the documentation for your agent version.", k)))
            }
        }

        if let kind, parseError == nil, let tree {
            if let dict = tree as? [String: Any] {
                validateTypes(dict, kind: kind, into: &issues)
            } else {
                issues.append(.init(severity: .error, message: L("Configuration must be an object.")))
            }
        }
        return (issues, managed)
    }

    // MARK: - known top-level keys per file

    private static func knownKeys(for kind: ConfigFileContext.SettingsKind?) -> Set<String>? {
        switch kind {
        case .claude:
            return [
                "$schema", "env", "attribution", "permissions", "model", "modelSettings",
                "skillOverrides", "hooks", "statusLine", "enabledPlugins", "extraKnownMarketplaces",
                "language", "alwaysThinkingEnabled", "effortLevel", "remote", "tui", "voice",
                "voiceEnabled", "verbose", "apiKeyHelper", "cleanupPeriodDays",
                "includeCoAuthoredBy", "autoUpdates", "theme", "editor", "teammateMode",
                "autoMode", "skipDangerousModePermissionPrompt", "skipWorkflowUsageWarning",
                "remoteControlAtStartup", "inputNeededNotifEnabled", "agentPushNotifEnabled",
                "skipAutoPermissionPrompt", "feedbackSurveyState", "spinnerVerbs",
                "terminalProgressBarEnabled", "respectGitignore", "outputStyle",
                "forceLoginMethod", "disableAllHooks", "allowManagedHooksOnly", "sandbox",
                "availableModels", "fallbackModel", "modelPicker", "claudeMdExcludes",
                "spinnerTipsEnabled", "disableClaudeAiConnectors", "forceLoginOrgUUID",
                "enabledMcpjsonServers", "disabledMcpjsonServers", "enableAllProjectMcpServers",
            ]
        case .codex:
            return [
                "model", "model_provider", "model_providers", "model_reasoning_effort",
                "model_context_window", "model_auto_compact_token_limit",
                "model_auto_compact_token_limit_scope", "review_model", "service_tier",
                "approval_policy", "sandbox_mode", "approvals_reviewer", "personality",
                "notify", "projects", "mcp_servers", "features", "plugins", "marketplaces",
                "desktop", "shell_environment_policy", "tui", "hooks", "profiles", "profile",
                "oss_provider", "openai_base_url", "chatgpt_base_url", "otel", "log_dir",
                "tool_output_token_limit", "background_terminal_max_timeout",
                "hide_agent_reasoning", "show_raw_agent_reasoning", "model_supports_reasoning_summaries",
                "experimental_realtime_ws_base_url", "apps_mcp_product_sku", "agents",
                "permissions", "default_permissions", "sandbox_workspace_write", "history",
                "project_doc_max_bytes", "project_doc_fallback_filenames", "project_root_markers",
                "model_instructions_file", "cli_auth_credentials_store", "web_search",
            ]
        case .opencode:
            return [
                "$schema", "provider", "mcp", "agent", "model", "small_model", "theme",
                "keybinds", "autoshare", "autoupdate", "disabled_providers", "plugin",
                "snapshot", "share", "formatter", "lsp", "instructions", "layout",
                "permission", "tools", "watcher", "compaction", "experimental",
                "default_agent", "mode", "username", "permissions", "server", "enabled_providers", "skills",
            ]
        case .gemini:
            return [
                "selectedAuthType", "theme", "ide", "security", "mcpServers",
                "contextFileName", "bugCommand", "fileFiltering", "checkpointing",
                "telemetry", "usageStatisticsEnabled", "hideTips", "hideBanner",
                "maxSessionTurns", "enableOpenAILogging", "sampling", "customThemes",
                "model", "preferredEditor", "coreTools", "excludeTools", "autoAccept",
                "general", "ui", "context", "tools", "hooks", "skills", "agents",
                "mcp", "advanced", "output", "experimental", "adminPolicyPaths",
            ]
        default:
            return nil
        }
    }

    // Conservative shape checks for established fields. This is not a full,
    // version-specific schema: unknown keys are retained and only informational.
    private enum ValueShape: String {
        case object = "object"
        case string = "string"
        case stringArray = "array of strings"
        case boolean = "boolean"
        case stringOrObject = "string or object"
        case array = "array"

        func accepts(_ value: Any) -> Bool {
            switch self {
            case .object: return value is [String: Any]
            case .string: return value is String
            case .stringArray: return value is [String]
            case .boolean:
                return (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
            case .stringOrObject: return value is String || value is [String: Any]
            case .array: return value is [Any]
            }
        }
    }

    private static func validateTypes(_ dict: [String: Any], kind: ConfigFileContext.SettingsKind,
                                      into issues: inout [FileIssue]) {
        var rules: [String: ValueShape] = [:]
        switch kind {
        case .claude:
            rules = ["permissions": .object, "permissions.allow": .stringArray,
                     "permissions.deny": .stringArray, "permissions.ask": .stringArray,
                     "permissions.defaultMode": .string, "env": .object, "hooks": .object,
                     "sandbox": .object, "sandbox.enabled": .boolean, "model": .string,
                     "enabledPlugins": .object]
        case .codex:
            rules = ["model": .string, "approval_policy": .stringOrObject, "sandbox_mode": .string,
                     "projects": .object, "mcp_servers": .object, "features": .object,
                     "agents": .object, "hooks": .object, "shell_environment_policy": .object]
        case .gemini:
            rules = ["general": .object, "ui": .object, "context": .object, "tools": .object,
                     "security": .object, "hooks": .object, "mcpServers": .object,
                     "model": .stringOrObject, "general.vimMode": .boolean]
        case .opencode:
            rules = ["model": .string, "provider": .object, "agent": .object,
                     "mcp": .object, "permission": .stringOrObject,
                     "permissions": .array, "instructions": .stringArray, "plugin": .array]
        }
        for (path, shape) in rules.sorted(by: { $0.key < $1.key }) {
            var value: Any? = dict
            for key in path.split(separator: ".") {
                value = (value as? [String: Any])?[String(key)]
            }
            if let value, !shape.accepts(value) {
                issues.append(.init(severity: .error,
                    message: L("Invalid type for «%@»: expected %@.", path, L(shape.rawValue))))
            }
        }
    }

    // MARK: - managed markers

    private static func scanManagedMarkers(text: String,
                                           into managed: inout [ManagedBlock],
                                           issues: inout [FileIssue]) {
        // pattern: ">>> <name>-managed-*" or "# >>> orca-managed-kimi-hooks"
        let pattern = #">>>\s*([A-Za-z0-9_-]*managed[A-Za-z0-9_-]*)"# 
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let ns = text as NSString
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range(at: 1))
            let owner = tag
                .replacingOccurrences(of: "orca-managed-", with: "Orca · ")
                .replacingOccurrences(of: "-managed-", with: " · ")
            managed.append(.init(owner: owner, detail: L("Delimited block «%@» — managed by an external tool", tag)))
        }
    }

    // MARK: - hooks

    /// Walk any `hooks`-shaped structure and collect `command` strings.
    static func collectHookCommands(_ dict: [String: Any]) -> [String] {
        var out: [String] = []
        func walk(_ v: Any) {
            switch v {
            case let d as [String: Any]:
                for (k, val) in d {
                    if k == "command", let s = val as? String { out.append(s) }
                    else if k == "command", let a = val as? [String] { out.append(contentsOf: a) }
                    else { walk(val) }
                }
            case let a as [Any]:
                a.forEach(walk)
            default: break
            }
        }
        if let hooks = dict["hooks"] { walk(hooks) }
        if let mcp = dict["mcpServers"] as? [String: Any] {
            for (_, v) in mcp {
                if let s = v as? [String: Any], let cmd = s["command"] as? String { out.append(cmd) }
            }
        }
        return out
    }

    /// Extract absolute-path tokens from a shell command.
    static func referencedPaths(in command: String) -> [String] {
        let pattern = #"(?<![\w.-])/(?:[A-Za-z0-9._~@-]+/)+[A-Za-z0-9._~@-]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = command as NSString
        var paths: [String] = []
        for m in regex.matches(in: command, range: NSRange(location: 0, length: ns.length)) {
            var p = ns.substring(with: m.range)
            p = p.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            // expand ~ inside token
            if p.hasPrefix("/~/") { p = AppPaths.home + String(p.dropFirst(1)) }
            if p.hasPrefix("/System") || p.hasPrefix("/usr/") || p.hasPrefix("/bin") || p.hasPrefix("/opt/homebrew") {
                if FileManager.default.fileExists(atPath: p) { continue }
            }
            paths.append(p)
        }
        return paths
    }

    /// Well-known keys that agents/tools write for their own bookkeeping.
    private static func detectManagedKeys(_ dict: [String: Any], path: String,
                                          kind: ConfigFileContext.SettingsKind?, into managed: inout [ManagedBlock]) {
        let codex = kind == .codex || ConfigFileContext.matches(path, suffix: ".codex/hooks.json")
        if codex, let hooks = dict["hooks"] as? [String: Any], hooks["state"] != nil {
            managed.append(.init(owner: "Codex", detail: L("hooks.state — trust hashes managed by Codex")))
        }
        if ConfigFileContext.isUserFile(path, relativePath: ".claude.json"),
           dict["feedbackSurveyState"] != nil || dict["projects"] != nil {
            managed.append(.init(owner: "Claude Code", detail: L("Internal state (projects, surveys) — rewrites itself")))
        }
        if codex, dict["plugins"] != nil, dict["marketplaces"] != nil {
            managed.append(.init(owner: "Codex", detail: L("plugins/marketplaces — managed by the Codex app")))
        }
    }
}
