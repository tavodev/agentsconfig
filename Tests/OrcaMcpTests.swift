import Foundation
import Testing

extension AgentsConfigTestSuite {
@Suite("Orca MCP and baseline", .serialized) @MainActor
struct OrcaMcpTests {
    private let orca = "Library/Application Support/orca"
    private var claudeHome: String { "\(orca)/claude-profiles/acct-claude-0001/home" }
    private var codexHome: String { "\(orca)/codex-accounts/acct-codex-0002/home" }
    typealias O = OrcaIntegration

    /// Fictitious state: the global Claude state and Codex config hold `docs`
    /// and a project server; the Orca homes add mirrors, account-only and
    /// stale servers.
    private func install(_ env: TestEnvironment, baseline: String? = nil) throws {
        try env.installClaude()
        try env.installCodex()
        try env.write(".claude.json", """
        {"mcpServers":{"docs":{"command":"npx","args":["-y","@fake/docs-mcp"]},"tuned":{"command":"tuned-v2"}},
         "projects":{"/work/alpha":{"mcpServers":{"alpha-db":{"command":"fake-db"}}}}}
        """)
        try env.write("\(claudeHome)/.claude.json", """
        {"userID":"acct","mcpServers":{"docs":{"command":"npx","args":["-y","@fake/docs-mcp"]},
          "tuned":{"command":"tuned-v1"},"acct-tool":{"command":"fake-acct","args":["--x"]}},
         "projects":{"/work/alpha":{"mcpServers":{"alpha-db":{"command":"fake-db"},"alpha-own":{"command":"fake-own"}}},
                     "/work/beta":{"mcpServers":{"beta-own":{"command":"fake-beta"}}}}}
        """)
        try env.write("\(codexHome)/config.toml", """
        model = "gpt-fake"

        [mcp_servers.docs]
        command = "npx"
        args = ["-y", "@fake/docs-mcp"]

        [mcp_servers.retired]
        command = "fake-retired"

        [mcp_servers.codex-own]
        command = "fake-codex-own"
        """)
        try env.write("\(codexHome)/.orca-managed-home", "acct-codex-0002")
        if let baseline { try env.write("\(codexHome)/\(O.codexBaselineFileName)", baseline) }
    }

    private func entry(_ store: ConfigStore, _ name: String, agent: String) throws -> McpServerEntry {
        try #require(store.mcpIndex.first { $0.name == name && $0.agentID == agent })
    }

    // MARK: - Origins

    @Test func originClassificationIsPure() {
        let spec: [String: Any] = ["command": "x", "args": ["a"]]
        #expect(O.mcpOrigin(spec: spec, sourceSpec: ["args": ["a"], "command": "x"], sourceOwnsEntry: false) == .mirrored)
        #expect(O.mcpOrigin(spec: spec, sourceSpec: ["command": "y"], sourceOwnsEntry: false) == .mirrorDiffers)
        #expect(O.mcpOrigin(spec: spec, sourceSpec: nil, sourceOwnsEntry: true) == .mirrorDiffers)
        #expect(O.mcpOrigin(spec: spec, sourceSpec: nil, sourceOwnsEntry: false) == .accountOnly)
        #expect(O.baseAgentID("claude-code:orca:acct") == "claude-code")
        #expect(O.baseAgentID("codex:orca:runtime") == "codex")
        #expect(O.baseAgentID("claude-code::/work/alpha") == "claude-code::/work/alpha")
    }

    @Test func claudeProfileServersAreMirroredOrAccountOnly() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try install(env)
        let store = env.makeStore()
        let id = "claude-code:orca:acct-claude-0001"
        #expect(store.orcaMcpOrigin(try entry(store, "docs", agent: id)) == .mirrored)
        #expect(store.orcaMcpOrigin(try entry(store, "tuned", agent: id)) == .mirrorDiffers)
        #expect(store.orcaMcpOrigin(try entry(store, "acct-tool", agent: id)) == .accountOnly)
        // Per-project servers of the profile are indexed too.
        let alphaDB = try entry(store, "alpha-db", agent: id)
        #expect(alphaDB.scope == "Private project" && alphaDB.projectPath == "/work/alpha")
        #expect(store.orcaMcpOrigin(alphaDB) == .mirrored)
        // A source project replaces the profile's record: its extra server goes.
        #expect(store.orcaMcpOrigin(try entry(store, "alpha-own", agent: id)) == .mirrorDiffers)
        #expect(store.orcaMcpOrigin(try entry(store, "beta-own", agent: id)) == .accountOnly)
        // Regular entries have no Orca origin.
        #expect(store.orcaMcpOrigin(try entry(store, "docs", agent: "claude-code")) == nil)
        // Mirrors are attached to their source and not counted as divergences.
        let source = try entry(store, "docs", agent: "claude-code")
        #expect(store.orcaMirrors(of: source).map(\.agentID).contains(id))
        #expect(store.orcaMcpSource(of: try entry(store, "docs", agent: id))?.id == source.id)
        #expect(!store.divergences(projectRoot: "").contains { $0.subject == "docs" && $0.members.contains { $0.family == id } })
    }

