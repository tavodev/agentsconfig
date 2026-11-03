import Foundation

/// MCP servers of Orca homes and Orca's Codex settings baseline, verified
/// against Orca 1.4.246 (`claude-profile-provisioning.ts` `mergeEntries`,
/// `codex-config-mirror-merge.ts`, `config-settings-baseline.ts`,
/// `config-settings-promotion.ts`, `config-settings-conflict-resolution.ts`).
///
/// - Claude profile `.claude.json`: Orca merges `mcpServers` and `projects`
///   from the global state entry by entry (the source wins) and keeps the
///   entries only the profile has. A project present in the source replaces
///   the profile's whole project record (only accepted trust is kept).
/// - Codex `config.toml`: the source config is copied; a home's own
///   `[mcp_servers.<name>]` survives unless the source defines that name or
///   the baseline says the last mirror copied it (`mcpServers`,
///   `mcpServerRoot`), in which case Orca drops it on its next launch.
extension OrcaIntegration {
    /// Where one MCP server of an Orca home comes from.
    enum McpOrigin: Equatable, Sendable {
        /// Same definition as the source entry Orca copies it from.
        case mirrored
        /// The source owns this entry but defines it differently or no longer
        /// has it: Orca replaces or removes the copy on its next launch.
        case mirrorDiffers
        /// Only this account has it; Orca preserves it.
        case accountOnly
    }

    /// `claude-code:orca:<account>` → `claude-code`; other ids unchanged.
    static func baseAgentID(_ agentID: String) -> String {
        agentID.range(of: idPrefix).map { String(agentID[..<$0.lowerBound]) } ?? agentID
    }

    static func isOrcaAgentID(_ agentID: String) -> Bool { agentID.contains(idPrefix) }

    /// Pure classification. `sourceSpec` is the source's definition of the
    /// same entry; `sourceOwnsEntry` is true when Orca rewrites the entry from
    /// the source even if the source no longer has it.
    static func mcpOrigin(spec: [String: Any], sourceSpec: [String: Any]?, sourceOwnsEntry: Bool) -> McpOrigin {
        if let sourceSpec {
            return (spec as NSDictionary).isEqual(to: sourceSpec) ? .mirrored : .mirrorDiffers
        }
        return sourceOwnsEntry ? .mirrorDiffers : .accountOnly
    }

    /// Origins of every Orca-home entry in `entries`, keyed by entry id.
    /// Sources are looked up in the same index. `sourceProjects` maps a
    /// Claude state file to its `projects` keys (nil when unknown);
    /// `baseline` returns a Codex home's parsed baseline.
    static func mcpOrigins(_ entries: [McpServerEntry],
                           sourceProjects: (String) -> Set<String>?,
                           baseline: (String) -> CodexBaselineObservation) -> [String: McpOrigin] {
        var bySource: [String: McpServerEntry] = [:]
        for entry in entries where !isOrcaAgentID(entry.agentID) {
            bySource[lookupKey(path: entry.sourcePath, keyPath: entry.sourceKeyPath, name: entry.name)] = entry
        }
        var baselines: [String: CodexSettingsBaseline?] = [:]
        var out: [String: McpOrigin] = [:]
        for entry in entries where isOrcaAgentID(entry.agentID) {
            guard let home = home(containing: entry.sourcePath), let relation = relation(for: entry.sourcePath),
                  relation != .accountOwned, let source = sourcePath(for: entry.sourcePath) else {
                out[entry.id] = .accountOnly
                continue
            }
            let sourceEntry = bySource[lookupKey(path: source, keyPath: entry.sourceKeyPath, name: entry.name)]
            var owns = relation == .mirroredCopy
            if relation == .mergedState {
                switch home.kind {
                case .claude:
                    // projects.<path>.mcpServers: a source project replaces the record.
                    if entry.sourceKeyPath.count == 3, entry.sourceKeyPath[0] == "projects" {
                        owns = sourceProjects(source)?.contains(entry.sourceKeyPath[1]) ?? false
                    }
                case .codex:
                    if baselines[home.path] == nil {
                        if case let .present(parsed) = baseline(home.path) { baselines[home.path] = parsed }
                        else { baselines[home.path] = .some(nil) }
                    }
                    if let parsed = baselines[home.path] ?? nil {
                        owns = parsed.mcpServerRoot || parsed.mcpServers.contains(entry.name)
                    }
                }
            }
            out[entry.id] = mcpOrigin(spec: entry.raw, sourceSpec: sourceEntry?.raw, sourceOwnsEntry: owns)
        }
        return out
    }

