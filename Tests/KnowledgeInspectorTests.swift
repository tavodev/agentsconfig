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
    // Issue #29: managed memory is a read-only source even when other launch instructions are disabled.
    @Test func claudeManagedOnlyIncludesManagedMemoryInContextBudget() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let project = try env.makeProjectRoot(); defer { try? FileManager.default.removeItem(at: project) }
        let managed = try env.write(".system/Library/Application Support/ClaudeCode/CLAUDE.md", "# Managed fixture\n")
        try env.write(".claude/settings.json", #"{"pluginConfigs":{"cc-plugin-agents-md@builtin":{"options":{"instructionFiles":"managed-only"}}}}"#)
        try env.write(".claude/CLAUDE.md", "# User fixture")
        try env.write(".claude/rules/preferences.md", "# User rule fixture")
        try env.write(root: project, "CLAUDE.md", "# Project fixture")
        try env.write(root: project, ".claude/CLAUDE.md", "# Project config fixture")
        try env.write(root: project, "CLAUDE.local.md", "# Local fixture")
        try env.write(root: project, "AGENTS.md", "# Shared fixture")
        let store = env.makeStore(); store.addProject(path: project.path)
        let source = try #require(store.agents.flatMap(\.files).first { $0.path == managed.path })
        #expect(source.exists && source.readOnly && source.role == .instructions)
        #expect(AppPaths.systemPath("/Library/Application Support/ClaudeCode/CLAUDE.md") == managed.path)
        let context = AnalysisContext(agentID: "claude-code", projectRoot: project.path, version: "2.1.285")
        let report = store.knowledgeAnalysis(context, configuration: store.configurationAnalysis(context))
        let first = try #require(report.instructions.first)
        #expect(first.path == managed.path && first.state == "Candidate" && first.includedBytes == first.bytes && first.bytes > 0)
        #expect(report.instructions.count == 7)
        #expect(report.instructions.dropFirst().allSatisfy { $0.state == "Excluded" && $0.includedBytes == 0 && $0.reason.contains("managed-only") })
        let budget = ContextBudget.build(knowledge: report, mcp: [], threshold: 8_000)
        #expect(budget.items.contains { $0.path == managed.path && $0.inclusion == .counted && $0.bytes == first.bytes })
        #expect(budget.tokens(.instruction) == ContextBudget.estimateTokens(bytes: first.bytes))
        #expect(budget.items.filter { $0.path != managed.path }.allSatisfy { $0.inclusion == .excluded && $0.bytes == 0 })
    }
    @Test func claudeManagedMemoryAndImportsPrecedeUserAndProject() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let project = try env.makeProjectRoot(); defer { try? FileManager.default.removeItem(at: project) }
        let managed = try env.write(".system/Library/Application Support/ClaudeCode/CLAUDE.md", "@policy.md\n@../outside.md\n")
        let policy = try env.write(".system/Library/Application Support/ClaudeCode/policy.md", "# Managed policy fixture")
        let user = try env.write(".claude/CLAUDE.md", "# User fixture")
        let local = try env.write(root: project, "CLAUDE.md", "# Project fixture")
        let store = env.makeStore(); store.addProject(path: project.path)
        let context = AnalysisContext(agentID: "claude-code", projectRoot: project.path)
        let report = store.knowledgeAnalysis(context, configuration: store.configurationAnalysis(context))
        #expect(report.instructions.filter { $0.importedBy == nil }.map(\.path) == [managed.path, user.path, local.path])
        #expect(report.instructions.prefix(2).map(\.path) == [managed.path, policy.path])
        #expect(report.instructions.contains { $0.path == policy.path && $0.state == "Candidate" && $0.importedBy == managed.path })
        #expect(report.instructions.contains { $0.path == "../outside.md" && $0.state == "Outside scope" && $0.importedBy == managed.path })
    }
    @Test func claudeMdExcludesCannotExcludeManagedMemory() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let project = try env.makeProjectRoot(); defer { try? FileManager.default.removeItem(at: project) }
        let managed = try env.write(".system/Library/Application Support/ClaudeCode/CLAUDE.md", "# Managed fixture")
        try env.write(".claude/settings.json", #"{"claudeMdExcludes":["**/CLAUDE.md"]}"#)
        try env.write(".claude/CLAUDE.md", "# User fixture")
        try env.write(root: project, "CLAUDE.md", "# Project fixture")
        let store = env.makeStore(); store.addProject(path: project.path)
        let context = AnalysisContext(agentID: "claude-code", projectRoot: project.path)
        let report = store.knowledgeAnalysis(context, configuration: store.configurationAnalysis(context))
        let first = try #require(report.instructions.first)
        #expect(first.path == managed.path && first.state == "Candidate" && first.includedBytes > 0)
        #expect(report.instructions.filter { $0.path != managed.path && $0.path.hasSuffix("/CLAUDE.md") }.allSatisfy { $0.state == "Excluded" && $0.text.isEmpty })
    }
    @Test func claudeInlineManagedInstructionsUseOnlyObservedManagedLayer() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let project = try env.makeProjectRoot(); defer { try? FileManager.default.removeItem(at: project) }
        let raw = "# Managed inline fixture\napi_key = \"sk-test-INLINE-FAKE\"\n" + String(repeating: "á", count: 22_000)
        let json = try JSONSerialization.data(withJSONObject: ["claudeMd": raw, "unrelated": "not instruction text"])
        let managed = try env.write(".system/Library/Application Support/ClaudeCode/managed-settings.json", String(decoding: json, as: UTF8.self))
        try env.write(".claude/settings.json", #"{"claudeMd":"USER-NOT-INCLUDED","pluginConfigs":{"cc-plugin-agents-md@builtin":{"options":{"instructionFiles":"managed-only"}}}}"#)
        try env.write(root: project, ".claude/settings.json", #"{"claudeMd":"PROJECT-NOT-INCLUDED"}"#)
        try env.write(root: project, ".claude/settings.local.json", #"{"claudeMd":"LOCAL-NOT-INCLUDED"}"#)
        try env.write(".claude/CLAUDE.md", "# Excluded user fixture")
        let store = env.makeStore(); store.addProject(path: project.path)
        let context = AnalysisContext(agentID: "claude-code", projectRoot: project.path)
        let report = store.knowledgeAnalysis(context, configuration: store.configurationAnalysis(context))
        let inline = report.instructions.filter { $0.keyPath == ["claudeMd"] }
        let source = try #require(inline.first)
        #expect(inline.count == 1 && source.path == managed.path && source.state == "Candidate")
        #expect(source.bytes == raw.utf8.count && source.includedBytes == source.bytes)
        #expect(source.text.count <= 20_000 && source.text.contains("# Managed inline fixture"))
        #expect(!source.text.contains("sk-test-INLINE-FAKE") && !source.text.contains("not instruction text"))
        #expect(!report.instructions.contains { $0.text.contains("NOT-INCLUDED") })
        #expect(report.instructions.contains { $0.path == env.path(".claude/CLAUDE.md") && $0.state == "Excluded" })
        let budget = ContextBudget.build(knowledge: report, mcp: [], threshold: 8_000)
        #expect(budget.items.contains { $0.path == managed.path && $0.label == "managed-settings.json → claudeMd" && $0.bytes == raw.utf8.count && $0.inclusion == .counted })
        #expect(budget.tokens(.instruction) == ContextBudget.estimateTokens(bytes: raw.utf8.count))
        var wholeFile = source; wholeFile.keyPath = []
        #expect(wholeFile.id != source.id)
    }
    @Test func claudeInlineManagedCoexistenceIsConditionalAndImportsAreNotInferred() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let managedFile = try env.write(".system/Library/Application Support/ClaudeCode/CLAUDE.md", "# Managed file fixture")
        let inline = "# Inline fixture\n@policy.md\n"
        let json = try JSONSerialization.data(withJSONObject: ["claudeMd": inline])
        let managedSettings = try env.write(".system/Library/Application Support/ClaudeCode/managed-settings.json", String(decoding: json, as: UTF8.self))
        try env.write(".system/Library/Application Support/ClaudeCode/policy.md", "# Must not be read through an inferred inline import")
        let user = try env.write(".claude/CLAUDE.md", "# User fixture")
        let store = env.makeStore()
        // Global scope exercises the system-path seam without a selected project.
        let context = AnalysisContext(agentID: "claude-code")
        let report = store.knowledgeAnalysis(context, configuration: store.configurationAnalysis(context))
        #expect(report.instructions.map(\.path) == [managedFile.path, managedSettings.path, user.path])
        #expect(report.instructions.prefix(2).allSatisfy { $0.state == "Conditional" && $0.bytes > 0 })
        #expect(report.notices.contains { $0.contains("combined activation") })
        #expect(report.notices.contains { $0.contains("Import expansion") && $0.contains("unresolved") })
        #expect(!report.instructions.contains { $0.path.hasSuffix("/policy.md") })
        let budget = ContextBudget.build(knowledge: report, mcp: [], threshold: 8_000)
        #expect(budget.tokens(.instruction) == ContextBudget.estimateTokens(bytes: "# User fixture".utf8.count))
        #expect(budget.tokens(.instruction, .conditional) == ContextBudget.estimateTokens(bytes: "# Managed file fixture".utf8.count) + ContextBudget.estimateTokens(bytes: inline.utf8.count))
    }
    @Test func claudeInlineManagedAmbiguityAndMismatchedContextStayUnresolved() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.write(".system/Library/Application Support/ClaudeCode/managed-settings.json", ##"{"claudeMd":"# Main managed fixture"}"##)
        try env.write(".system/Library/Application Support/ClaudeCode/managed-settings.d/team.json", ##"{"claudeMd":"# Managed drop-in fixture"}"##)
        let store = env.makeStore()
        let context = AnalysisContext(agentID: "claude-code")
        let configuration = store.configurationAnalysis(context)
        let report = store.knowledgeAnalysis(context, configuration: configuration)
        let inline = report.instructions.filter { $0.keyPath == ["claudeMd"] }
        #expect(inline.count == 2 && inline.allSatisfy { $0.state == "Unresolved" && $0.includedBytes == 0 && $0.bytes > 0 })
        #expect(ContextBudget.build(knowledge: report, mcp: [], threshold: 8_000).total == 0)
        var other = context; other.profile = "another-context"
        let mismatched = store.knowledgeAnalysis(other, configuration: configuration)
        #expect(!mismatched.instructions.contains { $0.keyPath == ["claudeMd"] })
        #expect(mismatched.notices.contains { $0.contains("another context") })
    }
    @Test func claudeInlineManagedInvalidValuesAndByteLimitsAreExplicit() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let path = AppPaths.systemPath("/Library/Application Support/ClaudeCode/managed-settings.json")
        let context = AnalysisContext(agentID: "claude-code")
        var configuration = ConfigurationAnalysis(context: context)
        configuration.sources = [.init(path: path, label: "Managed", state: "Applied", reason: "", tree: ["claudeMd": 42])]
        var reads: [String] = []
        func analyze() -> KnowledgeAnalysis {
            KnowledgeInspector.build(context: context, agents: [], configuration: configuration) { reads.append($0); return nil }
        }
        let invalid = try #require(analyze().instructions.first { $0.keyPath == ["claudeMd"] })
        #expect(invalid.state == "Unresolved" && invalid.bytes == 0 && invalid.includedBytes == 0 && invalid.reason.contains("must be a string"))
        configuration.sources[0].tree = ["claudeMd": String(repeating: "x", count: 2_000_004)]
        let limited = try #require(analyze().instructions.first { $0.keyPath == ["claudeMd"] })
        #expect(limited.state == "Truncated" && limited.bytes == 2_000_004 && limited.includedBytes == 2_000_000 && limited.text.count == 20_000)
        #expect(!reads.contains(path))
    }
    @Test func claudeInlineCoexistenceKeepsManagedFileImportsConditional() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.write(".system/Library/Application Support/ClaudeCode/CLAUDE.md", "@policy.md\n")
        try env.write(".system/Library/Application Support/ClaudeCode/policy.md", "# Managed import fixture")
        let settings = try env.write(".system/Library/Application Support/ClaudeCode/managed-settings.json", #"{"claudeMd":"Inline fixture"}"#)
        let store = env.makeStore()
        let context = AnalysisContext(agentID: "claude-code")
        var report = store.knowledgeAnalysis(context, configuration: store.configurationAnalysis(context))
        #expect(report.instructions.count == 3)
        #expect(report.instructions.allSatisfy { $0.state == "Conditional" })
        #expect(ContextBudget.build(knowledge: report, mcp: [], threshold: 8_000).tokens(.instruction) == 0)

        // A schema-invalid inline value cannot suppress a valid policy file.
        try #"{"claudeMd":42}"#.write(to: settings, atomically: true, encoding: .utf8)
        store.refresh()
        report = store.knowledgeAnalysis(context, configuration: store.configurationAnalysis(context))
        #expect(report.instructions.filter { $0.keyPath.isEmpty }.allSatisfy { $0.state == "Candidate" })
        #expect(report.instructions.first { $0.keyPath == ["claudeMd"] }?.state == "Unresolved")
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
