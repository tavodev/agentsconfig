import Foundation

/// A file or definition that should match across agent families but does
/// not (issue #19). Only detected — aligning always goes through a review.
struct Divergence: Identifiable {
    enum Kind: String, CaseIterable { case instructions = "Instructions", skills = "Skills", mcp = "MCP" }
    struct Member: Identifiable {
        var id: String { family + "|" + path }
        let family: String
        let familyName: String
        let path: String
        let text: String
    }
    var id: String { kind.rawValue + "|" + scope + "|" + subject }
    let kind: Kind
    /// Project root, or empty for the global (user-level) files.
    let scope: String
    let subject: String
    /// Present definitions; for instructions and skills each has its own text.
    let members: [Member]
    /// Families inspected in this scope that lack the subject (skills only).
    let missingFamilies: [String]
    let summary: String
}

/// Pure detection over already loaded texts. Never reads servers, never
/// writes; `read` returns a loaded document's text (nil = absent).
@MainActor enum DivergenceDetector {
    /// Root instruction file per family, relative to its user root (global)
    /// or the project root (local).
    static let instructionFiles: [(family: String, global: String, local: String)] = [
        ("claude-code", "CLAUDE.md", "CLAUDE.md"), ("codex", "AGENTS.md", "AGENTS.md"),
        ("gemini-cli", "GEMINI.md", "GEMINI.md"), ("opencode", "AGENTS.md", "AGENTS.md"),
    ]

    /// Where a copied skill lands for a family (relative to the user root of
    /// that family, or to the project root). Codex reads `~/.agents/skills`.
    static func skillDestination(family: String, name: String, scope: String) -> String? {
        let base: String
        switch (family, scope.isEmpty) {
        case ("claude-code", true): base = AgentCatalog.root(for: family) + "/skills"
        case ("claude-code", false): base = scope + "/.claude/skills"
        case ("codex", true): base = AppPaths.expand("~/.agents/skills")
        case ("codex", false), ("antigravity", false): base = scope + "/.agents/skills"
        case ("gemini-cli", true): base = AgentCatalog.root(for: family) + "/skills"
        case ("gemini-cli", false): base = scope + "/.gemini/skills"
        case ("opencode", true): base = AgentCatalog.root(for: family) + "/skills"
        case ("opencode", false): base = scope + "/.opencode/skills"
        case ("antigravity", true): base = AgentCatalog.root(for: family) + "/skills"
        default: return nil
        }
        return base + "/" + name + "/SKILL.md"
    }

    static func detect(agents: [Agent], scope: String, mcp: [McpComparedSource],
                       read: (String) -> String?) -> [Divergence] {
        let inScope = agents.filter { scope.isEmpty ? $0.projectRoot == nil : $0.projectRoot == scope && $0.submodulePath == nil }
        let families = Set(inScope.map(family))
        func name(_ family: String) -> String {
            AgentRegistry.definitions.first { $0.id == family }?.name ?? family
        }
        return instructions(families: families, scope: scope, name: name, read: read)
            + skills(agents: inScope, families: families, scope: scope, name: name, read: read)
            + mcpDefinitions(mcp, scope: scope, name: name)
    }

    static func family(_ agent: Agent) -> String { agent.id.components(separatedBy: "::")[0] }