    @Test func codexHomeServersUseTheBaseline() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try install(env)
        var store = env.makeStore()
        let id = "codex:orca:acct-codex-0002"
        #expect(store.orcaMcpOrigin(try entry(store, "docs", agent: id)) == .mirrored)
        // Without a baseline nothing says Orca copied `retired`.
        #expect(store.orcaMcpOrigin(try entry(store, "retired", agent: id)) == .accountOnly)
        try env.write("\(codexHome)/\(O.codexBaselineFileName)",
                      #"{"version":3,"settings":{},"mcpServers":["docs","retired"]}"#)
        store = env.makeStore()
        #expect(store.orcaMcpOrigin(try entry(store, "retired", agent: id)) == .mirrorDiffers)
        #expect(store.orcaMcpOrigin(try entry(store, "codex-own", agent: id)) == .accountOnly)
        // Version 1 baselines without names owned the whole MCP table.
        try env.write("\(codexHome)/\(O.codexBaselineFileName)", #"{"version":1,"settings":{}}"#)
        store = env.makeStore()
        #expect(store.orcaMcpOrigin(try entry(store, "codex-own", agent: id)) == .mirrorDiffers)
        #expect(store.orcaMcpOrigin(try entry(store, "docs", agent: id)) == .mirrored)
    }

    // MARK: - Promotion

    @Test func accountOnlyServersPromoteThroughReview() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try install(env)
        let store = env.makeStore()
        let claudeID = "claude-code:orca:acct-claude-0001"
        let own = try entry(store, "acct-tool", agent: claudeID)
        #expect(store.orcaPromotionTarget(for: own)?.path == env.path(".claude.json"))
        // Mirrors, stale copies and project servers are not offered.
        #expect(store.orcaPromotionTarget(for: try entry(store, "docs", agent: claudeID)) == nil)
        #expect(store.orcaPromotionTarget(for: try entry(store, "tuned", agent: claudeID)) == nil)
        #expect(store.orcaPromotionTarget(for: try entry(store, "beta-own", agent: claudeID)) == nil)
        let profileBefore = try env.read("\(claudeHome)/.claude.json")
        #expect(store.promoteOrcaMcpServer(own))
        let review = try #require(store.pendingMcpReview)
        #expect(review.path == env.path(".claude.json") && review.agentID == "claude-code")
        #expect(review.warnings.contains { $0.contains("Orca") })
        #expect(store.confirmMcpReview())
        store.save(path: env.path(".claude.json"))
        #expect(store.saveErrors[env.path(".claude.json")] == nil)
        #expect(try env.read(".claude.json").contains("fake-acct"))
        // The Orca home itself is untouched and still not a destination.
        #expect(try env.read("\(claudeHome)/.claude.json") == profileBefore)
        #expect(!store.isMcpDestination(env.path("\(claudeHome)/.claude.json")))

        let codexOwn = try entry(store, "codex-own", agent: "codex:orca:acct-codex-0002")
        #expect(store.orcaPromotionTarget(for: codexOwn)?.path == env.path(".codex/config.toml"))
        #expect(store.promoteOrcaMcpServer(codexOwn))
        #expect(store.pendingMcpReview?.path == env.path(".codex/config.toml"))
        #expect(store.pendingMcpReview?.proposedText.contains("fake-codex-own") == true)
        store.cancelMcpReview()
        #expect(!store.isMcpDestination(env.path("\(codexHome)/config.toml")))
    }

    // MARK: - Codex baseline

    private func parse(_ text: String) -> O.CodexBaselineObservation { O.parseCodexBaseline(Data(text.utf8)) }

