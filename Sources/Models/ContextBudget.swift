import Foundation

/// One line of the context budget: a file (instruction or skill) or an MCP
/// server, with the bytes it would add and the rough token estimate.
struct ContextBudgetItem: Identifiable {
    enum Kind: String { case instruction = "Instructions", skill = "Skills", mcp = "MCP" }
    /// `counted` adds to the total; `conditional` may load (rules, unverified
    /// plugins); `excluded` is listed for completeness only.
    enum Inclusion: String { case counted = "Counted", conditional = "Conditional", excluded = "Not loaded" }
    var id: String { kind.rawValue + "|" + path + "|" + label }
    let kind: Kind
    let path: String
    let label: String
    let bytes: Int
    let inclusion: Inclusion
    let reason: String
    var estimatedTokens: Int { ContextBudget.estimateTokens(bytes: bytes) }
}

/// Context an agent would load before any task, estimated from files only
/// (issue #20). Pure: built from an existing `KnowledgeAnalysis` and the MCP
/// comparison, no file reads, no tokenizer, no MCP process.
struct ContextBudget {
    var items: [ContextBudgetItem] = []
    var threshold: Int
    var mcpServers: Int = 0

    /// Rough rule of thumb (≈ 4 bytes per token for English prose and code);
    /// labelled as an estimate everywhere it is shown.
    static func estimateTokens(bytes: Int) -> Int { (max(0, bytes) + 3) / 4 }

    func tokens(_ kind: ContextBudgetItem.Kind? = nil, _ inclusion: ContextBudgetItem.Inclusion = .counted) -> Int {
        items.filter { (kind == nil || $0.kind == kind) && $0.inclusion == inclusion }.map(\.estimatedTokens).reduce(0, +)
    }
    var total: Int { tokens() }
    var exceedsThreshold: Bool { total > threshold }

    /// Instructions count their included bytes (after Codex's byte budget);
    /// imports are separate rows of the analysis, so they count too. Skills
    /// contribute only `name` + `description`: bodies load on invocation.
    static func build(knowledge: KnowledgeAnalysis, mcp: [McpComparedSource], threshold: Int) -> ContextBudget {
        var budget = ContextBudget(threshold: threshold)
        for source in knowledge.instructions {
            let inclusion: ContextBudgetItem.Inclusion
            switch source.state {
            case "Candidate", "Truncated": inclusion = .counted
            case "Conditional": inclusion = .conditional
            default: inclusion = .excluded
            }
            let bytes = inclusion == .excluded ? 0 : source.state == "Conditional" ? source.bytes : source.includedBytes
            budget.items.append(.init(kind: .instruction, path: source.path, label: URL(fileURLWithPath: source.path).lastPathComponent,
                                      bytes: bytes, inclusion: inclusion,
                                      reason: source.importedBy == nil ? source.state : "Imported"))
        }
        for skill in knowledge.skills {
            let inclusion: ContextBudgetItem.Inclusion
            switch skill.state {
            case "Manual invocation", "Shadowed by scope": inclusion = .excluded
            case "Activation not verified": inclusion = .conditional
            default: inclusion = .counted
            }
            budget.items.append(.init(kind: .skill, path: skill.path, label: skill.name,
                                      bytes: inclusion == .excluded ? 0 : skill.name.utf8.count + skill.description.utf8.count,
                                      inclusion: inclusion, reason: skill.state))
        }
        let active = mcp.filter { !["Outside context", "Shadowed", "Disabled"].contains($0.state) }
        var names = Set<String>()
        for source in active where names.insert(source.entry.name).inserted {
            budget.items.append(.init(kind: .mcp, path: source.entry.sourcePath, label: source.entry.name, bytes: 0,
                                      inclusion: .conditional, reason: source.state))
        }
        budget.mcpServers = names.count
        budget.items.sort { ($0.inclusion == .counted ? 0 : 1, -$0.bytes, $0.label) < ($1.inclusion == .counted ? 0 : 1, -$1.bytes, $1.label) }
        return budget
    }
}