    private static func lookupKey(path: String, keyPath: [String], name: String) -> String {
        ([path] + keyPath + [name]).joined(separator: "\u{1F}")
    }

    /// The regular file a server of an Orca home can be promoted to: the
    /// Claude state or Codex config Orca copies from. nil outside Orca homes.
    static func promotionTarget(for entry: McpServerEntry) -> String? {
        guard isOrcaAgentID(entry.agentID), let home = home(containing: entry.sourcePath) else { return nil }
        switch home.kind {
        case .claude:
            return sourcePath(for: home.path + "/.claude.json")
        case .codex:
            return sourcePath(for: home.path + "/config.toml")
        }
    }

    // MARK: - Codex settings baseline

    static let codexBaselineFileName = ".orca-config-settings-baseline.json"
    /// Larger baselines are discarded by Orca too; never read them whole.
    static let codexBaselineByteLimit = 1_000_000

    /// What AgentsConfig keeps from `.orca-config-settings-baseline.json`.
    /// Conflict values are never kept: they may hold any config value.
    struct CodexSettingsBaseline: Equatable, Sendable {
        var version: Int
        /// MCP server names the last mirror copied from the Codex config.
        var mcpServers: Set<String>
        /// The last mirror owned the whole `mcp_servers` table (or the
        /// baseline predates per-server ownership).
        var mcpServerRoot: Bool
        /// Promoted keys whose account and Codex config values diverged
        /// without a common baseline, sorted.
        var conflictKeys: [String]
    }

    enum CodexBaselineObservation: Equatable, Sendable {
        case absent
        case present(CodexSettingsBaseline)
        /// Valid JSON, but not a baseline version/shape Orca 1.4.246 writes.
        case unrecognized(version: String?)
        /// Not JSON, or too large: Orca discards it and rebuilds it.
        case invalid
        /// Exists but cannot be read: Orca stalls the mirror for this home.
        case unreadable
    }