    @Test func baselineParserIsTolerant() {
        guard case .present(let v3) = parse(#"""
        {"version":3,"settings":{"model":"\"gpt-a\""},"mcpServers":["a",1,"b"],
         "conflicts":{"model":{"runtime":"\"x\"","system":null},"bad":{"runtime":1,"system":null},"half":{"runtime":"x"},"odd":7}}
        """#) else { Issue.record("v3 not parsed"); return }
        #expect(v3.version == 3 && v3.mcpServers == ["a", "b"] && !v3.mcpServerRoot)
        #expect(v3.conflictKeys == ["model"])
        guard case .present(let v1) = parse(#"{"version":1,"settings":{}}"#) else { Issue.record("v1"); return }
        #expect(v1.mcpServerRoot && v1.mcpServers.isEmpty && v1.conflictKeys.isEmpty)
        guard case .present(let root) = parse(#"{"version":2,"settings":{},"mcpServers":[],"mcpServerRoot":true}"#) else { Issue.record("v2"); return }
        #expect(root.mcpServerRoot)
        #expect(parse(#"{"version":4,"settings":{}}"#) == .unrecognized(version: "4"))
        #expect(parse(#"{"version":true,"settings":{}}"#) == .unrecognized(version: nil))
        #expect(parse(#"{"version":2.5,"settings":{}}"#) == .unrecognized(version: nil))
        #expect(parse(#"{"version":"3","settings":{}}"#) == .unrecognized(version: "3"))
        #expect(parse(#"{"version":3,"settings":[]}"#) == .unrecognized(version: "3"))
        #expect(parse(#"{"version":1e300,"settings":{}}"#) == .unrecognized(version: nil))
        #expect(parse("[1,2]") == .unrecognized(version: nil))
        #expect(parse("\"text\"") == .unrecognized(version: nil))
        #expect(parse("{not json") == .invalid)
        #expect(parse("") == .invalid)
        #expect(O.parseCodexBaseline(Data(repeating: 0x20, count: O.codexBaselineByteLimit + 1)) == .invalid)
    }

    @Test func baselineConflictsBecomeConfigIssuesWithoutValues() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try install(env, baseline: #"""
        {"version":3,"settings":{},"mcpServers":[],
         "conflicts":{"model":{"runtime":"\"gpt-secret-account\"","system":"\"gpt-secret-global\""},
                      "tui.theme":{"runtime":null,"system":"\"dark-secret\""}}}
        """#)
        let store = env.makeStore()
        let config = env.path("\(codexHome)/config.toml")
        let issues = try #require(store.agents.flatMap(\.files).first { $0.path == config }).issues
        let conflicts = issues.filter { $0.message.contains("without a common baseline") }
        #expect(conflicts.count == 2)
        #expect(conflicts.allSatisfy { $0.severity == .warning && $0.ruleID == nil })
        #expect(conflicts.contains { $0.message.contains("“model”") })
        #expect(conflicts.contains { $0.message.contains("“tui.theme”") })
        #expect(!issues.contains { $0.message.contains("secret") || $0.message.contains("/Users/") })
        // Other files never get baseline notices.
        #expect(O.codexBaselineIssues(configPath: env.path(".codex/config.toml")).isEmpty)
        #expect(O.codexBaselineIssues(configPath: env.path("\(codexHome)/hooks.json")).isEmpty)
    }

    @Test func baselineProblemsAreReportedNotFatal() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try install(env)
        let config = env.path("\(codexHome)/config.toml")
        let baseline = "\(codexHome)/\(O.codexBaselineFileName)"
        #expect(O.codexBaselineIssues(configPath: config).isEmpty)
        try env.write(baseline, #"{"version":9,"settings":{}}"#)
        var issues = O.codexBaselineIssues(configPath: config)
        #expect(issues.count == 1 && issues[0].severity == .info && issues[0].message.contains("version 9"))
        try env.write(baseline, "{oops")
        issues = O.codexBaselineIssues(configPath: config)
        #expect(issues.count == 1 && issues[0].severity == .info && issues[0].message.contains("not valid JSON"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: env.path(baseline))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.path(baseline)) }
        #expect(O.readCodexBaseline(home: env.path(codexHome)) == .unreadable)
        issues = O.codexBaselineIssues(configPath: config)
        #expect(issues.count == 1 && issues[0].severity == .warning)
        // Many conflicts are summarized.
        let many = (0..<20).map { "\"k\($0)\":{\"runtime\":null,\"system\":null}" }.joined(separator: ",")
        issues = O.codexBaselineIssues(.present(try #require({
            if case .present(let b) = parse("{\"version\":3,\"settings\":{},\"conflicts\":{\(many)}}") { return b }
            return nil
        }())))
        #expect(issues.count == 13 && issues.last?.message.contains("8 more keys") == true)
    }

    @Test func orcaMcpStringsAreTranslated() {
        let keys = [
            "Orca mirror", "Differs from source", "Only in this account",
            "Orca copies this server from the regular configuration before each launch; same definition.",
            "The regular configuration owns this server but defines it differently or no longer has it; Orca updates this copy on its next launch.",
            "Only this Orca account has this server and Orca keeps it. Promote it to share it with the regular configuration and every account.",
            "+1 Orca mirror", "+%d Orca mirrors", "Promote to %@", "Also in Orca, same definition: %@",
            "Copies Orca makes for its accounts, identical to their source. Shown with the source in Server details.",
            "Copy this account-only server to the regular configuration, after reviewing the diff. Orca then shares it with every account.",
            "Orca copies this server to these accounts before each launch.",
            "Orca copies the promoted definition back to every account on its next launch; this account's entry is then replaced by it.",
            "Orca keeps this account's value of “%@” in this home and does not copy it to the Codex config: both sides changed it without a common baseline. The next change on only one side decides which value wins.",
            "%d more keys in conflict between this account and the Codex config.",
            "Orca's settings baseline for this home has a format AgentsConfig does not recognize (version %@). Conflicts with the Codex config are not shown.",
            "Orca's settings baseline for this home has a format AgentsConfig does not recognize. Conflicts with the Codex config are not shown.",
            "Orca's settings baseline for this home is not valid JSON. Orca discards it and rebuilds it on its next launch, forgetting earlier conflicts.",
            "Orca's settings baseline for this home cannot be read. Orca does not sync this home's config until it can.",
        ]
        for key in keys { #expect(Loc.esTranslation(key) != nil, "missing Spanish: \(key)") }
    }
}
}
