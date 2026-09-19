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