    /// Tolerant, pure parser; never throws or traps on hostile input.
    static func parseCodexBaseline(_ data: Data) -> CodexBaselineObservation {
        guard data.count <= codexBaselineByteLimit,
              let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return .invalid }
        guard let object = json as? [String: Any] else { return .unrecognized(version: nil) }
        let version = integer(object["version"])
        guard let version, (1...3).contains(version), object["settings"] is [String: Any] else {
            return .unrecognized(version: version.map(String.init) ?? (object["version"] as? String).map { sanitizedKey($0) })
        }
        var conflictKeys: [String] = []
        for (key, value) in object["conflicts"] as? [String: Any] ?? [:] {
            guard let conflict = value as? [String: Any],
                  let runtime = conflict["runtime"], runtime is String || runtime is NSNull,
                  let system = conflict["system"], system is String || system is NSNull else { continue }
            conflictKeys.append(key)
        }
        let storedServers = object["mcpServers"]
        let servers = (storedServers as? [Any])?.compactMap { $0 as? String } ?? []
        return .present(CodexSettingsBaseline(
            version: version,
            mcpServers: Set(servers),
            mcpServerRoot: storedServers == nil || isTrue(object["mcpServerRoot"]),
            conflictKeys: conflictKeys.sorted()))
    }

    /// Reads the baseline of a Codex home (`<home>/.orca-config-settings-baseline.json`).
    static func readCodexBaseline(home: String) -> CodexBaselineObservation {
        let path = (home as NSString).appendingPathComponent(codexBaselineFileName)
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return .absent }
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > codexBaselineByteLimit { return .invalid }
        guard let handle = FileHandle(forReadingAtPath: path) else { return .unreadable }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: codexBaselineByteLimit + 1) else { return .unreadable }
        return parseCodexBaseline(data)
    }

    /// Notices for a Codex home's `config.toml` from its baseline. Static
    /// texts plus key names only: values are never shown.
    @MainActor static func codexBaselineIssues(_ observation: CodexBaselineObservation) -> [FileIssue] {
        switch observation {
        case .absent:
            return []
        case .present(let baseline):
            let shown = baseline.conflictKeys.prefix(maxListedConflicts)
            var issues = shown.map {
                FileIssue(severity: .warning, message: L("Orca keeps this account's value of “%@” in this home and does not copy it to the Codex config: both sides changed it without a common baseline. The next change on only one side decides which value wins.", sanitizedKey($0)))
            }
            if baseline.conflictKeys.count > shown.count {
                issues.append(FileIssue(severity: .warning, message: L("%d more keys in conflict between this account and the Codex config.", baseline.conflictKeys.count - shown.count)))
            }
            return issues
        case .unrecognized(let version?):
            return [FileIssue(severity: .info, message: L("Orca's settings baseline for this home has a format AgentsConfig does not recognize (version %@). Conflicts with the Codex config are not shown.", version))]
        case .unrecognized(nil):
            return [FileIssue(severity: .info, message: L("Orca's settings baseline for this home has a format AgentsConfig does not recognize. Conflicts with the Codex config are not shown."))]
        case .invalid:
            return [FileIssue(severity: .info, message: L("Orca's settings baseline for this home is not valid JSON. Orca discards it and rebuilds it on its next launch, forgetting earlier conflicts."))]
        case .unreadable:
            return [FileIssue(severity: .warning, message: L("Orca's settings baseline for this home cannot be read. Orca does not sync this home's config until it can."))]
        }
    }

    /// Baseline notices for `path` when it is the `config.toml` of an Orca
    /// Codex home; empty for any other file.
    @MainActor static func codexBaselineIssues(configPath path: String) -> [FileIssue] {
        guard let home = home(containing: path), home.kind == .codex, path == home.path + "/config.toml" else { return [] }
        return codexBaselineIssues(readCodexBaseline(home: home.path))
    }

    private static let maxListedConflicts = 12

    /// Key names come from a file: one line, bounded length.
    private static func sanitizedKey(_ key: String) -> String {
        let flat = String(key.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
        return flat.count > 64 ? String(flat.prefix(63)) + "…" : flat
    }

    /// JSON integer that is not a boolean (`true` bridges to 1).
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 1e9 else { return nil }
        return Int(double)
    }

    private static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }
}

// MARK: - Comparator helpers

extension ConfigStore {
    func orcaMcpOrigin(_ entry: McpServerEntry) -> OrcaIntegration.McpOrigin? { orcaMcpOrigins[entry.id] }

    /// True for an Orca-home server identical to its source: it adds no
    /// information to comparisons and is shown next to its source instead.
    func isOrcaMirror(_ entry: McpServerEntry) -> Bool { orcaMcpOrigins[entry.id] == .mirrored }

    /// The regular entry an Orca-home server is copied from, if indexed.
    func orcaMcpSource(of entry: McpServerEntry) -> McpServerEntry? {
        guard OrcaIntegration.isOrcaAgentID(entry.agentID),
              let source = OrcaIntegration.sourcePath(for: entry.sourcePath) else { return nil }
        return mcpIndex.first {
            !OrcaIntegration.isOrcaAgentID($0.agentID) && $0.sourcePath == source
                && $0.sourceKeyPath == entry.sourceKeyPath && $0.name == entry.name
        }
    }

    /// Orca-home servers that mirror `entry` with the same definition.
    func orcaMirrors(of entry: McpServerEntry) -> [McpServerEntry] {
        guard !OrcaIntegration.isOrcaAgentID(entry.agentID) else { return [] }
        return mcpIndex.filter { isOrcaMirror($0) && orcaMcpSource(of: $0)?.id == entry.id }
    }
}
