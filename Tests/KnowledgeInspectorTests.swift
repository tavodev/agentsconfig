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

    // Issue #27: Claude Code reads AGENTS.md when no CLAUDE file exists in the working folder or above.
    @Test func claudeReadsAgentsMdWithoutClaudeFiles() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let project = try env.makeProjectRoot(); defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, "AGENTS.md", "# Shared fixture\n@docs/extra.md\n")
        try env.write(root: project, "docs/extra.md", "# Extra fixture")
        try env.write(root: project, ".claude/AGENTS.md", "# Nested fixture")
        try env.write(root: project, "pkg/CLAUDE.md", "# Below the working folder")
        let store = env.makeStore(); store.addProject(path: project.path)
        let context = AnalysisContext(agentID: "claude-code", projectRoot: project.path)
        let report = store.knowledgeAnalysis(context, configuration: store.configurationAnalysis(context))
        let agents = try #require(report.instructions.first { $0.path.hasSuffix("/AGENTS.md") && !$0.path.hasSuffix(".claude/AGENTS.md") })
        #expect(agents.state == "Candidate" && agents.reason.contains("No CLAUDE.md") && agents.includedBytes == agents.bytes)
        #expect(report.instructions.contains { $0.path.hasSuffix(".claude/AGENTS.md") && $0.state == "Candidate" })
        #expect(report.instructions.contains { $0.path.hasSuffix("docs/extra.md") && $0.importedBy == agents.path })
        #expect(!report.instructions.contains { $0.path.hasSuffix("pkg/CLAUDE.md") })
        let budget = ContextBudget.build(knowledge: report, mcp: [], threshold: 8_000)
        #expect(budget.items.contains { $0.label == "AGENTS.md" && $0.inclusion == .counted && $0.bytes > 0 })
        #expect(budget.tokens(.instruction) > 0)
    }
    @Test func claudeFilesInTheChainReplaceAgentsMd() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let project = try env.makeProjectRoot(); defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, "CLAUDE.md", "# Root fixture")
        try env.write(root: project, "AGENTS.md", "# Shared fixture")
        try env.write(root: project, "pkg/AGENTS.md", "# Package fixture")
        let store = env.makeStore(); store.addProject(path: project.path)
        // Same folder: CLAUDE.md wins and AGENTS.md is not read through the fallback.
        var context = AnalysisContext(agentID: "claude-code", projectRoot: project.path)
        var report = store.knowledgeAnalysis(context, configuration: store.configurationAnalysis(context))
        #expect(report.instructions.contains { $0.path.hasSuffix("/CLAUDE.md") && $0.state == "Candidate" })
        let replaced = try #require(report.instructions.first { $0.path.hasSuffix("/AGENTS.md") })
        #expect(replaced.state == "Replaced" && replaced.includedBytes == 0 && replaced.reason.contains("takes precedence"))
        #expect(ContextBudget.build(knowledge: report, mcp: [], threshold: 8_000).items.contains { $0.label == "AGENTS.md" && $0.inclusion == .excluded })
        // CLAUDE.md in a parent folder also counts for a working folder below it.
        context.workingDirectory = project.path + "/pkg"
        report = store.knowledgeAnalysis(context, configuration: store.configurationAnalysis(context))
        #expect(report.instructions.contains { $0.path.hasSuffix("pkg/AGENTS.md") && $0.state == "Replaced" })
        #expect(!report.instructions.contains { $0.path.hasSuffix("AGENTS.md") && $0.state == "Candidate" })
        // CLAUDE.local.md counts too.
        try FileManager.default.removeItem(at: project.appendingPathComponent("CLAUDE.md"))
        try env.write(root: project, "CLAUDE.local.md", "# Local fixture")
        let fresh = env.makeStore(); fresh.addProject(path: project.path)
        report = fresh.knowledgeAnalysis(context, configuration: fresh.configurationAnalysis(context))
        #expect(!report.instructions.contains { $0.path.hasSuffix("/CLAUDE.md") })
        #expect(report.instructions.contains { $0.path.hasSuffix("/CLAUDE.local.md") && $0.state == "Candidate" })
        #expect(report.instructions.filter { $0.path.hasSuffix("AGENTS.md") }.count == 2)
        #expect(report.instructions.filter { $0.path.hasSuffix("AGENTS.md") }.allSatisfy { $0.state == "Replaced" })
    }
    @Test func claudeImportedAgentsMdIsNotListedTwice() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let project = try env.makeProjectRoot(); defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, "CLAUDE.md", "@AGENTS.md\n")
        try env.write(root: project, "AGENTS.md", "# Shared fixture")
        let store = env.makeStore(); store.addProject(path: project.path)
        let context = AnalysisContext(agentID: "claude-code", projectRoot: project.path)
        let report = store.knowledgeAnalysis(context, configuration: store.configurationAnalysis(context))
        let rows = report.instructions.filter { $0.path.hasSuffix("/AGENTS.md") }
        #expect(rows.count == 1 && rows.first?.state == "Candidate" && rows.first?.importedBy?.hasSuffix("/CLAUDE.md") == true)
    }
    @Test func claudeProjectInstructionsSettingIsRespected() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let project = try env.makeProjectRoot(); defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, "CLAUDE.md", "# Root fixture")
        try env.write(root: project, "AGENTS.md", "# Shared fixture")
        func setting(_ plugin: String, _ value: String) -> String {
            #"{"pluginConfigs":{""# + plugin + #"":{"options":{"instructionFiles":""# + value + #""}}}}"#
        }
        var context = AnalysisContext(agentID: "claude-code", projectRoot: project.path)
        // A fresh store per step: files change faster than the cached documents' modification times.
        func freshStore() -> ConfigStore { let store = env.makeStore(); store.addProject(path: project.path); return store }
        func analyze() -> KnowledgeAnalysis {
            let store = freshStore()
            return store.knowledgeAnalysis(context, configuration: store.configurationAnalysis(context))
        }
        // Ignored in project and local settings files.
        try env.write(root: project, ".claude/settings.json", setting("cc-plugin-agents-md@builtin", "claude-md-and-agents-md"))
        let configuration = freshStore().configurationAnalysis(context)
        #expect(configuration.settings.contains { $0.name.hasSuffix("instructionFiles") && $0.state == "Excluded" })
        #expect(analyze().instructions.contains { $0.path.hasSuffix("/AGENTS.md") && $0.state == "Replaced" })
        // User settings: both files, CLAUDE.md first.
        try env.write(".claude/settings.json", setting("cc-plugin-agents-md@builtin", "claude-md-and-agents-md"))
        var report = analyze()
        let claude = try #require(report.instructions.firstIndex { $0.path.hasSuffix("/CLAUDE.md") })
        let agents = try #require(report.instructions.firstIndex { $0.path.hasSuffix("/AGENTS.md") })
        #expect(claude < agents && report.instructions[agents].state == "Candidate" && report.instructions[agents].reason.contains("claude-md-and-agents-md"))
        // The legacy plugin ID is read too; claude-md never reads AGENTS.md.
        try env.write(".claude/settings.json", setting("agents-md@builtin", "claude-md"))
        report = analyze()
        #expect(report.instructions.contains { $0.path.hasSuffix("/AGENTS.md") && $0.state == "Excluded" && $0.includedBytes == 0 })
        // managed-only leaves out project CLAUDE.md and AGENTS.md.
        try env.write(".claude/settings.json", setting("cc-plugin-agents-md@builtin", "managed-only"))
        report = analyze()
        #expect(report.instructions.count == 2 && report.instructions.allSatisfy { $0.state == "Excluded" && $0.reason.contains("managed-only") })
        #expect(report.instructions.reduce(0) { $0 + $1.includedBytes } == 0)
        // An undocumented value stays conditional.
        try env.write(".claude/settings.json", setting("cc-plugin-agents-md@builtin", "fixture-value"))
        #expect(analyze().instructions.contains { $0.path.hasSuffix("/AGENTS.md") && $0.state == "Conditional" })
        // Before 2.1.277 AGENTS.md is not read directly; before 2.1.285 only the legacy plugin ID counts.
        try FileManager.default.removeItem(at: project.appendingPathComponent("CLAUDE.md"))
        context.version = "2.1.276"
        #expect(analyze().instructions.contains { $0.path.hasSuffix("/AGENTS.md") && $0.state == "Excluded" && $0.reason.contains("2.1.277") })
        try env.write(".claude/settings.json", setting("cc-plugin-agents-md@builtin", "claude-md"))
        context.version = "2.1.280"
        #expect(analyze().instructions.contains { $0.path.hasSuffix("/AGENTS.md") && $0.state == "Candidate" })
        context.version = "2.1.285"
        #expect(analyze().instructions.contains { $0.path.hasSuffix("/AGENTS.md") && $0.state == "Excluded" })
    }
    @Test func claudeImportsStopAfterFourHops() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let project = try env.makeProjectRoot(); defer { try? FileManager.default.removeItem(at: project) }
        let chain = ["a", "b", "c", "d", "e"]
        for (index, name) in chain.enumerated() {
            try env.write(root: project, name + ".md", index + 1 < chain.count ? "@" + chain[index + 1] + ".md\n" : "# Last fixture")
        }
        try env.write(root: project, "CLAUDE.md", "@a.md\n")
        try env.write(root: project, "GEMINI.md", "@a.md\n")
        let store = env.makeStore(); store.addProject(path: project.path)
        var context = AnalysisContext(agentID: "claude-code", projectRoot: project.path)
        var report = store.knowledgeAnalysis(context, configuration: store.configurationAnalysis(context))
        for name in ["a", "b", "c", "d"] { #expect(report.instructions.contains { $0.path.hasSuffix("/\(name).md") && $0.state == "Candidate" }) }
        let fifth = try #require(report.instructions.first { $0.path.hasSuffix("/e.md") })
        #expect(fifth.state == "Not loaded" && fifth.includedBytes == 0 && fifth.importedBy?.hasSuffix("/d.md") == true)
        // Gemini CLI keeps its own five-level cap.
        context.agentID = "gemini-cli"
        report = store.knowledgeAnalysis(context, configuration: store.configurationAnalysis(context))
        #expect(report.instructions.contains { $0.path.hasSuffix("/e.md") && $0.state == "Candidate" })
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
