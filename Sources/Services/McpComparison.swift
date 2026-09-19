import Foundation

struct McpComparedSource: Identifiable {
    var id: String { entry.id }
    let entry: McpServerEntry
    var state: String
    var reason: String
}
@MainActor enum McpComparison {
    static func family(_ entry: McpServerEntry) -> String { entry.agentID.components(separatedBy: "::")[0] }
    static func sources(_ entries: [McpServerEntry], project: String?, profile: String = "") -> [McpComparedSource] {
        var rows = entries.map { entry -> McpComparedSource in
            if let project {
                if let own = entry.projectPath, project.isEmpty || !(project == own || project.hasPrefix(own + "/")) {
                    return .init(entry: entry, state: "Outside context", reason: "This source belongs to another project or subfolder.")
                }
                if let own = entry.profileName, own != profile {
                    return .init(entry: entry, state: "Outside context", reason: "This Codex profile is not selected.")
                }
            }
            if entry.scope == "Extension" { return .init(entry: entry, state: "Activation not verified", reason: "Extension enablement and authentication are not observed.") }
            return .init(entry: entry, state: entry.enabled == false ? "Disabled" : "Configured",
                reason: "Configuration found on disk; connection, authentication and session policy are not verified.")
        }
        guard project != nil else { return rows }
        let groups = Dictionary(grouping: rows.indices.filter { rows[$0].state != "Outside context" },
                                by: { family(rows[$0].entry) + "|" + rows[$0].entry.name })
        for indices in groups.values {
            let ranked = indices.filter { rows[$0].state != "Activation not verified" }
            guard let high = ranked.map({ rank(rows[$0].entry) }).max() else { continue }
            let winners = ranked.filter { rank(rows[$0].entry) == high }
            let variants = Set(winners.map { signature(rows[$0].entry) })
            for index in indices {
                if !winners.contains(index) { rows[index].state = "Shadowed"; rows[index].reason = "A more specific source defines this server name." }
                else if variants.count > 1 { rows[index].state = "Ambiguous"; rows[index].reason = "Multiple definitions at the same scope disagree; no winner was inferred." }
            }
        }
        return rows
    }
    private static func rank(_ entry: McpServerEntry) -> Int {
        switch entry.scope {
        case "Managed": return 1_000
        case "Private project": return 800 + min(99, entry.projectPath?.split(separator: "/").count ?? 0)
        case "Project": return 300 + min(99, entry.projectPath?.split(separator: "/").count ?? 0)
        case "Profile": return 200
        case "Extension": return 0
        default: return 100
        }
    }
    static func normalized(_ entry: McpServerEntry) -> [String: Any] {
        let family = family(entry)
        let raw = entry.raw
        let transport: String
        if !entry.isRemote { transport = "stdio" }
        else if family == "gemini-cli" { transport = raw["httpUrl"] == nil ? "sse" : "http" }
        else if family == "opencode" { transport = "negotiated-remote" }
        else { transport = raw["type"] as? String ?? raw["transport"] as? String ?? (["cursor", "copilot-cli", "antigravity"].contains(family) ? "unspecified-remote" : "http") }
        var value: [String: Any] = ["transport": transport, "enabled": entry.enabled ?? true]
        if entry.isRemote { value["url"] = entry.url ?? "" }
        else { value["command"] = entry.command ?? ""; value["args"] = entry.args }
        value["env"] = raw[family == "opencode" ? "environment" : "env"] ?? [String: String]()
        value["headers"] = raw[family == "codex" ? "http_headers" : "headers"] ?? [String: String]()
        let common: Set<String> = ["command", "args", "url", "httpUrl", "type", "transport", "enabled", "disabled", "env", "environment", "headers", "http_headers"]
        let other = raw.filter { !common.contains($0.key) }
        if !other.isEmpty { value["clientOptions:" + family] = other }
        return value
    }
    /// Kept only in memory: signatures include raw values and must not be exported.
    static func signature(_ entry: McpServerEntry) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: normalized(entry), options: [.sortedKeys])) ?? Data()
        return data.base64EncodedString()
    }
    static func differences(_ a: McpServerEntry, _ b: McpServerEntry) -> [SemanticChange] {
        DiffEngine.diff(oldText: "", newText: "", oldTree: normalized(a), newTree: normalized(b))
    }
}

