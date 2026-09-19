import Foundation
import Testing

extension AgentsConfigTestSuite {
@Suite("Configuration resolution", .serialized) @MainActor
struct ConfigurationResolverTests {
    private func layer(_ label: String, _ tree: [String: Any], state: String = "Applied") -> SourceObservation {
        .init(path: "/fixture/" + label, label: label, state: state, reason: "", tree: tree)
    }
    @Test func codexProfileAndNestedTrustAreExplained() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.installCodex()
        let project = try env.makeProjectRoot(); defer { try? FileManager.default.removeItem(at: project) }
        try env.write(".codex/review.config.toml", "model = 'profile'\napproval_policy = 'never'")
        try env.write(root: project, ".codex/config.toml", "model = 'root'\nmodel_provider = 'ignored'")
        try env.write(root: project, "api/.codex/config.toml", "model = 'nested'")
        try env.write(".system/etc/codex/requirements.toml", "allowed_approval_policies = ['on-request']")
        let store = env.makeStore(); store.addProject(path: project.path)
        var context = AnalysisContext(agentID: "codex", projectRoot: project.path,
            workingDirectory: project.appendingPathComponent("api").path, profile: "review", trust: .trusted)
        var result = store.configurationAnalysis(context)
        let model = try #require(result.settings.first { $0.key == ["model"] })
        #expect(model.value == "nested")
        #expect(model.origins.filter { $0.state == "Shadowed" }.count == 3)
        #expect(result.settings.first { $0.key == ["model_provider"] }?.state == "Excluded")
        #expect(result.settings.first { $0.key == ["approval_policy"] }?.state == "Restricted")
        context.trust = .untrusted
        result = store.configurationAnalysis(context)
        #expect(result.settings.first { $0.key == ["model"] }?.value == "profile")
        context.trust = .unknown
        #expect(store.configurationAnalysis(context).settings.first { $0.key == ["model"] }?.state == "Conditional")
    }
    @Test func claudeListsAndRestrictionsHaveDistinctRules() {
        let result = SettingMerger.resolve([
            layer("User", ["permissions": ["allow": ["Read"], "deny": ["Edit"]], "fallbackModel": ["first"], "disableClaudeAiConnectors": true]),
            layer("Project", ["permissions": ["allow": ["Read", "Bash"]], "fallbackModel": ["second"]]),
            layer("Managed", ["disableClaudeAiConnectors": false])
        ], agentID: "claude-code", trust: .trusted)
        #expect(result.first { $0.key == ["permissions", "allow"] }?.value == "[\"Read\",\"Bash\"]")
        #expect(result.first { $0.key == ["fallbackModel"] }?.value == "[\"second\"]")
        #expect(result.first { $0.key == ["disableClaudeAiConnectors"] }?.value == "true")
    }
    @Test func specialClaudeFieldsAreNotGuessedAndRemoteEnableIsIgnoredLocally() {
        let result = SettingMerger.resolve([
            layer("User", ["remoteControlAtStartup": false, "effortLevel": "high"]),
            layer("Project", ["remoteControlAtStartup": true, "modelSettings": ["fixture": ["effortLevel": "low"]]]),
            layer("Managed", ["remoteControlAtStartup": true])
        ], agentID: "claude-code", trust: .trusted)
        #expect(result.first { $0.key == ["remoteControlAtStartup"] }?.value == "true")
        #expect(result.first { $0.key == ["modelSettings", "fixture", "effortLevel"] }?.state == "Unresolved")
        #expect(result.first { $0.key == ["effortLevel"] }?.state == "Unresolved")
    }

    @Test func managedOnlyRulesExcludeOtherScopes() {
        let result = SettingMerger.resolve([
            layer("User", ["permissions": ["allow": ["Bash"]]]),
            layer("Managed", ["allowManagedPermissionRulesOnly": true, "permissions": ["allow": ["Read"]]])
        ], agentID: "claude-code", trust: .trusted)
        #expect(result.first { $0.key == ["permissions", "allow"] }?.value == "[\"Read\"]")
    }
    @Test func uncertainArraysAndSecretsStayHonest() {
        let result = SettingMerger.resolve([
            layer("User", ["items": ["a"], "env": ["API_KEY": "FAKE-SECRET"]]),
            layer("Project", ["items": ["b"]])
        ], agentID: "gemini-cli")
        #expect(result.first { $0.key == ["items"] }?.state == "Unresolved")
        #expect(result.allSatisfy { !$0.value.contains("FAKE-SECRET") && $0.origins.allSatisfy { !$0.value.contains("FAKE-SECRET") } })
    }
    @Test func shapeReplacementAndLiteralKeysRemainDistinct() {
        let result = SettingMerger.resolve([layer("User", ["a": ["b": 1], "a.b": 5]),
                                            layer("Project", ["a": "new"])], agentID: "codex", trust: .trusted)
        #expect(result.first { $0.key == ["a", "b"] }?.state == "Shadowed")
        #expect(result.first { $0.key == ["a.b"] }?.value == "5")
        #expect(Set(result.map(\.id)).count == result.count)
    }
    @Test func invalidContextDoesNotReadAnySource() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        var reads = 0
        let context = AnalysisContext(projectRoot: env.path("project"), workingDirectory: env.path("outside"))
        let result = ConfigurationResolver.analyze(context) { _ in reads += 1; return nil }
        #expect(reads == 0); #expect(result.settings.isEmpty)
    }
}
}

