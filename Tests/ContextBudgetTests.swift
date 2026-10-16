import Foundation
import Testing

extension AgentsConfigTestSuite {
@Suite("Context budget", .serialized) @MainActor
struct ContextBudgetTests {
    /// Issue #20: instructions (with `@` imports), skill descriptions and MCP
    /// servers of a fictitious Claude project, estimated as bytes ÷ 4.
    @Test func estimatesInstructionsImportsSkillsAndServers() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let user = String(repeating: "u", count: 400)
        try env.write(".claude/CLAUDE.md", user)
        try env.write(".claude.json", #"{"mcpServers":{"docs":{"command":"npx","args":["-y","@fake/docs-mcp@1.0.0"]},"off":{"command":"x","disabled":true}}}"#)
        try env.write(".claude/skills/demo/SKILL.md", "---\nname: demo\ndescription: \(String(repeating: "d", count: 96))\n---\n\(String(repeating: "b", count: 4_000))")
        try env.write(".claude/skills/manual/SKILL.md", "---\nname: manual\ndescription: manual only\ndisable-model-invocation: true\n---\nbody")
        let project = try env.makeProjectRoot(); defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, "CLAUDE.md", "See @docs/guide.md\n")
        try env.write(root: project, "docs/guide.md", String(repeating: "g", count: 800))
        let store = env.makeStore(); store.addProject(path: project.path)

        let context = AnalysisContext(agentID: "claude-code", projectRoot: project.path, workingDirectory: project.path)
        let knowledge = store.knowledgeAnalysis(context, configuration: store.configurationAnalysis(context))
        let mcp = McpComparison.sources(store.mcpIndex.filter { McpComparison.family($0) == "claude-code" }, project: project.path)
        let budget = ContextBudget.build(knowledge: knowledge, mcp: mcp, threshold: 300)

        let projectFile = "See @docs/guide.md\n".utf8.count
        #expect(budget.tokens(.instruction) == ContextBudget.estimateTokens(bytes: 400)
            + ContextBudget.estimateTokens(bytes: projectFile) + ContextBudget.estimateTokens(bytes: 800))
        #expect(budget.items.contains { $0.path.hasSuffix("/docs/guide.md") && $0.inclusion == .counted && $0.reason == "Imported" })
        // Skill bodies never count; disabled model invocation is not loaded.
        #expect(budget.tokens(.skill) == ContextBudget.estimateTokens(bytes: 4 + 96))
        #expect(budget.items.first { $0.label == "manual" }?.inclusion == .excluded)
        #expect(budget.mcpServers == 1)
        #expect(budget.items.filter { $0.kind == .mcp }.allSatisfy { $0.bytes == 0 && $0.inclusion == .conditional })
        #expect(budget.total == budget.tokens(.instruction) + budget.tokens(.skill))
        #expect(budget.exceedsThreshold)
        #expect(!ContextBudget.build(knowledge: knowledge, mcp: mcp, threshold: 100_000).exceedsThreshold)
    }

    @Test func codexByteLimitAndConditionalRulesAreRespected() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let knowledge = KnowledgeAnalysis(instructions: [
            .init(path: "/fixture/AGENTS.md", state: "Truncated", reason: "", bytes: 10_000, includedBytes: 2_000, text: "", importedBy: nil),
            .init(path: "/fixture/rules/a.md", state: "Conditional", reason: "", bytes: 400, includedBytes: 400, text: "", importedBy: nil),
            .init(path: "/fixture/AGENTS.override.md", state: "Replaced", reason: "", bytes: 900, includedBytes: 0, text: "", importedBy: nil),
        ])
        let budget = ContextBudget.build(knowledge: knowledge, mcp: [], threshold: 8_000)
        #expect(budget.total == 500)
        #expect(budget.tokens(nil, .conditional) == 100)
        #expect(budget.items.first { $0.path.hasSuffix("override.md") }?.inclusion == .excluded)
        #expect(AppSettings.contextBudgetThreshold == 8_000)
        AppSettings.defaults.set(12_000, forKey: "contextBudgetThreshold")
        #expect(AppSettings.contextBudgetThreshold == 12_000)
    }
}
}
