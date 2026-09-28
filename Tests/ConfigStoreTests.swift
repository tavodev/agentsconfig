import Testing
import Foundation


/// Store-level smoke tests against fixture agents in the fake home.
extension AgentsConfigTestSuite {
@Suite("ConfigStore basics", .serialized)
@MainActor
struct ConfigStoreTests {

    @Test func storePreloadsDocumentsAndBaselinesHistory() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()

        let store = env.makeStore()
        let settings = env.path(".claude/settings.json")
        let doc = store.document(for: settings)
        #expect(doc?.parseError == nil)
        #expect((doc?.tree as? [String: Any])?["theme"] as? String == "dark")
        // first load records a baseline snapshot
        #expect(!store.history(for: settings).isEmpty)
    }

    @Test func editMarksDirtyAndDiscardClears() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()

        let store = env.makeStore()
        let settings = env.path(".claude/settings.json")
        store.updateEdit(path: settings, text: "{\"theme\":\"light\"}")
        #expect(store.dirtyPaths.contains(settings))
        store.discardEdit(path: settings)
        #expect(!store.dirtyPaths.contains(settings))
        #expect(store.text(for: settings) == store.document(for: settings)?.text)
    }

    @Test func saveWritesBufferToDisk() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()

        let store = env.makeStore()
        let settings = env.path(".claude/settings.json")
        let newText = "{\"theme\":\"light\"}\n"
        store.updateEdit(path: settings, text: newText)
        store.save(path: settings)

        #expect(store.saveErrors[settings] == nil)
        #expect(!store.dirtyPaths.contains(settings))
        #expect(try env.read(".claude/settings.json") == newText)
    }

    @Test func invalidJSONIsRejectedAndKeepsBuffer() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()

        let store = env.makeStore()
        let settings = env.path(".claude/settings.json")
        let original = store.document(for: settings)?.text
        store.updateEdit(path: settings, text: "{ not json")
        store.save(path: settings)

        #expect(store.saveErrors[settings] != nil)
        #expect(store.dirtyPaths.contains(settings))
        #expect(try env.read(".claude/settings.json") == original)
    }

    @Test func mcpIndexAggregatesAcrossAgents() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installAllAgents()

        let store = env.makeStore()
        // `docs` appears in claude's volatile ~/.claude.json and codex's TOML.
        let docs = store.mcpEntries(for: "docs")
        #expect(docs.count == 2)
        #expect(Set(docs.map(\.agentID)) == ["claude-code", "codex"])
    }

    @Test func volatileStateFileIsExcludedFromHistory() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()

        let store = env.makeStore()
        let state = env.path(".claude.json")
        _ = store.document(for: state)
        #expect(store.history(for: state).isEmpty)
    }

    /// Issue #18: a silenced `LintRule` disappears from `TrackedFile.issues`
    /// immediately, survives across store instances (persisted in
    /// `AppSettings.defaults`, same seam as `excludedHistoryPaths`), and can
    /// be reversed.
    @Test func mutingALintRulePersistsAcrossStoresAndCanBeReversed() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude(settingsJSON: #"{"permissions":{"allow":["Bash"]},"model":"opus"}"#)

        let settings = env.path(".claude/settings.json")
        func hasBroadPermissionIssue(_ store: ConfigStore) -> Bool {
            store.agents.flatMap(\.files).first { $0.path == settings }?
                .issues.contains { $0.ruleID == LintRule.broadPermissions.rawValue } == true
        }

        let store = env.makeStore()
        #expect(hasBroadPermissionIssue(store))

        store.setLintRuleMuted(true, ruleID: LintRule.broadPermissions.rawValue, for: settings)
        #expect(!hasBroadPermissionIssue(store))
        #expect(store.mutedLintRules[settings] == Set([LintRule.broadPermissions.rawValue]))

        // persisted: a fresh store sharing the same defaults suite stays muted
        let store2 = env.makeStore()
        #expect(store2.mutedLintRules[settings] == Set([LintRule.broadPermissions.rawValue]))
        #expect(!hasBroadPermissionIssue(store2))

        store2.setLintRuleMuted(false, ruleID: LintRule.broadPermissions.rawValue, for: settings)
        #expect(store2.mutedLintRules[settings] == nil)
        #expect(hasBroadPermissionIssue(store2))
    }
}

}
