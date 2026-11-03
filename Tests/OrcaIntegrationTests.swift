import Foundation
import Testing

extension AgentsConfigTestSuite {
@Suite("Orca integration", .serialized) @MainActor
struct OrcaIntegrationTests {
    private let orca = "Library/Application Support/orca"

    /// Fictitious Orca layout: one Claude profile (selected) whose skills
    /// link to ~/.claude, one Codex account whose AGENTS.md links to
    /// ~/.codex, and the shared Codex runtime home.
    private func installOrca(_ env: TestEnvironment) throws {
        try env.installClaude()
        try env.installCodex()
        let claude = "\(orca)/claude-profiles/acct-claude-0001/home"
        try env.write("\(claude)/settings.json", #"{"model":"opus","hooks":{}}"#)
        try env.write("\(claude)/CLAUDE.md", "@~/.claude/CLAUDE.md\n")
        try env.write("\(claude)/.claude.json", #"{"mcpServers":{"orca-only":{"command":"echo"}}}"#)
        try FileManager.default.createSymbolicLink(atPath: env.path("\(claude)/skills"), withDestinationPath: env.path(".claude/skills"))
        try env.write("\(orca)/claude-profiles/selected-host", env.path(claude))
        let codex = "\(orca)/codex-accounts/acct-codex-0002/home"
        try env.write("\(codex)/config.toml", "model = \"gpt-fake\"\n")
        try env.write("\(codex)/.orca-managed-home", "acct-codex-0002")
        try env.write("\(codex)/auth.json", #"{"OPENAI_API_KEY":"sk-test-FAKE-2222"}"#)
        try env.write("\(codex)/rules/default.rules", "prefix_rule(pattern = [\"ls\"], decision = \"allow\")\n")
        try FileManager.default.createSymbolicLink(atPath: env.path("\(codex)/AGENTS.md"), withDestinationPath: env.path(".codex/AGENTS.md"))
        try env.write("\(orca)/codex-runtime-home/home/config.toml", "model = \"gpt-fake\"\n")
    }

    @Test func orcaHomesAreDetectedAsSeparateAgents() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try installOrca(env)
        let agents = AgentRegistry.detect()
        let claude = try #require(agents.first { $0.id == "claude-code:orca:acct-claude-0001" })
        let codex = try #require(agents.first { $0.id == "codex:orca:acct-codex-0002" })
        let runtime = try #require(agents.first { $0.id == "codex:orca:runtime" })
        #expect(claude.name == "Claude Code · Orca acct-cla")
        #expect(claude.notes?.contains("the one Orca has selected") == true)
        let home = env.path("\(orca)/claude-profiles/acct-claude-0001/home")
        #expect(claude.files.contains { $0.path == home + "/settings.json" && $0.exists && !$0.readOnly })
        #expect(claude.files.contains { $0.path == home + "/.claude.json" && $0.volatile })
        // Linked folders stay with the regular agent: one identity per file.
        #expect(!claude.files.contains { $0.role == .skills })
        #expect(!codex.files.contains { $0.path.hasSuffix("/AGENTS.md") })
        #expect(!codex.files.contains { $0.path.hasSuffix("/auth.json") })
        #expect(codex.files.contains { $0.path.hasSuffix("/rules/default.rules") })
        #expect(runtime.files.contains { $0.path.hasSuffix("/codex-runtime-home/home/config.toml") && $0.exists })
        // Regular agents are unchanged and never list Orca files.
        let regular = agents.filter { $0.id == "claude-code" || $0.id == "codex" }.flatMap(\.files)
        #expect(regular.count > 0 && regular.allSatisfy { !$0.path.contains("/orca/") })
        let definitions = AgentRegistry.definitions.filter { $0.id.contains(OrcaIntegration.idPrefix) }
        #expect(definitions.allSatisfy { $0.mcpDestinationPaths.isEmpty && $0.localSources.isEmpty })
    }

    @Test func orcaFilesShareDocumentationButNotLayerAnalysis() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try installOrca(env)
        let settings = env.path("\(orca)/claude-profiles/acct-claude-0001/home/settings.json")
        let config = env.path("\(orca)/codex-accounts/acct-codex-0002/home/config.toml")
        #expect(ConfigFileContext.settingsKind(for: settings) == .claude)
        #expect(ConfigFileContext.settingsKind(for: config) == .codex)
        #expect(DocsCatalog.settingsScope(filePath: settings) == .user)
        #expect(DocsCatalog.keyDoc(filePath: settings, keyPath: ["model"]) != nil)
        #expect(DocsCatalog.keyDoc(filePath: config, keyPath: ["model"]) != nil)
        #expect(DocsCatalog.fileDoc(for: settings)?.title == DocsCatalog.fileDoc(for: env.path(".claude/settings.json"))?.title)
        #expect(DocsCatalog.settingsCatalog(filePath: settings)?.isEmpty == false)
        let store = env.makeStore()
        #expect(store.layerContext(for: settings) == nil)
        #expect(store.layerContext(for: env.path(".claude/settings.json")) != nil)
        #expect(OrcaIntegration.home(containing: env.path("\(orca)/orca-stats.json")) == nil)
    }

    @Test func orcaIntegrationCanBeTurnedOff() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try installOrca(env)
        let store = env.makeStore()
        #expect(store.agents.contains { $0.id.hasPrefix("claude-code:orca:") })
        store.setOrcaIntegration(enabled: false)
        #expect(!store.agents.contains { $0.id.contains(OrcaIntegration.idPrefix) })
        let settings = env.path("\(orca)/claude-profiles/acct-claude-0001/home/settings.json")
        #expect(ConfigFileContext.settingsKind(for: settings) == nil)
        store.setOrcaIntegration(enabled: true)
        #expect(store.agents.filter { $0.id.contains(OrcaIntegration.idPrefix) }.count == 3)
    }
}
}
