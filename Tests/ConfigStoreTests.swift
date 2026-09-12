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
}

}
