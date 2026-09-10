import Foundation

/// Detects issues and managed blocks inside a config file:
/// - parse errors
/// - hook commands pointing to files that no longer exist (e.g. stale Orca hooks)
/// - marker sections written by third-party tools (orca-managed, gk hooks, state blocks)
enum Linter {

    static func lint(path: String, text: String, tree: Any?, parseError: String?,
                     format: ConfigFormat) -> (issues: [FileIssue], managed: [ManagedBlock]) {
        var issues: [FileIssue] = []
        var managed: [ManagedBlock] = []

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
                            message: "Hook referencia un archivo inexistente: \(ref)"
                        ))
                    }
                }
            }
            detectManagedKeys(dict, into: &managed)
        }

        // --- orphan orca references in plain text (TOML hook strings etc.)
        if format == .toml || format == .json || format == .jsonc {
            if text.contains("/.orca/") {
                if !FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.orca") {
                    issues.append(.init(
                        severity: .warning,
                        message: "Hooks de Orca detectados pero ~/.orca ya no existe — son inertes."
                    ))
                }
            }
        }

        // --- empty instruction files
        if (format == .markdown || format == .text) &&
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(severity: .info, message: "Archivo vacío."))
        }

        // --- unknown top-level keys (typo / deprecated)
        if let dict = tree as? [String: Any], let known = knownKeys(for: path) {
            for k in dict.keys where !known.contains(k) {
                issues.append(.init(severity: .info,
                                    message: "Clave no reconocida: «\(k)» — ¿typo o key nueva del agente?"))
            }
        }

        return (issues, managed)
    }

    // MARK: - known top-level keys per file

    private static func knownKeys(for path: String) -> Set<String>? {
        let home = NSHomeDirectory()
        switch path {
        case "\(home)/.claude/settings.json":
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
                "forceLoginMethod", "disableAllHooks", "allowManagedHooksOnly",
            ]
        case "\(home)/.codex/config.toml":
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
            ]
        case "\(home)/.config/opencode/opencode.json":
            return [
                "$schema", "provider", "mcp", "agent", "model", "small_model", "theme",
                "keybinds", "autoshare", "autoupdate", "disabled_providers", "plugin",
                "snapshot", "share", "formatter", "lsp", "instructions", "layout",
                "permission", "tools", "watcher", "compaction", "experimental",
                "default_agent", "mode", "username",
            ]
        case "\(home)/.gemini/settings.json":
            return [
                "selectedAuthType", "theme", "ide", "security", "mcpServers",
                "contextFileName", "bugCommand", "fileFiltering", "checkpointing",
                "telemetry", "usageStatisticsEnabled", "hideTips", "hideBanner",
                "maxSessionTurns", "enableOpenAILogging", "sampling", "customThemes",
                "model", "preferredEditor", "coreTools", "excludeTools", "autoAccept",
            ]
        default:
            return nil
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
            managed.append(.init(owner: owner, detail: "Bloque delimitado «\(tag)» — gestionado por herramienta externa"))
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
            if p.hasPrefix("/~/") { p = NSHomeDirectory() + String(p.dropFirst(1)) }
            if p.hasPrefix("/System") || p.hasPrefix("/usr/") || p.hasPrefix("/bin") || p.hasPrefix("/opt/homebrew") {
                if FileManager.default.fileExists(atPath: p) { continue }
            }
            paths.append(p)
        }
        return paths
    }

    /// Well-known keys that agents/tools write for their own bookkeeping.
    private static func detectManagedKeys(_ dict: [String: Any], into managed: inout [ManagedBlock]) {
        if let hooks = dict["hooks"] as? [String: Any], hooks["state"] != nil {
            managed.append(.init(owner: "Codex", detail: "hooks.state — hashes de confianza gestionados por Codex"))
        }
        if dict["feedbackSurveyState"] != nil || dict["projects"] != nil {
            managed.append(.init(owner: "Claude Code", detail: "Estado interno (projects, surveys) — se reescribe solo"))
        }
        if dict["plugins"] != nil, dict["marketplaces"] != nil {
            managed.append(.init(owner: "Codex", detail: "plugins/marketplaces — gestionados por la app de Codex"))
        }
    }
}
