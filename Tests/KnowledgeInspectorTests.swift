import Foundation
import Testing

extension AgentsConfigTestSuite {
@Suite("Instructions and skills", .serialized) @MainActor
struct KnowledgeInspectorTests {
    @Test func yamlFrontmatterSupportsBlocksListsAndFlags() {
        let parsed = Frontmatter.parse("""
        ---
        name: example
        description: |
          A multiline description.
          More detail.
        paths:
          - "src/**/*.swift"
          - "Tests/**"
        disable-model-invocation: true
        ---
        # Body
        """)
        #expect(parsed.issue == nil)
        #expect(parsed.header?.description?.contains("\n") == true)
        #expect(parsed.header?.paths?.values == ["src/**/*.swift", "Tests/**"])
        #expect(parsed.header?.disableModelInvocation == true)
        #expect(parsed.body == "# Body")
        #expect(Frontmatter.parse("---\nname: [invalid]\n---\n").issue != nil)
    }
    @Test func packageResourcesAndSharedConsumersAreVisible() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.installAllAgents()
        try env.write(".agents/skills/sample/SKILL.md", "---\nname: sample\ndescription: Sample fixture\n---\n[Missing](references/missing.md)\n[safe](references/safe.md)\n")
        try env.write(".agents/skills/sample/references/safe.md", "# Safe fixture")
        let store = env.makeStore()
        let context = AnalysisContext()
        let report = store.knowledgeAnalysis(context, configuration: store.configurationAnalysis(context))
        let package = try #require(report.skills.first { $0.name == "sample" })
        #expect(package.consumers.contains("Codex"))
        #expect(package.consumers.contains("Gemini CLI"))
        #expect(package.resources.contains { $0.name == "references/missing.md" && $0.state == "Missing" })
        #expect(package.resources.contains { $0.name == "references/safe.md" && $0.state == "Available" })
    }
    @Test func importsStayInsideScopeAndCyclesStop() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let project = try env.makeProjectRoot(); defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, "CLAUDE.md", "@inside.md\n@../outside.md\n")
        try env.write(root: project, "inside.md", "@CLAUDE.md\n")
        let store = env.makeStore(); store.addProject(path: project.path)
        let context = AnalysisContext(agentID: "claude-code", projectRoot: project.path)
        let report = store.knowledgeAnalysis(context, configuration: store.configurationAnalysis(context))
        #expect(report.instructions.contains { $0.state == "Outside scope" })
        #expect(report.instructions.contains { $0.state == "Already included" })
        #expect(report.instructions.count <= 5)
    }
    @Test func codexOverridesAndByteBudgetAreExplained() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.write(".codex/config.toml", "project_doc_max_bytes = 16")
        let project = try env.makeProjectRoot(); defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, "AGENTS.override.md", String(repeating: "x", count: 24))
        try env.write(root: project, "AGENTS.md", "# Normal")
        let store = env.makeStore(); store.addProject(path: project.path)
        let context = AnalysisContext(projectRoot: project.path)
        let report = store.knowledgeAnalysis(context, configuration: store.configurationAnalysis(context))
        #expect(report.instructions.contains { $0.path.hasSuffix("AGENTS.override.md") && $0.state == "Truncated" })
        #expect(report.instructions.contains { $0.path.hasSuffix("/AGENTS.md") && $0.state == "Replaced" })
        #expect(report.instructions.reduce(0) { $0 + $1.includedBytes } == 16)
    }
    @Test func geminiSkillCollisionUsesWorkspaceAliasPriority() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.installGemini()
        let text = "---\nname: sample\ndescription: Fixture\n---\n"
        try env.write(".gemini/skills/sample/SKILL.md", text)
        let project = try env.makeProjectRoot(); defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, ".agents/skills/sample/SKILL.md", text)
        let store = env.makeStore(); store.addProject(path: project.path)
        let context = AnalysisContext(agentID: "gemini-cli", projectRoot: project.path)
        let report = store.knowledgeAnalysis(context, configuration: store.configurationAnalysis(context))
        #expect(report.skills.first { $0.path.hasPrefix(project.path) }?.state == "Preferred by scope")
        #expect(report.skills.first { !$0.path.hasPrefix(project.path) }?.state == "Shadowed by scope")
    }
    @Test func pathGlobsAndImportOrderRemainDeterministic() {
        #expect(KnowledgeGlob.matches("src/main.swift", pattern: "src/**/*.swift") == true)
        #expect(KnowledgeGlob.matches("src/main.py", pattern: "src/**/*.swift") == false)
        #expect(KnowledgeGlob.matches("src/main.swift", pattern: "{src,test}/*") == nil)
        #expect(KnowledgeInspector.references(in: "@z.md\n@a.md\n@z.md", importsOnly: true) == ["z.md", "a.md"])
    }
    @Test func customGeminiNamesAndClaudeExclusionsAreApplied() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let project = try env.makeProjectRoot(); defer { try? FileManager.default.removeItem(at: project) }
        try env.write(".gemini/settings.json", #"{"context":{"fileName":"TEAM.md"}}"#)
        try env.write(root: project, "TEAM.md", "# Team fixture")
        try env.write(root: project, "GEMINI.md", "# Default")
        try env.write(root: project, "CLAUDE.md", "# Excluded")
        try env.write(".claude/settings.json", #"{"claudeMdExcludes":["**/CLAUDE.md"]}"#)
        let store = env.makeStore(); store.addProject(path: project.path)
        var context = AnalysisContext(agentID: "gemini-cli", projectRoot: project.path)
        var result = store.knowledgeAnalysis(context, configuration: store.configurationAnalysis(context))
        #expect(result.instructions.contains { $0.path.hasSuffix("/TEAM.md") })
        #expect(!result.instructions.contains { $0.path.hasSuffix("/GEMINI.md") })
        context.agentID = "claude-code"
        result = store.knowledgeAnalysis(context, configuration: store.configurationAnalysis(context))
        #expect(result.instructions.contains { $0.path.hasSuffix("/CLAUDE.md") && $0.state == "Excluded" && $0.text.isEmpty })
    }

    @Test func linkedResourcesCannotEscapeTheirPackage() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.write("package/SKILL.md", "# Fixture")
        try env.write("outside.md", "# Outside")
        try FileManager.default.createSymbolicLink(atPath: env.path("package/link.md"), withDestinationPath: "../outside.md")
        #expect(KnowledgeInspector.safeReference("link.md", base: env.path("package"), boundary: env.path("package")) == nil)
    }
}
}

