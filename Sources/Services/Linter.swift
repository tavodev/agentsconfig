import Foundation

/// Stable identifiers for the security-audit rules below, so a single rule
/// can be silenced per file (`ConfigStore.mutedLintRules`) without touching
/// the core diagnostics (parse errors, unknown keys, type/shape checks,
/// managed markers), which stay permanent and keep `FileIssue.ruleID == nil`.
enum LintRule: String, CaseIterable {
    case broadPermissions = "broad-permissions"
    case dangerousMode = "dangerous-mode"
    case hookOutsideConfig = "hook-outside-config"
    case hookDownloadExecute = "hook-download-execute"
    case unpinnedMcp = "unpinned-mcp-version"
    case literalSecret = "literal-secret"
}

/// Detects issues and managed blocks inside a config file:
/// - parse errors
/// - hook commands pointing to files that no longer exist (e.g. stale Orca hooks)
/// - marker sections written by third-party tools (orca-managed, gk hooks, state blocks)
/// - security-audit rules (see `LintRule`): overly broad permissions,
///   dangerously permissive modes, risky hooks, unpinned MCP servers and
///   literal secrets — each silenceable per file via `mutedRuleIDs`.
@MainActor enum Linter {

    static func lint(path: String, text: String, tree: Any?, parseError: String?,
                     format: ConfigFormat, mutedRuleIDs: Set<String> = []) -> (issues: [FileIssue], managed: [ManagedBlock]) {
        var issues: [FileIssue] = []
        var managed: [ManagedBlock] = []
        let kind = ConfigFileContext.settingsKind(for: path)

        if let parseError {
            issues.append(.init(severity: .error, message: parseError))
        }

        // --- managed marker blocks in text, e.g. "# >>> orca-managed-kimi-hooks ..."
        scanManagedMarkers(text: text, into: &managed, issues: &issues)

        // --- hook commands that reference missing files, or are otherwise risky
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
            // Only real hooks: `collectHookCommands` also returns MCP launch commands.
            let hookCommands = dict["hooks"].map { collectHookCommands(["hooks": $0]) } ?? []
            issues.append(contentsOf: hookRiskIssues(hookCommands, path: path))
            detectManagedKeys(dict, path: path, kind: kind, into: &managed)

            // --- security audit (issue #18)
            issues.append(contentsOf: broadPermissionIssues(dict, kind: kind))
            issues.append(contentsOf: dangerousModeIssues(dict, kind: kind))
            issues.append(contentsOf: unpinnedMcpIssues(dict, kind: kind))
            issues.append(contentsOf: literalSecretIssues(dict))
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
        if !mutedRuleIDs.isEmpty {
            issues.removeAll { $0.ruleID.map(mutedRuleIDs.contains) ?? false }
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

    // MARK: - security audit (issue #18)
    //
    // Keys/values below are confirmed against official docs at the time of
    // writing: code.claude.com/docs/en/permissions (Bash rule syntax) and
    // .../settings-reference (permissions.defaultMode values),
    // developers.openai.com/codex/config-reference (approval_policy,
    // sandbox_mode), opencode.ai/docs/permissions (permission shorthand +
    // per-tool object), and google-gemini/gemini-cli docs/cli/settings.md
    // (general.defaultApprovalMode; full "yolo" mode cannot be persisted in
    // settings.json, only toggled with the --yolo flag, so it has no rule here).

    /// Claude `Bash`/`PowerShell` allow-rules that are fully unrestricted, and
    /// the OpenCode equivalent for `permission.bash`. A bare tool name,
    /// `Tool(*)` and `Tool(:*)` are documented as equivalent — all three match
    /// every invocation.
    private static func broadPermissionIssues(_ dict: [String: Any], kind: ConfigFileContext.SettingsKind?) -> [FileIssue] {
        var issues: [FileIssue] = []
        guard let unrestricted = try? NSRegularExpression(pattern: #"^(Bash|PowerShell)(\((\*|:\*)\))?$"#) else { return issues }
        func isUnrestricted(_ s: String) -> Bool {
            unrestricted.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        if kind == .claude, let perms = dict["permissions"] as? [String: Any],
           let allow = perms["allow"] as? [String] {
            for rule in allow where isUnrestricted(rule) {
                issues.append(.init(severity: .warning, message: L("«permissions.allow» includes «%@», which lets every shell command run without confirmation. Replace it with scoped rules, e.g. «Bash(git *)» or specific commands.", rule), ruleID: LintRule.broadPermissions.rawValue))
            }
        }
        if kind == .opencode, let perm = dict["permission"] as? [String: Any] {
            if (perm["bash"] as? String) == "allow" {
                issues.append(.init(severity: .warning, message: L("«permission.bash» is «allow»: every shell command runs without confirmation. Scope it to specific patterns instead, e.g. {\"git *\": \"allow\", \"rm *\": \"deny\"}."), ruleID: LintRule.broadPermissions.rawValue))
            }
            if let rules = perm["bash"] as? [String: Any], (rules["*"] as? String) == "allow" {
                issues.append(.init(severity: .warning, message: L("«permission.bash» has a catch-all «*: allow» rule: every shell command runs without confirmation unless a more specific rule overrides it. Replace the wildcard with scoped patterns."), ruleID: LintRule.broadPermissions.rawValue))
            }
        }
        return issues
    }

    /// Modes that remove the permission/approval prompt entirely: Claude's
    /// `bypassPermissions`, Codex's `approval_policy = "never"` /
    /// `sandbox_mode = "danger-full-access"` (top-level and per profile),
    /// OpenCode's `permission = "allow"`, and Gemini's legacy `autoAccept`.
    private static func dangerousModeIssues(_ dict: [String: Any], kind: ConfigFileContext.SettingsKind?) -> [FileIssue] {
        var issues: [FileIssue] = []
        switch kind {
        case .claude:
            if let perms = dict["permissions"] as? [String: Any], (perms["defaultMode"] as? String) == "bypassPermissions" {
                issues.append(.init(severity: .warning, message: L("«permissions.defaultMode» is «bypassPermissions»: Claude Code skips every permission prompt entirely. Reserve this for isolated sandboxes (container/VM) and prefer «acceptEdits» or «plan» otherwise."), ruleID: LintRule.dangerousMode.rawValue))
            }
        case .codex:
            func check(_ table: [String: Any], keyPath: String) {
                if (table["approval_policy"] as? String) == "never" {
                    issues.append(.init(severity: .warning, message: L("«%@» is «never»: Codex never stops to ask for approval. Combine it with a restrictive «sandbox_mode» or use a narrower approval policy.", "\(keyPath)approval_policy"), ruleID: LintRule.dangerousMode.rawValue))
                }
                if (table["sandbox_mode"] as? String) == "danger-full-access" {
                    issues.append(.init(severity: .warning, message: L("«%@» is «danger-full-access»: Codex runs without filesystem or network isolation. Use «workspace-write» or «read-only» unless you fully trust this environment.", "\(keyPath)sandbox_mode"), ruleID: LintRule.dangerousMode.rawValue))
                }
            }
            check(dict, keyPath: "")
            if let profiles = dict["profiles"] as? [String: Any] {
                for (name, value) in profiles.sorted(by: { $0.key < $1.key }) {
                    if let table = value as? [String: Any] { check(table, keyPath: "profiles.\(name).") }
                }
            }
        case .opencode:
            if (dict["permission"] as? String) == "allow" {
                issues.append(.init(severity: .warning, message: L("«permission» is «allow»: every tool runs without confirmation. Scope it per tool instead, e.g. {\"bash\": \"ask\", \"edit\": \"allow\"}."), ruleID: LintRule.dangerousMode.rawValue))
            }
        case .gemini:
            if dict["autoAccept"] as? Bool == true {
                issues.append(.init(severity: .warning, message: L("«autoAccept» is enabled: actions run without confirmation. Disable it and approve actions manually."), ruleID: LintRule.dangerousMode.rawValue))
            }
            if (dict["general"] as? [String: Any])?["defaultApprovalMode"] as? String == "auto_edit" {
                issues.append(.init(severity: .info, message: L("«general.defaultApprovalMode» is «auto_edit»: file edits are approved automatically without asking. Shell commands still prompt, but review this if the session runs unattended."), ruleID: LintRule.dangerousMode.rawValue))
            }
        case nil:
            break
        }
        return issues
    }

    /// MCP servers launched with `npx`/`uvx` and no pinned version — including
    /// an explicit `@latest`/`@next`/`@canary` tag, which is not a fixed
    /// version either. `npx -y @scope/pkg@1.2.3` is correctly left alone.
    private static func unpinnedMcpIssues(_ dict: [String: Any], kind: ConfigFileContext.SettingsKind?) -> [FileIssue] {
        let containerKey: String
        switch kind {
        case .claude, .gemini: containerKey = "mcpServers"
        case .codex: containerKey = "mcp_servers"
        case .opencode: containerKey = "mcp"
        case nil: return []
        }
        guard let servers = dict[containerKey] as? [String: Any] else { return [] }
        var issues: [FileIssue] = []
        for (name, raw) in servers.sorted(by: { $0.key < $1.key }) {
            guard let spec = raw as? [String: Any] else { continue }
            let command: String?
            let args: [String]
            if kind == .opencode {
                guard let list = spec["command"] as? [String], let first = list.first else { continue }
                command = first; args = Array(list.dropFirst())
            } else {
                command = spec["command"] as? String
                args = spec["args"] as? [String] ?? []
            }
            guard let command else { continue }
            let executable = (command as NSString).lastPathComponent
            let keyPath = "\(containerKey).\(name)"
            if executable == "npx", let pin = unpinnedNpxPackage(args) {
                issues.append(.init(severity: .warning, message: L("MCP server at «%@» runs «npx» on «%@» without a pinned version. A registry change or a compromised release could silently alter what runs next time. Pin an exact version, e.g. «%@@1.2.3».", keyPath, pin, pin), ruleID: LintRule.unpinnedMcp.rawValue))
            } else if executable == "uvx", let pin = unpinnedUvxPackage(args) {
                issues.append(.init(severity: .warning, message: L("MCP server at «%@» runs «uvx %@» without a pinned version. Pin an exact version, e.g. «uvx %@==1.2.3».", keyPath, pin, pin), ruleID: LintRule.unpinnedMcp.rawValue))
            }
        }
        return issues
    }

    /// Returns the package token if it has no fixed version (no `@version`
    /// at all, or an explicit `@latest`/`@next`/`@canary` tag). Handles scoped
    /// packages, whose name already contains one `@` for the scope.
    private static func unpinnedNpxPackage(_ args: [String]) -> String? {
        guard let token = args.first(where: { !$0.hasPrefix("-") }), !token.isEmpty else { return nil }
        let atCount = token.filter { $0 == "@" }.count
        let pinned = token.hasPrefix("@") ? atCount >= 2 : atCount >= 1
        if !pinned { return token }
        if let tag = token.split(separator: "@").last, ["latest", "next", "canary"].contains(String(tag)) {
            return token
        }
        return nil
    }

    /// `uv tool run` (`uvx`) pins a version with `pkg==1.2.3`/`pkg>=1.2.3`, or
    /// via a scoped `@version` after the package name. No such marker at all
    /// means the resolved version floats.
    private static func unpinnedUvxPackage(_ args: [String]) -> String? {
        guard let token = args.first(where: { !$0.hasPrefix("-") }), !token.isEmpty else { return nil }
        if token.contains("==") || token.contains(">=") || token.contains("@") { return nil }
        return token
    }

    /// Config keys/values that must stay under the config's own root (the
    /// enclosing repo for a project file, or `~` for a global one), plus
    /// download-and-execute one-liners (`curl … | sh`).
    private static func hookRiskIssues(_ commands: [String], path: String) -> [FileIssue] {
        guard !commands.isEmpty else { return [] }
        var issues: [FileIssue] = []
        let allowedRoots = [configRoot(for: path), AppPaths.home]
        guard let downloadExec = try? NSRegularExpression(
            pattern: #"(?i)\b(curl|wget)\b[^\n|]*\|\s*(sudo\s+)?(sh|bash|zsh|python[0-9.]*|perl)\b"#) else { return issues }
        var flaggedOutside = Set<String>()
        for cmd in commands {
            if downloadExec.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)) != nil {
                issues.append(.init(severity: .warning, message: L("Hook downloads and runs a remote script in one step: «%@». A compromised or intercepted server could run arbitrary code. Download it to a file, review it, then execute it separately.", String(Secrets.maskLine(cmd).prefix(200))), ruleID: LintRule.hookDownloadExecute.rawValue))
            }
            for ref in referencedPaths(in: cmd) where !flaggedOutside.contains(ref) {
                guard !allowedRoots.contains(where: { ref == $0 || ref.hasPrefix($0 + "/") }) else { continue }
                flaggedOutside.insert(ref)
                issues.append(.init(severity: .warning, message: L("Hook references a script outside the repository and outside the configuration home: «%@». Anyone who can write to that path changes what runs. Keep hook scripts inside the repo (or inside ~/.claude, etc.) and reference them with a path under that root.", ref), ruleID: LintRule.hookOutsideConfig.rawValue))
            }
        }
        return issues
    }

    /// The directory a config file's paths should stay under: the parent of
    /// a dotfile config dir (`.claude`, `.codex`, `.gemini`, `.config`, …) for
    /// project-local files, or the file's own directory for a root file like
    /// `opencode.json`.
    private static func configRoot(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        if parent.lastPathComponent.hasPrefix(".") {
            return parent.deletingLastPathComponent().path
        }
        return parent.path
    }

    /// Keys catalogued here whose value is legitimately not a secret, despite
    /// matching `Secrets.isSecretKey` (e.g. a helper script path). Kept short
    /// and explicit rather than loosening the shared secret-key heuristic.
    private static let literalSecretExemptKeys: Set<String> = ["apiKeyHelper"]

    /// Literal values under a key `Secrets.isSecretKey` flags, other than a
    /// reference (`${VAR}`, `$VAR`, `env://…`, etc.) meant to be resolved
    /// from the environment instead of written directly into the file.
    private static func literalSecretIssues(_ dict: [String: Any]) -> [FileIssue] {
        var issues: [FileIssue] = []
        var seen = Set<String>()
        func isReference(_ value: String) -> Bool {
            if value.isEmpty { return true }
            if value.range(of: #"\$\{[^}]+\}"#, options: .regularExpression) != nil { return true }
            if value.range(of: #"^\$[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil { return true }
            if value.range(of: #"(?i)^(env|file|keychain|op|vault|secretref):/?/?\S+"#, options: .regularExpression) != nil { return true }
            return false
        }
        func flag(_ value: String, path: String) {
            guard !isReference(value), !seen.contains(path) else { return }
            seen.insert(path)
            issues.append(.init(severity: .warning, message: L("«%@» holds a literal secret value instead of a reference. Move it to an environment variable (e.g. «${VAR}») and keep only that reference here.", path), ruleID: LintRule.literalSecret.rawValue))
        }
        func walk(_ value: Any, path: String) {
            if let d = value as? [String: Any] {
                for (key, child) in d {
                    let childPath = path.isEmpty ? key : "\(path).\(key)"
                    if !literalSecretExemptKeys.contains(key), Secrets.isSecretKey(key) {
                        if let s = child as? String { flag(s, path: childPath) }
                        else if let arr = child as? [String] { for s in arr { flag(s, path: childPath) } }
                    }
                    walk(child, path: childPath)
                }
            } else if let a = value as? [Any] {
                for (i, child) in a.enumerated() { walk(child, path: "\(path)[\(i)]") }
            }
        }
        walk(dict, path: "")
        return issues
    }
}
