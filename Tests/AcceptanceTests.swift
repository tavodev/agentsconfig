import Testing
import Foundation

extension AgentsConfigTestSuite {
@Suite("Integrated acceptance gaps", .serialized)
@MainActor
struct AcceptanceTests {
    @Test func disablingHistoryStopsNewSnapshotsAndBlocksDirtyRestore() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let path = env.path(".claude/settings.json")
        let original = try #require(store.history(for: path).first)
        AppSettings.defaults.set(false, forKey: "historyEnabled")
        store.updateEdit(path: path, text: "{\"value\":1}")
        store.save(path: path)
        #expect(store.saveErrors[path] == nil)
        #expect(store.history(for: path).count == 1)
        store.updateEdit(path: path, text: "{\"draft\":true}")
        store.requestRestore(path: path, version: original)
        store.confirmRestore()
        #expect(store.dirtyPaths.contains(path))
        #expect(store.text(for: path) == "{\"draft\":true}")
        #expect(store.saveErrors[path] != nil)
    }

    @Test func largeFileAndDiffWorkIsBounded() throws {
        let clock = ContinuousClock()
        let input = "{\"payload\":\"" + String(repeating: "x", count: 1_800_000) + "\"}"
        let started = clock.now
        let tree = Parsers.parse(input, format: .json).tree
        #expect(tree != nil)
        let lines = (0..<2_100).map { "line-\($0)" }.joined(separator: "\n")
        let changes = DiffEngine.lineDiff(oldText: lines, newText: lines + "\nextra")
        #expect(changes.count == 1)
        #expect(changes.first?.keyPath == L("Large diff omitted"))
        let elapsed = started.duration(to: clock.now)
        print("Bounded 1.8 MB parse + 2100-line diff: \(elapsed)")
        #expect(elapsed < .seconds(3)) // generous regression ceiling, not a UI latency claim
    }

    @Test func integratedEditingConflictRestoreAndMcpReview() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installAllAgents()
        let store = env.makeStore()
        let a = env.path(".claude/settings.json")
        let b = env.path(".gemini/settings.json")
        let aDraft = "{\"env\":{\"API_KEY\":\"FAKE-INTEGRATED\"},\"value\":1}"
        store.updateEdit(path: a, text: aDraft)
        store.updateEdit(path: b, text: "{\"value\":2}")
        store.save(path: b)
        #expect(store.text(for: a) == aDraft)
        try env.write(".claude/settings.json", "{\"value\":3}")
        store.save(path: a)
        #expect(store.conflicts.contains(a))
        store.resolveConflictKeepMine(path: a)
        #expect(!store.dirtyPaths.contains(a))
        #expect(store.history(for: a).contains { store.versionContent(path: a, version: $0) == "{\"value\":3}" })
        #expect(!Secrets.maskText(store.text(for: a), format: .json).contains("FAKE-INTEGRATED"))
        let version = try #require(store.history(for: a).first)
        store.updateEdit(path: a, text: "{\"draft\":true}")
        store.requestRestore(path: a, version: version)
        store.cancelRestore()
        #expect(store.dirtyPaths.contains(a))
        store.requestRestore(path: a, version: version)
        store.confirmRestore()
        #expect(!store.dirtyPaths.contains(a))
        #expect(store.history(for: a).contains { store.versionContent(path: a, version: $0) == "{\"draft\":true}" })
        let source = try #require(store.mcpEntries(for: "docs").first { $0.agentID == "claude-code" })
        #expect(store.copyMcpServer(source, to: "opencode"))
        let target = env.path(".config/opencode/opencode.json")
        #expect(!store.dirtyPaths.contains(target))
        #expect(store.confirmMcpReview())
        store.save(path: target)
        #expect(store.saveErrors[target] == nil)
        #expect(store.mcpEntries(for: "docs").contains { $0.agentID == "opencode" })
        store.updateEdit(path: target, text: "{invalid")
        let events = store.activity.count
        store.save(path: target)
        #expect(store.saveErrors[target] != nil)
        #expect(store.activity.count == events)
        #expect(store.dirtyPaths.contains(target))
    }

    @Test func successfulSaveRecordsNewStateImmediately() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let path = env.path(".claude/settings.json")
        let new = "{\"model\":\"new-save\"}"
        store.updateEdit(path: path, text: new)
        store.save(path: path)
        let first = try #require(store.history(for: path).first)
        #expect(store.versionContent(path: path, version: first) == new)
        #expect(store.history(for: path).count >= 2)
        #expect(store.activity.first?.changes.contains { $0.keyPath == "model" } == true)
        #expect(first.changeCount > 0)
    }

    @Test func externalDeletionRemovesMcpAndCachedDocument() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let path = env.path(".claude.json")
        try FileManager.default.removeItem(atPath: path)
        store.handleFileChanged(path)
        #expect(store.document(for: path) == nil)
        #expect(!store.mcpNames.contains("docs"))
        #expect(store.externalChanges[path]?.isDeletion == true)
        try env.write(".claude.json", "{\"mcpServers\":{\"restored\":{\"command\":\"fake\"}}}")
        store.handleFileChanged(path)
        #expect(store.mcpNames.contains("restored"))
    }

    @Test func nestedSkillAndNewChildAreDiscovered() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        try env.write(".claude/skills/collection/deep/SKILL.md", "# nested")
        let store = env.makeStore()
        #expect(store.agents.flatMap(\.files).contains { $0.path == env.path(".claude/skills/collection/deep/SKILL.md") })
        try env.write(".claude/skills/collection/new-child/SKILL.md", "# discovered later")
        store.handleWatchEvent(env.path(".claude/skills/collection"))
        #expect(store.agents.flatMap(\.files).contains { $0.path == env.path(".claude/skills/collection/new-child/SKILL.md") })
    }

    @Test func largeStructuredInputUsesBackgroundSourceMode() async throws {
        let text = "{\"payload\":\"" + String(repeating: "x", count: 2_100_000) + "\"}"
        let parsed = Parsers.parse(text, format: .json)
        #expect(parsed.tree == nil)
        #expect(parsed.error != nil)
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude(settingsJSON: text)
        let store = env.makeStore()
        let path = env.path(".claude/settings.json")
        #expect(store.document(for: path) == nil)
        #expect(store.loadingPaths.contains(path))
        await store.waitForBackgroundWork(path: path)
        #expect(store.document(for: path)?.text.utf8.count == text.utf8.count)
        #expect(store.saveErrors[path] == nil)
        #expect(!store.isReadOnly(path))
    }
}

}
