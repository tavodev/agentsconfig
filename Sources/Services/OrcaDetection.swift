import Foundation

/// Where Orca keeps its data and which account it has selected, resolved the
/// way Orca 1.4.246 does (`getOrcaUserDataPath` in `codex-home-paths.ts`,
/// `resolveLaunchUserDataPath` in `launch-user-data-path.ts`,
/// `ClaudeProfileRouter.pointerPath` in `claude-profile-router.ts`).
///
/// Never reads Orca's settings store (`orca-data.json` / SQLite, which also
/// holds sealed secrets) nor any credential file, so two things stay unknown:
/// - whether a `claude-profiles/<id>` folder still belongs to a registered
///   account (the registry is `claudeManagedAccounts` in that store; Orca
///   itself keeps retired Codex homes on disk), so no profile is marked
///   orphaned;
/// - which Codex account is selected (`activeCodexManagedAccountId`, same
///   store; the runtime home only carries a copy of that account's
///   credentials), so no Codex home is marked selected.
extension OrcaIntegration {
    /// UserDefaults key of the folder chosen in Settings (nil: default).
    static let dataPathKey = "orcaDataPath"
    static let dataPathEnvironmentKey = "ORCA_USER_DATA_PATH"

    /// Read once, like `AppPaths.environmentHome`: `root` is consulted per key row.
    private static let processDataPath = ProcessInfo.processInfo.environment[dataPathEnvironmentKey]

    /// Folder chosen in Settings → Configuration folders, if any.
    static var customDataPath: String? {
        guard let path = AppSettings.defaults.string(forKey: dataPathKey), !path.isEmpty else { return nil }
        return path
    }

    /// Where `root` comes from, for Settings.
    enum DataRootOrigin: Equatable { case chosen, environment, standard }

    /// Orca's data folder: the folder chosen in Settings, else
    /// `ORCA_USER_DATA_PATH` from the app's environment (only outside
    /// isolated runs), else `~/Library/Application Support/orca`.
    static func dataRoot(custom: String?, environment: String?, isolated: Bool, home: String) -> (path: String, origin: DataRootOrigin) {
        if let custom, !custom.isEmpty {
            return (standardized(custom, home: home), .chosen)
        }
        // Orca tests `if (process.env.ORCA_USER_DATA_PATH)`: an empty value is unset.
        if !isolated, let environment, !environment.isEmpty {
            return (standardized(environment, home: home), .environment)
        }
        return (home + "/Library/Application Support/orca", .standard)
    }

    /// Resolution actually in use. An isolated run (`AppPaths.overrideHome`,
    /// `AGENTSCONFIG_HOME`) never reads the app environment: it always uses
    /// the folder under the isolated home unless Settings chose another.
    static var dataRootResolution: (path: String, origin: DataRootOrigin) {
        let isolated = AppPaths.overrideHome != nil || AppPaths.environmentHome != nil || AppSettings.isIsolatedRun
        return dataRoot(custom: customDataPath, environment: processDataPath, isolated: isolated, home: AppPaths.home)
    }

    /// Node's `path.resolve` makes a relative value absolute against the
    /// working directory, which for a GUI app is meaningless; a relative
    /// value is resolved against the home instead. `~` is expanded.
    private static func standardized(_ path: String, home: String) -> String {
        var path = path
        if path == "~" { path = home } else if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        if !path.hasPrefix("/") { path = home + "/" + path }
        // `URL.standardized` folds `.`/`..` without NSString's `/private` stripping,
        // which would break path identity with tracked files.
        var result = URL(fileURLWithPath: path).standardized.path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }

    // MARK: - Selected account

    /// Home in `claude-profiles/selected-host`, the pointer Orca writes for
    /// terminals. Empty or absent: "System default" (`~/.claude`) is in use,
    /// or no managed account exists. Holds a path only, never a secret.
    static func selectedClaudeHome(root: String) -> String? {
        let file = root + "/claude-profiles/selected-host"
        guard let text = try? Parsers.readText(at: file, limit: 64 * 1024) else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// True when `home` is the Claude profile Orca has selected.
    static func isSelectedClaudeHome(_ home: String, root: String) -> Bool {
        guard let selected = selectedClaudeHome(root: root) else { return false }
        if selected == home { return true }
        let a = AppPaths.canonicalPath(selected) ?? (selected as NSString).standardizingPath
        let b = AppPaths.canonicalPath(home) ?? (home as NSString).standardizingPath
        return a == b
    }

    // MARK: - Orca-managed hook commands

    /// Orca's `createManagedCommandMatcher("codex-hook.sh")`, the Codex
    /// counterpart of `isManagedHookCommand` (Claude).
    static func isManagedCodexHookCommand(_ command: String?) -> Bool {
        guard let command, !command.isEmpty else { return false }
        var search = command
        if let regex = try? NSRegularExpression(pattern: #"\s-EncodedCommand\s+(\S+)"#, options: .caseInsensitive),
           let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
           let range = Range(match.range(at: 1), in: command),
           let data = Data(base64Encoded: String(command[range])),
           let decoded = String(data: data, encoding: .utf16LittleEndian) {
            search += "\n" + decoded
        }
        let normalized = search.replacingOccurrences(of: "\\", with: "/")
        if ["sh", "cmd", "ps1"].contains(where: { normalized.contains("agent-hooks/codex-hook." + $0) }) { return true }
        return normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .contains { ($0 + " ").contains("agent-hooks/orca-agent-hook.exe codex ") }
    }

    /// Status hook Orca installs for this agent family (`claude-code…` or
    /// `codex…`), wherever it appears — Orca also installs them in the
    /// regular homes used by "System default".
    static func isManagedHook(_ command: String, agentID: String) -> Bool {
        if agentID.hasPrefix("claude-code") { return isManagedHookCommand(command) }
        if agentID.hasPrefix("codex") { return isManagedCodexHookCommand(command) }
        return false
    }

    /// Short, stable label of a home: account folder (first 8 characters,
    /// as in the agent name) or "runtime".
    static func accountLabel(_ home: Home) -> String {
        home.account.map { String($0.prefix(8)) } ?? "runtime"
    }
}
