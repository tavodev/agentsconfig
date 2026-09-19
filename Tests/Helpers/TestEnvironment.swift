import Foundation


/// Scratch home + exclusive UserDefaults suite for a single test.
///
/// Mutates process-global seams (`AppPaths.overrideHome`, `AppSettings.defaults`),
/// so it may only be used inside `@Suite(.serialized)` suites, and every test
/// must `teardown()` (via `defer`) so later tests see a clean process.
/// Nothing here ever touches the real home, real defaults, or notifications.
@MainActor
final class TestEnvironment {
    let home: URL
    let defaultsSuite: String

    init() throws {
        // /var is a symlink to /private/var — resolvingSymlinksInPath keeps
        // the alias, so canonicalize with realpath(3) after creating the dir.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentsconfig-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        home = realpath(base.path, &buf) != nil
            ? URL(fileURLWithPath: String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), isDirectory: true)
            : base
        AppPaths.overrideHome = home.path
        defaultsSuite = "agentsconfig-tests.\(UUID().uuidString)"
        AppSettings.defaults = UserDefaults(suiteName: defaultsSuite)!
    }

    /// `~/Library/Application Support/AgentsConfig/History` inside the fake home.
    var historyRoot: URL {
        AppPaths.applicationSupport
            .appendingPathComponent("AgentsConfig/History", isDirectory: true)
    }

    func path(_ rel: String) -> String { home.appendingPathComponent(rel).path }

    /// A scratch directory independent of `home`, usable as a registered
    /// project root (`ConfigStore.addProject`). Same realpath canonicalization
    /// as `home` so path-string comparisons against tracked files are exact.
    /// Not removed by `teardown()` — callers must delete it themselves.
    func makeProjectRoot(_ name: String = "project") throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentsconfig-tests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(base.path, &buf) != nil
            ? URL(fileURLWithPath: String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), isDirectory: true)
            : base
    }

    @discardableResult
    func write(root: URL, _ rel: String, _ content: String) throws -> URL {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func makeSnapshots(now: @escaping () -> Date = Date.init,
                       historyLimit: @escaping () -> Int = { AppSettings.historyLimit }
    ) -> SnapshotStore {
        SnapshotStore(now: now, historyLimit: historyLimit)
    }

    /// A store pointed at the fake home, with no notification center access.
    func makeStore() -> ConfigStore { ConfigStore(notifier: nil) }

    @discardableResult
    func write(_ rel: String, _ content: String, permissions: Int = 0o600) throws -> URL {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
        return url
    }

    func read(_ rel: String) throws -> String {
        try String(contentsOf: home.appendingPathComponent(rel), encoding: .utf8)
    }

    func posixPermissions(_ rel: String) -> Int? {
        (try? FileManager.default.attributesOfItem(
            atPath: path(rel))[.posixPermissions] as? NSNumber)?.intValue
    }

    // MARK: - agent fixtures (all fictitious)

    /// `~/.claude` + settings with a fake apiKey, volatile ~/.claude.json with
    /// an MCP server, a hook script and a skill — enough for detection + MCP.
    func installClaude(settingsJSON: String? = nil) throws {
        try write(".claude/settings.json", settingsJSON ?? """
        {"apiKey":"sk-test-FAKE-0000","theme":"dark","model":"opus"}
        """)
        try write(".claude/CLAUDE.md", "# test memory\n")
        try write(".claude.json", """
        {"mcpServers":{"docs":{"command":"npx","args":["-y","@fake/docs-mcp"]}}}
        """)
        try write(".claude/hooks/lint.sh", "#!/bin/sh\nexit 0\n", permissions: 0o700)
        try write(".claude/skills/demo/SKILL.md", "---\nname: demo\n---\n")
    }

    func installCodex() throws {
        try write(".codex/config.toml", """
        model = "gpt-fake"

        [mcp_servers.docs]
        command = "npx"
        args = ["-y", "@fake/docs-mcp"]
        """)
        try write(".codex/AGENTS.md", "# agents\n")
        try write(".codex/auth.json",
                  "{\"OPENAI_API_KEY\":\"sk-test-FAKE-1111\"}",
                  permissions: 0o600)
    }

    func installGemini() throws {
        try FileManager.default.createDirectory(atPath: path(".gemini/skills"), withIntermediateDirectories: true)
        try write(".gemini/settings.json", "{\"theme\":\"Default\"}")
        try write(".gemini/GEMINI.md", "# gemini\n")
        try write(".gemini/config/mcp_config.json", "{\"mcpServers\":{}}")
    }

    func installOpenCode() throws {
        try write(".config/opencode/opencode.json", """
        {"$schema":"https://opencode.ai/config.json","mcp":{}}
        """)
        try write(".config/opencode/AGENTS.md", "# opencode\n")
    }

    func installAllAgents() throws {
        try installClaude()
        try installCodex()
        try installGemini()
        try installOpenCode()
    }

    /// Restores process-global seams and deletes the scratch home + suite.
    func teardown() {
        AppPaths.overrideHome = nil
        AppSettings.defaults = .standard
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: home)
    }
}
