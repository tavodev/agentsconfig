import Foundation
import Testing

extension AgentsConfigTestSuite {
@Suite("Catalog coverage", .serialized) @MainActor
struct CatalogCoverageTests {
    @Test func productsAndSourcesAreIndependent() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.write(".gemini/settings.json", "{}")
        var agents = AgentRegistry.detect()
        #expect(agents.contains { $0.id == "gemini-cli" })
        #expect(!agents.contains { $0.id == "antigravity" })
        try env.write(".gemini/config/config.json", "{}")
        agents = AgentRegistry.detect()
        #expect(agents.contains { $0.id == "antigravity" })
        #expect(agents.first { $0.id == "antigravity" }?.files.contains { $0.path == env.path(".gemini/settings.json") } == false)
    }
    @Test func modernSourcesAndNestedFoldersAreDiscovered() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.installAllAgents()
        for path in [".agents/skills/shared/SKILL.md", ".codex/deep.config.toml", ".codex/AGENTS.override.md",
                     ".gemini/skills/native/SKILL.md", ".config/opencode/skills/native/SKILL.md"] { try env.write(path, "# Fixture") }
        let store = env.makeStore()
        #expect(store.agents.first { $0.id == "codex" }?.files.contains { $0.path == env.path(".codex/deep.config.toml") } == true)
        for id in ["codex", "gemini-cli", "opencode"] {
            #expect(store.agents.first { $0.id == id }?.files.contains { $0.path == env.path(".agents/skills/shared/SKILL.md") } == true)
        }
        let project = try env.makeProjectRoot(); defer { try? FileManager.default.removeItem(at: project) }
        for path in ["packages/api/AGENTS.override.md", "packages/api/.codex/hooks.json", ".claude/rules/nested/test.md",
                     ".agents/rules/style.md", ".opencode/skills/local/SKILL.md"] { try env.write(root: project, path, "# Fixture") }
        store.addProject(path: project.path)
        let files = store.agents.filter { $0.projectRoot == project.path }.flatMap(\.files)
        #expect(files.contains { $0.path == project.appendingPathComponent("packages/api/AGENTS.override.md").path })
        #expect(files.contains { $0.path.hasSuffix("/.claude/rules/nested/test.md") })
        #expect(files.contains { $0.path.hasSuffix("/.opencode/skills/local/SKILL.md") })
        #expect(store.agents.contains { $0.id == "antigravity::\(project.path)" })
    }
    @Test func systemSourcesStayIsolatedAndReadOnly() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.installCodex()
        try env.write(".system/etc/codex/requirements.toml", "allowed_approval_policies = ['on-request']")
        let files = AgentRegistry.detect().flatMap(\.files)
        let requirement = try #require(files.first { $0.path.hasSuffix("/etc/codex/requirements.toml") })
        #expect(requirement.path.hasPrefix(env.home.path + "/"))
        #expect(requirement.readOnly)
        #expect(files.allSatisfy { $0.path.hasPrefix(env.home.path + "/") })
    }
    @Test func privateClaudeServersKeepProjectIdentity() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.write(".claude.json", #"{"mcpServers":{"same":{"command":"global"}},"projects":{"/fixture/a":{"mcpServers":{"same":{"command":"first"}}},"/fixture/b":{"mcpServers":{"same":{"command":"second"}}}}}"#)
        let store = env.makeStore()
        let entries = store.mcpEntries(for: "same")
        #expect(entries.count == 3)
        #expect(Set(entries.map(\.id)).count == 3)
        #expect(entries.first { $0.projectPath == "/fixture/a" }?.sourceKeyPath == ["projects", "/fixture/a", "mcpServers"])
        #expect(entries.first { $0.projectPath == "/fixture/b" }?.scope == "Private project")
    }
    /// Issue #23: Windsurf / Devin Desktop and Claude Desktop are read-only
    /// inventory; their MCP servers reach the comparator, never as a target.
    @Test func windsurfAndClaudeDesktopAreReadOnlyInventory() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.installCursor(); try env.installCopilot()
        try env.installWindsurf(); try env.installClaudeDesktop()
        let project = try env.makeProjectRoot(); defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, ".devin/rules/style.md", "# Rule")
        try env.write(root: project, ".windsurfrules", "legacy rule")
        try env.write(root: project, ".windsurf/hooks.json", #"{"hooks":{"post_write_code":[{"command":"echo fixture"}]}}"#)
        let store = env.makeStore(); store.addProject(path: project.path)
        for id in ["cursor", "copilot-cli", "windsurf", "claude-desktop"] {
            let agent = try #require(store.agents.first { $0.id == id })
            #expect(agent.files.filter { $0.exists }.allSatisfy { $0.readOnly }, "\(id) must stay read-only")
            #expect(store.mcpTargetFiles(for: id).isEmpty, "\(id) is not an MCP destination")
            #expect(store.mcpIndex.contains { $0.agentID == id }, "\(id) servers reach the comparator")
        }
        let desktop = env.path("Library/Application Support/Claude/claude_desktop_config.json")
        #expect(store.agents.flatMap(\.files).first { $0.path == desktop }?.excludeFromHistory == true)
        let windsurf = try #require(store.mcpIndex.first { $0.agentID == "windsurf" })
        #expect(windsurf.isRemote && windsurf.url == "https://mcp.example.test/sse")
        #expect(McpComparison.normalized(windsurf)["transport"] as? String == "unspecified-remote")
        let local = store.agents.filter { $0.projectRoot == project.path && $0.id.hasPrefix("windsurf::") }.flatMap(\.files)
        for suffix in ["/.devin/rules/style.md", "/.windsurfrules", "/.windsurf/hooks.json"] {
            #expect(local.contains { $0.path.hasSuffix(suffix) }, "missing \(suffix)")
        }
    }

    @Test func inventoryAgentsHaveFileDocs() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        for rel in [".cursor/mcp.json", ".cursor/cli-config.json", ".cursor/hooks.json", ".copilot/settings.json",
                    ".copilot/mcp-config.json", ".copilot/copilot-instructions.md", "repo/.github/copilot-instructions.md",
                    "repo/.cursor/rules/a.mdc", "repo/.github/instructions/a.instructions.md",
                    ".codeium/windsurf/memories/global_rules.md", ".config/devin/mcp_config.json", ".codeium/mcp_config.json",
                    ".codeium/windsurf/mcp_config.json", ".codeium/windsurf/hooks.json", "repo/.devin/hooks.json",
                    "repo/.windsurf/hooks.json", "repo/.windsurfrules",
                    "Library/Application Support/Claude/claude_desktop_config.json"] {
            let doc = try #require(DocsCatalog.fileDoc(for: env.path(rel)), "missing doc for \(rel)")
            #expect(doc.docsURL != nil, "missing official link for \(rel)")
            #expect(doc.titleES != nil && doc.bodyES != nil)
        }
    }

    @Test func customRootsChangeInspectionWithoutReadingHostEnvironment() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.write("custom-codex/config.toml", "model = 'fixture'")
        let store = env.makeStore()
        store.setConfigurationRoot(agentID: "codex", path: env.path("custom-codex"))
        #expect(store.agents.first { $0.id == "codex" }?.files.contains { $0.path == env.path("custom-codex/config.toml") } == true)
        #expect(store.mcpTargetFiles(for: "codex").first?.path == env.path("custom-codex/config.toml"))
    }
}
}