    /// Trailing whitespace and line endings do not count as a difference.
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A file made only of `@import` lines pointing at other members (e.g. a
    /// CLAUDE.md holding just `@AGENTS.md`) is linked, not divergent.
    static func isImportOnly(_ text: String, of others: [String]) -> Bool {
        let lines = normalized(text).components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { line in
            line.hasPrefix("@") && others.contains { URL(fileURLWithPath: $0).lastPathComponent == String(line.dropFirst()) }
        }
    }

    private static func instructions(families: Set<String>, scope: String, name: (String) -> String,
                                      read: (String) -> String?) -> [Divergence] {
        var members: [Divergence.Member] = []
        var seen = Set<String>()
        for entry in instructionFiles where families.contains(entry.family) {
            let path = scope.isEmpty ? AgentCatalog.root(for: entry.family) + "/" + entry.global : scope + "/" + entry.local
            let canonical = AppPaths.canonicalPath(path) ?? path
            guard let text = read(path), !normalized(text).isEmpty else { continue }
            if seen.insert(canonical).inserted {
                members.append(.init(family: entry.family, familyName: name(entry.family), path: path, text: text))
            }
        }
        let paths = members.map(\.path)
        let substantive = members.filter { member in !isImportOnly(member.text, of: paths.filter { $0 != member.path }) }
        guard Set(substantive.map { normalized($0.text) }).count > 1 else { return [] }
        let subject = Array(Set(members.map { URL(fileURLWithPath: $0.path).lastPathComponent })).sorted().joined(separator: " · ")
        return [.init(kind: .instructions, scope: scope, subject: subject, members: substantive,
                      missingFamilies: [], summary: "Instruction files for different agents say different things.")]
    }

    private static func skills(agents: [Agent], families: Set<String>, scope: String, name: (String) -> String,
                               read: (String) -> String?) -> [Divergence] {
        // name → family → member (writable skills only: plugins and system
        // skills are installed by their managers).
        var byName: [String: [String: Divergence.Member]] = [:]
        var skillFamilies = Set<String>()
        for agent in agents {
            let owner = family(agent)
            guard skillDestination(family: owner, name: "x", scope: scope) != nil else { continue }
            skillFamilies.insert(owner)
            for file in agent.files where file.role == .skills && file.exists && !file.readOnly
                && URL(fileURLWithPath: file.path).lastPathComponent == "SKILL.md" {
                guard let text = read(file.path) else { continue }
                let skill = URL(fileURLWithPath: file.path).deletingLastPathComponent().lastPathComponent
                if byName[skill]?[owner] == nil {
                    byName[skill, default: [:]][owner] = .init(family: owner, familyName: name(owner), path: file.path, text: text)
                }
            }
        }
        var out: [Divergence] = []
        for (skill, present) in byName.sorted(by: { $0.key < $1.key }) {
            let missing = skillFamilies.subtracting(present.keys).filter(families.contains).sorted()
            let members = present.values.sorted { $0.family < $1.family }
            let distinctPaths = Set(members.map { AppPaths.canonicalPath($0.path) ?? $0.path })
            let differs = distinctPaths.count > 1 && Set(members.map { normalized($0.text) }).count > 1
            guard differs || !missing.isEmpty else { continue }
            out.append(.init(kind: .skills, scope: scope, subject: skill, members: members, missingFamilies: missing,
                             summary: differs ? "Copies of this skill differ between agents." : "This skill is installed for some agents only."))
        }
        return out
    }

    /// Same server name, different definitions across families. Client-only
    /// options are ignored: they never match across dialects (see #17).
    private static func mcpDefinitions(_ sources: [McpComparedSource], scope: String, name: (String) -> String) -> [Divergence] {
        let active = sources.filter { !["Outside context", "Shadowed"].contains($0.state) }
        var out: [Divergence] = []
        for (server, rows) in Dictionary(grouping: active, by: \.entry.name).sorted(by: { $0.key < $1.key }) {
            let byFamily = Dictionary(grouping: rows, by: { McpComparison.family($0.entry) })
            guard byFamily.count > 1 else { continue }
            let signatures = Set(byFamily.values.compactMap { $0.first.map { comparableSignature($0.entry) } })
            guard signatures.count > 1 else { continue }
            let members = byFamily.keys.sorted().compactMap { key -> Divergence.Member? in
                guard let entry = byFamily[key]?.first?.entry else { return nil }
                return .init(family: key, familyName: name(key), path: entry.sourcePath, text: "")
            }
            out.append(.init(kind: .mcp, scope: scope, subject: server, members: members, missingFamilies: [],
                             summary: "Agents define this server differently."))
        }
        return out
    }

    static func comparableSignature(_ entry: McpServerEntry) -> String {
        let value = McpComparison.normalized(entry).filter { !$0.key.hasPrefix("clientOptions:") }
        return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).map { $0.base64EncodedString() } ?? ""
    }
}
