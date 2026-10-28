import Foundation
import Testing

extension AgentsConfigTestSuite {
@Suite("MCP context comparison", .serialized) @MainActor
struct McpComparisonTests {
    private func server(_ command: String, scope: String = "User", project: String? = nil, enabled: Bool? = nil) -> McpServerEntry {
        .init(name: "same", agentID: "claude-code", agentName: "Claude Code", sourcePath: "/fixture/" + command,
              containerKey: "mcpServers", isRemote: false, command: command, args: [], url: nil, envKeys: [], enabled: enabled,
              raw: ["command": command], projectPath: project, scope: scope)
    }
    @Test func projectFilterAndPrivateScopeAreRespected() {
        let rows = McpComparison.sources([server("global"), server("project", scope: "Project", project: "/repo"),
            server("private", scope: "Private project", project: "/repo"), server("other", scope: "Project", project: "/other")], project: "/repo")
        #expect(rows.first { $0.entry.command == "global" }?.state == "Shadowed")
        #expect(rows.first { $0.entry.command == "project" }?.state == "Shadowed")
        #expect(rows.first { $0.entry.command == "private" }?.state == "Configured")
        #expect(rows.first { $0.entry.command == "other" }?.state == "Outside context")
    }
    @Test func managedScopeWinsRegardlessOfProjectPathLength() {
        let project = "/repo/" + String(repeating: "x", count: 600)
        let rows = McpComparison.sources([server("managed", scope: "Managed"),
            server("private", scope: "Private project", project: project)], project: project)
        #expect(rows.first { $0.entry.command == "managed" }?.state == "Configured")
        #expect(rows.first { $0.entry.command == "private" }?.state == "Shadowed")
    }

    @Test func conflictsAtEqualScopeAreAmbiguous() {
        let rows = McpComparison.sources([server("a"), server("b")], project: "")
        #expect(rows.allSatisfy { $0.state == "Ambiguous" })
    }
    @Test func unverifiedExtensionsKeepTheirStateAlongsideHigherScopes() {
        for scope in ["User", "Managed", "Profile", "Project"] {
            let plugin = server("plugin", scope: "Extension")
            let otherPlugin = server("other-plugin", scope: "Extension")
            let configured = server("configured", scope: scope,
                                    project: scope == "Project" ? "/fixture/repo" : nil)
            let rows = McpComparison.sources([plugin, otherPlugin, configured], project: "/fixture/repo")
            #expect(rows.filter { $0.entry.scope == "Extension" }.allSatisfy {
                $0.state == "Activation not verified" && $0.reason.contains("not observed")
            }, "\(scope)")
            #expect(rows.first { $0.entry.command == "configured" }?.state == "Configured", "\(scope)")
        }
    }
    /// Issue #31: exercise discovery, parsing and MCP comparison from isolated
    /// inventories. The commands are fictitious definitions, never executed.
    @Test func installedPluginMcpScopeAndActivationSurviveUserNameCollisions() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let fixtures = [
            ("copilot-cli", ".copilot/installed-plugins/review-kit/mcp.json", ".copilot/mcp-config.json"),
            ("gemini-cli", ".gemini/extensions/review-kit/gemini-extension.json", ".gemini/settings.json"),
            ("claude-code", ".claude/plugins/config.json", ".claude/settings.json"),
        ]
        for (_, pluginPath, userPath) in fixtures {
            try env.write(pluginPath, #"{"mcpServers":{"docs":{"command":"fixture-plugin-mcp"}}}"#)
            try env.write(userPath, #"{"mcpServers":{"docs":{"command":"fixture-user-mcp"}}}"#)
        }
        let store = env.makeStore()
        let contexts: [String?] = [nil, "", env.path("project")]
        for (family, pluginPath, userPath) in fixtures {
            let entries = store.mcpIndex.filter { McpComparison.family($0) == family }
            #expect(entries.count == 2, "\(family)")
            let plugin = try #require(entries.first { $0.sourcePath == env.path(pluginPath) })
            let user = try #require(entries.first { $0.sourcePath == env.path(userPath) })
            #expect(plugin.scope == "Extension" && user.scope == "User", "\(family)")
            for context in contexts {
                let alone = McpComparison.sources([plugin], project: context)
                #expect(alone.first?.state == "Activation not verified", "\(family)")
                let rows = McpComparison.sources(entries, project: context)
                #expect(rows.first { $0.entry.id == plugin.id }?.state == "Activation not verified", "\(family)")
                #expect(rows.first { $0.entry.id == user.id }?.state == "Configured", "\(family)")
            }
        }
    }
    @Test func disabledStateAndProfilesAreExplicit() {
        var profile = server("profile");
        profile.profileName = "review"; profile.scope = "Profile"
        let rows = McpComparison.sources([server("disabled", enabled: false), profile], project: "", profile: "")
        #expect(rows.first { $0.entry.command == "disabled" }?.state == "Disabled")
        #expect(rows.first { $0.entry.command == "profile" }?.state == "Outside context")
    }
    @Test func changesIncludeArgumentOrderWithoutLeakingValues() {
        let a = McpServerEntry(name: "test", agentID: "codex", agentName: "Codex", sourcePath: "/a",
            containerKey: "mcp_servers", isRemote: false, command: "fixture", args: ["FAKE-FIRST", "FAKE-SECOND"],
            url: nil, envKeys: [], enabled: nil, raw: ["command": "fixture", "args": ["FAKE-FIRST", "FAKE-SECOND"]])
        let b = McpServerEntry(name: "test", agentID: "codex", agentName: "Codex", sourcePath: "/b",
            containerKey: "mcp_servers", isRemote: false, command: "fixture", args: ["FAKE-SECOND", "FAKE-FIRST"],
            url: nil, envKeys: [], enabled: nil, raw: ["command": "fixture", "args": ["FAKE-SECOND", "FAKE-FIRST"]])
        let changes = McpComparison.differences(a, b)
        #expect(!changes.isEmpty)
        #expect(changes.allSatisfy { !($0.oldValue ?? "").contains("FAKE-") && !($0.newValue ?? "").contains("FAKE-") })
    }
}
}
