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

    /// Issue #31: Copilot's plugin is present on disk, but activation is not
    /// observed. Only its name and description enter the conditional budget.
    @Test func copilotInstalledPluginSkillsHaveConditionalContextCost() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let plugin = try env.write(".copilot/installed-plugins/review-kit/skills/review/SKILL.md",
                                   "---\nname: review\ndescription: Plugin fixture\n---\n" + String(repeating: "body", count: 500))
        let personal = try env.write(".copilot/skills/personal/SKILL.md",
                                     "---\nname: personal\ndescription: Personal fixture\n---\n# Instructions")
        try env.write(".copilot/installed-plugins/review-kit/mcp.json", #"{"mcpServers":{"docs":{"command":"fixture-plugin-mcp"}}}"#)
        try env.write(".copilot/mcp-config.json", #"{"mcpServers":{"docs":{"command":"fixture-user-mcp"}}}"#)
        let store = env.makeStore()
        let context = AnalysisContext(agentID: "copilot-cli")
        let knowledge = store.knowledgeAnalysis(context, configuration: store.configurationAnalysis(context))
        #expect(knowledge.skills.first { $0.path == plugin.path }?.state == "Activation not verified")
        #expect(knowledge.skills.first { $0.path == personal.path }?.state == "Discovered")
        let mcp = McpComparison.sources(store.mcpIndex.filter { McpComparison.family($0) == "copilot-cli" }, project: "")
        let budget = ContextBudget.build(knowledge: knowledge, mcp: mcp, threshold: 8_000)
        let pluginBytes = "review".utf8.count + "Plugin fixture".utf8.count
        let personalBytes = "personal".utf8.count + "Personal fixture".utf8.count
        #expect(budget.items.contains { $0.path == plugin.path && $0.kind == .skill && $0.inclusion == .conditional && $0.bytes == pluginBytes })
        #expect(budget.items.contains { $0.path == personal.path && $0.kind == .skill && $0.inclusion == .counted && $0.bytes == personalBytes })
        #expect(budget.tokens(.skill, .conditional) == ContextBudget.estimateTokens(bytes: pluginBytes))
        #expect(budget.tokens(.skill) == ContextBudget.estimateTokens(bytes: personalBytes))
        #expect(budget.mcpServers == 1)
    }

    @Test func pluginSkillActivationRequiresExactMarkersAndKeepsOtherAgents() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let fixtures = [
            ("copilot-cli", ".copilot/installed-plugins/kit/skills/review/SKILL.md", true),
            ("copilot-cli", ".copilot/installed-plugins-backup/kit/skills/review/SKILL.md", false),
            ("copilot-cli", ".copilot-extra/installed-plugins/kit/skills/review/SKILL.md", false),
            ("claude-code", ".claude/installed-plugins/kit/skills/review/SKILL.md", false),
            ("claude-code", ".claude/plugins/cache/kit/skills/review/SKILL.md", true),
            ("codex", ".codex/plugins/cache/kit/skills/review/SKILL.md", true),
            ("gemini-cli", ".gemini/extensions/kit/skills/review/SKILL.md", true),
            ("windsurf", ".codeium/windsurf/skills/review/SKILL.md", false),
        ]
        for (family, relativePath, plugin) in fixtures {
            let text = "---\nname: review\ndescription: Fixture\n---\n# Instructions"
            let file = try env.write(relativePath, text)
            let definition = AgentDefinition(id: family, name: family, symbol: "puzzlepiece", color: .gray,
                                             detectionPaths: [], sources: [.init(path: file.path, role: .skills, readOnly: true)])
            let agent = Agent(id: family, name: family, symbol: "puzzlepiece", color: .gray,
                              files: AgentRegistry.resolveFiles(definition), detectionPath: env.home.path, notes: nil)
            let context = AnalysisContext(agentID: family)
            let knowledge = KnowledgeInspector.build(context: context, agents: [agent],
                                                      configuration: ConfigurationAnalysis(context: context)) {
                $0 == file.path ? text : nil
            }
            let skill = try #require(knowledge.skills.first)
            #expect(skill.state == (plugin ? "Activation not verified" : "Discovered"), "\(relativePath)")
            let budget = ContextBudget.build(knowledge: knowledge, mcp: [], threshold: 8_000)
            #expect(budget.items.first?.inclusion == (plugin ? .conditional : .counted), "\(relativePath)")
        }
    }
}
}
