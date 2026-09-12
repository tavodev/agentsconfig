import Testing
import Foundation
import TOMLKit

/// F7: MCP copy must use the right schema per agent, preserve unknown
/// fields, refuse to clobber invalid buffers or existing names, and fail
/// visibly when no valid destination exists.
extension AgentsConfigTestSuite {
@Suite("MCP copy", .serialized)
@MainActor
struct McpTests {

    @Test func absentDestinationAppearingDuringReviewIsNotOverwritten() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installCodex()
        let path = env.path(".codex/config.toml")
        try FileManager.default.removeItem(atPath: path)
        let store = env.makeStore()
        #expect(store.addMcpServer(path: path, name: "first", transport: .stdio, command: "fake", args: [], url: ""))
        try env.write(".codex/config.toml", "model = 'external'\n")
        #expect(!store.confirmMcpReview())
        #expect(try env.read(".codex/config.toml") == "model = 'external'\n")
        #expect(!store.dirtyPaths.contains(path))
    }

    @Test func jsoncDestinationAndAmbiguityRequireExplicitChoice() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installOpenCode()
        try FileManager.default.removeItem(atPath: env.path(".config/opencode/opencode.json"))
        try env.write(".config/opencode/opencode.jsonc", "{ // comment\n\"model\":\"fixture\"\n}")
        let store = env.makeStore()
        let path = env.path(".config/opencode/opencode.jsonc")
        #expect(store.mcpTargetFile(for: "opencode")?.path == path)
        #expect(store.format(for: path) == .jsonc)
        #expect(store.addMcpServer(path: path, name: "first", transport: .http, command: "", args: [], url: "https://example.test/mcp"))
        #expect(store.pendingMcpReview?.warnings.isEmpty == false)
        #expect(store.confirmMcpReview())
        let root = try #require(Parsers.parse(store.text(for: path), format: .jsonc).tree as? [String: Any])
        #expect(root["model"] as? String == "fixture")
        try env.write(".config/opencode/opencode.json", "{}")
        store.refresh()
        #expect(store.mcpTargetFiles(for: "opencode").count == 2)
        #expect(store.mcpTargetFile(for: "opencode") == nil)
        #expect(!store.isMcpDestination(env.path(".config/opencode/AGENTS.md")))
    }

    @Test func unsupportedAndReadOnlyFilesCannotReceiveMcp() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installAllAgents()
        let store = env.makeStore()
        for relative in [".codex/auth.json", ".gemini/config/mcp_config.json", ".claude/settings.json"] {
            let path = env.path(relative)
            let before = store.text(for: path)
            #expect(!store.addMcpServer(path: path, name: "x", transport: .stdio, command: "fake", args: [], url: ""))
            #expect(store.text(for: path) == before)
        }
    }

    @Test(arguments: ["claude-code", "codex", "antigravity", "opencode"], [false, true])
    func firstServerUsesExplicitDestination(agentID: String, missing: Bool) throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installAllAgents()
        let paths = ["claude-code": ".claude.json", "codex": ".codex/config.toml",
                     "antigravity": ".gemini/settings.json", "opencode": ".config/opencode/opencode.json"]
        let relative = try #require(paths[agentID])
        if missing { try FileManager.default.removeItem(atPath: env.path(relative)) }
        else { try env.write(relative, agentID == "codex" ? "model = 'fixture'\n" : "{}") }
        let store = env.makeStore()
        let entry = McpServerEntry(name: "first", agentID: "claude-code", agentName: "Claude Code",
            sourcePath: env.path(".claude.json"), containerKey: "mcpServers", isRemote: false,
            command: "fake", args: [], url: nil, envKeys: [], enabled: nil, raw: ["command": "fake"])
        #expect(store.copyMcpServer(entry, to: agentID))
        #expect(store.pendingMcpReview?.path == env.path(relative))
        #expect(store.confirmMcpReview())
        store.save(path: env.path(relative))
        #expect(store.saveErrors[env.path(relative)] == nil)
        #expect(try env.read(relative).contains("first"))
        #expect(env.posixPermissions(relative) == 0o600)
        if agentID == "claude-code" {
            #expect(store.history(for: env.path(relative)).isEmpty)
            #expect(try env.makeSnapshots().loadHistory(for: env.path(relative)).isEmpty)
        }
    }

    @Test(arguments: McpAdapter.Dialect.allCases, McpAdapter.Dialect.allCases)
    func localAndRemoteMatrixPreservesSemantics(source: McpAdapter.Dialect, target: McpAdapter.Dialect) throws {
        for transport in [McpAdapter.Transport.stdio, .http] {
            let args = ["--name", "two words", "", "last"]
            var raw = try McpAdapter.makeSpec(dialect: source, transport: transport,
                                               command: "fake-mcp", args: args, url: "https://example.test/mcp")
            let sourceKey = transport == .stdio ? (source == .opencode ? "environment" : "env") : (source == .codex ? "http_headers" : "headers")
            raw[sourceKey] = ["X-Test": "fixture"]
            let spec = try McpAdapter.convert(raw, from: source, to: target).spec
            if transport == .stdio {
                #expect(spec["command"] as? [String] == (target == .opencode ? ["fake-mcp"] + args : nil))
                if target != .opencode {
                    #expect(spec["command"] as? String == "fake-mcp")
                    #expect(spec["args"] as? [String] == args)
                }
                #expect(spec[target == .opencode ? "environment" : "env"] as? [String: String] == ["X-Test": "fixture"])
            } else {
                #expect(spec[target == .gemini ? "httpUrl" : "url"] as? String == "https://example.test/mcp")
                #expect(spec[target == .codex ? "http_headers" : "headers"] as? [String: String] == ["X-Test": "fixture"])
            }
        }
    }

    @Test func unsupportedTimeoutDisabledSseAndExpansionAreRejected() throws {
        for raw: [String: Any] in [
            ["command": "fake", "startup_timeout_sec": 4],
            ["command": "fake", "enabled": false],
            ["command": "fake", "unknown_option": true],
            ["command": "fake", "env": ["KEY": "${VALUE}"]]
        ] {
            #expect(throws: (any Error).self) { try McpAdapter.convert(raw, from: .codex, to: .claude) }
        }
        #expect(throws: (any Error).self) {
            try McpAdapter.convert(["url": "https://example.test/sse"], from: .gemini, to: .codex)
        }
        let enabled = try McpAdapter.convert(["command": "fake", "enabled": true], from: .codex, to: .claude)
        #expect(enabled.spec["enabled"] == nil)
        let disabled = try McpAdapter.convert(["command": "fake", "enabled": false], from: .codex, to: .opencode)
        #expect(disabled.spec["enabled"] as? Bool == false)
    }

    @Test func addUsesTheAdapterAndPreservesArgumentRows() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installOpenCode()
        let store = env.makeStore()
        let path = env.path(".config/opencode/opencode.json")
        #expect(store.addMcpServer(path: path, name: "new", transport: .stdio,
                                  command: "fake", args: ["two words", ""], url: ""))
        #expect(!store.dirtyPaths.contains(path))
        let review = try #require(store.pendingMcpReview)
        let root = try #require(Parsers.parse(review.proposedText, format: .json).tree as? [String: Any])
        let servers = try #require(root["mcp"] as? [String: Any])
        let spec = try #require(servers["new"] as? [String: Any])
        #expect(spec["type"] as? String == "local")
        #expect(spec["command"] as? [String] == ["fake", "two words", ""])
    }

    @Test(arguments: ["[]", "null", "{\"mcp\":[]}", "{broken"])
    func invalidDestinationShapesKeepOriginal(text: String) throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installOpenCode()
        let path = env.path(".config/opencode/opencode.json")
        let store = env.makeStore()
        store.updateEdit(path: path, text: text)
        #expect(!store.addMcpServer(path: path, name: "new", transport: .stdio, command: "fake", args: [], url: ""))
        #expect(store.text(for: path) == text)
        #expect(store.pendingMcpReview == nil)
    }

    @Test(arguments: [false, true])
    func reviewRejectsChangedBufferOrDisk(disk: Bool) throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installOpenCode()
        let store = env.makeStore()
        let path = env.path(".config/opencode/opencode.json")
        #expect(store.addMcpServer(path: path, name: "new", transport: .stdio, command: "fake", args: [], url: ""))
        if disk { try env.write(".config/opencode/opencode.json", "{}") }
        else { store.updateEdit(path: path, text: "{\"edited\":true}") }
        #expect(!store.confirmMcpReview())
        #expect(store.actionError != nil)
        #expect(!store.text(for: path).contains("fake"))
    }

    @Test func tomlMcpUpdatePreservesUnrelatedNativeTypes() throws {
        let input = "# preserve values\ndate = 2026-09-10T12:30:00Z\ninteger = 9223372036854775807\n[mcp_servers.old]\ncommand = 'old'\n"
        let output = try Parsers.updatingTOMLMcp(input, container: "mcp_servers", name: "new", spec: ["command": "fake"])
        let before = try TOMLTable(string: input)
        let after = try TOMLTable(string: output)
        #expect(after["date"]?.type == before["date"]?.type)
        #expect(after["integer"]?.int == Int.max)
        #expect(after["mcp_servers"]?["old"]?["command"]?.string == "old")
        #expect(after["mcp_servers"]?["new"]?["command"]?.string == "fake")
    }

    /// Claude-style spec with fields the normalizer doesn't know —
    /// copying must carry them over, not drop them silently.
    @Test func copyRejectsUnsupportedCrossAgentFields() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude(settingsJSON: """
        {"mcpServers":{"docs":{"command":"npx","args":["-y","@fake/docs"],
         "env":{"TOKEN":"x"},"headers":{"X-Tenant":"t"},"startup_timeout_ms":5000}}}
        """)
        try env.installOpenCode()
        let store = env.makeStore()

        // the custom settings.json entry (not the default .claude.json one)
        let settings = env.path(".claude/settings.json")
        let entry = try #require(store.mcpIndex.first {
            $0.name == "docs" && $0.sourcePath == settings })
        #expect(!store.copyMcpServer(entry, to: "opencode"))
        #expect(store.actionError != nil)
        #expect(!store.dirtyPaths.contains(env.path(".config/opencode/opencode.json")))
    }

    /// A remote (url) entry copied to codex keeps the url and drops
    /// command-shaped leftovers.
    @Test func remoteEntryCopiesToCodexAsUrl() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude(settingsJSON: """
        {"mcpServers":{"web":{"type":"http","url":"https://mcp.example.com/x",
         "headers":{"Authorization":"Bearer t"}}}}
        """)
        try env.installCodex()
        let store = env.makeStore()

        let entry = try #require(store.mcpIndex.first { $0.name == "web" })
        #expect(entry.isRemote)
        #expect(store.copyMcpServer(entry, to: "codex"))

        #expect(store.pendingMcpReview != nil)
        #expect(store.confirmMcpReview())
        let target = env.path(".codex/config.toml")
        let buf = store.text(for: target)
        let root = try #require(
            Parsers.parse(buf, format: .toml).tree as? [String: Any])
        let servers = try #require(root["mcp_servers"] as? [String: Any])
        let spec = try #require(servers["web"] as? [String: Any])
        #expect(spec["url"] as? String == "https://mcp.example.com/x")
        #expect(spec["command"] == nil)
        #expect(spec["http_headers"] as? [String: String] == ["Authorization": "Bearer t"])
    }

    /// Repro: an invalid target buffer/disk content was replaced by a fresh
    /// JSON containing only the new server — silently destroying user text.
    @Test func copyRefusesInvalidTargetContent() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        try env.installOpenCode()
        // target is invalid *before* the store loads it
        try env.write(".config/opencode/opencode.json", "{ not json !!")
        let store = env.makeStore()

        let target = env.path(".config/opencode/opencode.json")

        let entry = try #require(store.mcpIndex.first { $0.name == "docs" })
        #expect(!store.copyMcpServer(entry, to: "opencode"))
        #expect(store.actionError != nil)
        #expect(store.text(for: target) == "{ not json !!")
    }

    /// Copying over an existing server name must not silently overwrite it.
    @Test func replacementRequiresReviewAndCanBeCancelled() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        try env.installOpenCode()
        // target already defines "docs"
        try env.write(".config/opencode/opencode.json",
                      #"{"mcp":{"docs":{"type":"local","command":["old"],"enabled":true}}}"#)
        let store = env.makeStore()

        let entry = try #require(store.mcpIndex.first {
            $0.name == "docs" && $0.agentID == "claude-code" })
        let target = env.path(".config/opencode/opencode.json")
        let before = store.text(for: target)
        #expect(store.copyMcpServer(entry, to: "opencode"))
        #expect(store.pendingMcpReview?.replacesExisting == true)
        #expect(store.text(for: target) == before)
        store.cancelMcpReview()
        #expect(store.text(for: target) == before)
        #expect(store.copyMcpServer(entry, to: "opencode"))
        #expect(store.confirmMcpReview())
        #expect(store.text(for: target) != before)
        #expect(try env.read(".config/opencode/opencode.json") == before)
    }

    /// An agent with no writable MCP file fails visibly, not silently.
    @Test func copyWithoutTargetFailsVisibly() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let entry = try #require(store.mcpIndex.first { $0.name == "docs" })

        #expect(!store.copyMcpServer(entry, to: "codex"))   // no codex here
        #expect(store.actionError != nil)
    }

    /// Own saves must refresh the MCP index — a removed server disappears
    /// from the matrix without waiting for an external event.
    @Test func mcpIndexUpdatesAfterOwnSave() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let p = env.path(".claude.json")
        #expect(store.mcpIndex.contains { $0.name == "docs" })

        store.updateEdit(path: p, text: #"{"mcpServers":{}}"#)
        store.save(path: p)
        #expect(!store.mcpIndex.contains { $0.name == "docs" })
        #expect(store.saveErrors[p] == nil)
    }
}

}
