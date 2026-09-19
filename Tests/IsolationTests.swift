import Testing
import Foundation


/// F0 acceptance: tests run against a scratch home, an exclusive defaults
/// suite, and never produce real notifications or touch personal paths.
extension AgentsConfigTestSuite {
@Suite("Test isolation", .serialized)
@MainActor
struct IsolationTests {

    @Test func overrideRedirectsHomeAndApplicationSupport() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }

        #expect(AppPaths.home == env.home.path)
        #expect(AppPaths.expand("~/x/y.json") == env.path("x/y.json"))
        #expect(AppPaths.expand("/abs/path") == "/abs/path")
        #expect(AppPaths.applicationSupport.path.hasPrefix(env.home.path))
        #expect(env.historyRoot.path.hasPrefix(env.home.path))
    }

    @Test func emptyHomeDetectsNoAgents() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }

        let store = env.makeStore()
        #expect(store.agents.isEmpty)
        #expect(store.mcpIndex.isEmpty)
        #expect(store.activity.isEmpty)
    }

    @Test func storeDetectsAllFixtureAgentsInsideFakeHome() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installAllAgents()

        let store = env.makeStore()
        #expect(Set(store.agents.map(\.id))
                == ["claude-code", "codex", "gemini-cli", "antigravity", "opencode"])
        for agent in store.agents {
            for f in agent.files {
                #expect(f.path.hasPrefix(env.home.path))
                #expect(!f.path.hasPrefix(NSHomeDirectory()))
            }
        }
    }

    @Test func defaultsSuiteIsExclusiveAndDoesNotLeakToStandard() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }

        let key = "test.marker.\(UUID().uuidString)"
        AppSettings.defaults.set("x", forKey: key)
        #expect(AppSettings.defaults.string(forKey: key) == "x")
        #expect(UserDefaults.standard.string(forKey: key) == nil)

        env.teardown()
        #expect(AppSettings.defaults == .standard)
        #expect(AppPaths.overrideHome == nil)
    }

    @Test func snapshotsStayInsideFakeHome() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()

        let snapshots = env.makeSnapshots()
        let file = env.path(".claude/settings.json")
        let v = try snapshots.record(path: file, content: "{\"a\":1}",
                                     origin: .baseline, changes: [])
        #expect(v != nil)
        #expect(try snapshots.loadHistory(for: file).count == 1)

        // Everything written must live under the fake home's history root.
        let fm = FileManager.default
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: env.historyRoot.path, isDirectory: &isDir))
        let enumerator = fm.enumerator(at: env.historyRoot,
                                       includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator {
            #expect(url.path.hasPrefix(env.home.path))
        }
    }

    @Test func homeIsUniquePerTest() throws {
        let a = try TestEnvironment()
        defer { a.teardown() }
        let b = try TestEnvironment()
        defer { b.teardown() }
        #expect(a.home != b.home)
        #expect(a.defaultsSuite != b.defaultsSuite)
    }
}

}
