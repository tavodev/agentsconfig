import Foundation
import Testing

extension AgentsConfigTestSuite {
@Suite("MCP static checks", .serialized) @MainActor
struct McpStaticCheckTests {
    private func entry(command: String? = nil, args: [String] = [], url: String? = nil,
                       raw extra: [String: Any] = [:], agentID: String = "claude-code") -> McpServerEntry {
        var raw = extra
        if let command { raw["command"] = command }
        if !args.isEmpty { raw["args"] = args }
        if let url { raw["url"] = url }
        return McpServerEntry(name: "fixture", agentID: agentID, agentName: "Fixture", sourcePath: "/fixture/config.json",
                              containerKey: "mcpServers", isRemote: url != nil, command: command, args: args, url: url,
                              envKeys: (raw["env"] as? [String: Any])?.keys.sorted() ?? [], enabled: nil, raw: raw)
    }

    private func environment(_ env: TestEnvironment, variables: Set<String> = ["FAKE_PRESENT"]) -> McpCheckEnvironment {
        .init(searchPath: [env.path("bin")], variables: variables, origin: .app)
    }

    private func messages(_ findings: [McpCheckFinding]) -> [String] { findings.map(\.message) }

    @Test func commandResolvesThroughSearchPathOrExecutablePath() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.write("bin/fake-mcp", "#!/bin/sh\nexit 0\n", permissions: 0o700)
        try env.write("tools/not-executable", "data", permissions: 0o600)
        let context = environment(env)
        #expect(McpStaticCheck.check(entry(command: "fake-mcp"), environment: context).isEmpty)
        #expect(McpStaticCheck.check(entry(command: env.path("bin/fake-mcp")), environment: context).isEmpty)
        let missing = McpStaticCheck.check(entry(command: "fake-missing-mcp"), environment: context)
        #expect(missing.map(\.severity) == [.error] && missing.first?.detail == "fake-missing-mcp")
        #expect(McpStaticCheck.check(entry(command: env.path("tools/not-executable")), environment: context)
            .contains { $0.message == "Command «%@» is not executable." })
        #expect(McpStaticCheck.check(entry(command: env.path("tools/absent")), environment: context)
            .contains { $0.message == "Command «%@» does not exist." })
        // Relative commands resolve against cwd when declared.
        #expect(McpStaticCheck.check(entry(command: "./fake-mcp", raw: ["cwd": env.path("bin")]), environment: context).isEmpty)
        #expect(McpStaticCheck.check(entry(command: "./fake-mcp"), environment: context).map(\.severity) == [.info])
    }

    @Test func variablesAndEnvironmentAreCheckedByNameOnly() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.write("bin/fake-mcp", "#!/bin/sh\n", permissions: 0o700)
        let findings = McpStaticCheck.check(entry(command: "fake-mcp",
            args: ["--token=${FAKE_MISSING}", "${FAKE_PRESENT}", "${FAKE_DEFAULTED:-x}", "${CLAUDE_PROJECT_DIR}/x", "${env:FAKE_ENV_FORM}"],
            raw: ["env": ["API_KEY": "", "OTHER": "${FAKE_IN_ENV_BLOCK}"]]), environment: environment(env))
        let missing = findings.filter { $0.message == "Variable «%@» is not set in the inspected environment." }.compactMap(\.detail)
        #expect(Set(missing) == ["FAKE_MISSING", "FAKE_ENV_FORM", "FAKE_IN_ENV_BLOCK"])
        #expect(findings.contains { $0.message == "Environment variable «%@» is empty." && $0.detail == "API_KEY" })

        let codex = McpStaticCheck.check(entry(url: "https://mcp.example.test/mcp",
            raw: ["env_vars": ["FAKE_FORWARDED"], "bearer_token_env_var": "FAKE_PRESENT"], agentID: "codex"), environment: environment(env))
        #expect(codex.compactMap(\.detail) == ["FAKE_FORWARDED"])

        let file = McpStaticCheck.check(entry(url: "https://mcp.example.test/sse",
            raw: ["headers": ["Authorization": "Bearer ${file:~/secrets/fake-token.txt}"]], agentID: "windsurf"), environment: environment(env))
        #expect(file.contains { $0.message == "Referenced file «%@» does not exist." && $0.detail == env.path("secrets/fake-token.txt") })
    }

    @Test func pathsAndUrlsAreValidated() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.write("bin/fake-mcp", "#!/bin/sh\n", permissions: 0o700)
        try env.write("data/present.db", "")
        let paths = McpStaticCheck.check(entry(command: "fake-mcp",
            args: ["-y", env.path("data/present.db"), "--db=" + env.path("data/absent.db"), "~/data/also-absent", "https://example.test/x"],
            raw: ["cwd": env.path("no-such-dir")]), environment: environment(env))
        #expect(Set(paths.filter { $0.message == "Argument path «%@» does not exist." }.compactMap(\.detail))
            == [env.path("data/absent.db"), env.path("data/also-absent")])
        #expect(paths.first?.message == "Working directory «%@» does not exist.")

        #expect(McpStaticCheck.check(entry(url: "https://mcp.example.test/mcp"), environment: environment(env)).isEmpty)
        #expect(McpStaticCheck.check(entry(url: "${FAKE_PRESENT}/mcp"), environment: environment(env)).isEmpty)
        for bad in ["mcp.example.test/mcp", "ftp://mcp.example.test", "https://"] {
            #expect(McpStaticCheck.check(entry(url: bad), environment: environment(env)).contains { $0.message == "Server URL «%@» is malformed." }, "\(bad)")
        }
    }

    /// The store checks indexed servers against an injectable environment and
    /// recomputes when that environment changes; nothing is launched.
    @Test func storeChecksIndexedServersAgainstItsEnvironment() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.write(".claude.json", #"{"mcpServers":{"docs":{"command":"fake-mcp","args":["${FAKE_TOKEN}"]}}}"#)
        let store = env.makeStore()
        store.mcpCheckEnvironment = .init(searchPath: [env.path("bin")], variables: [], origin: .app)
        let docs = try #require(store.mcpIndex.first { $0.name == "docs" })
        #expect(Set(store.mcpChecks(for: docs).map(\.severity)) == [.error, .warning])

        try env.write("bin/fake-mcp", "#!/bin/sh\n", permissions: 0o700)
        store.mcpCheckEnvironment = .init(searchPath: [env.path("bin")], variables: ["FAKE_TOKEN"], origin: .loginShell)
        #expect(store.mcpChecks(for: docs).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: env.path("bin/fake-mcp.ran")))
    }

    @Test func appEnvironmentAddsCommonInstallLocations() {
        let context = McpCheckEnvironment.app(environment: ["PATH": "/usr/bin:/bin", "FAKE": "value"], home: "/Users/fixture")
        #expect(context.searchPath.prefix(2) == ["/usr/bin", "/bin"])
        #expect(context.searchPath.contains("/opt/homebrew/bin") && context.searchPath.contains("/Users/fixture/.local/bin"))
        #expect(context.variables == ["PATH", "FAKE"])
    }
}
}
