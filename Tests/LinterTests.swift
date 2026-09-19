import Testing
import Foundation

extension AgentsConfigTestSuite {
@Suite("Configuration diagnostics", .serialized)
@MainActor
struct LinterTests {
    @Test func unknownKeysAreConsistentAcrossEquivalentPaths() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        for paths in [
            [".claude/settings.json", "repo/.claude/settings.json", "repo/.claude/settings.local.json"],
            [".codex/config.toml", "repo/.codex/config.toml"],
            [".gemini/settings.json", "repo/.gemini/settings.json"],
            [".config/opencode/opencode.json", ".config/opencode/opencode.jsonc", "repo/opencode.json", "repo/opencode.jsonc"]
        ] {
            for path in paths {
                let result = Linter.lint(path: env.path(path), text: "{}", tree: ["modle": "fixture"],
                    parseError: nil, format: AgentRegistry.inferFormat(path: path))
                #expect(result.issues.contains { $0.message.contains("modle") }, "No diagnosis for \(path)")
            }
        }
        #expect(Linter.lint(path: env.path("notopencode.json"), text: "{}", tree: ["modle": "fixture"],
            parseError: nil, format: .json).issues.isEmpty)
    }

    @Test func currentGeminiSectionsAreRecognized() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let tree: [String: Any] = ["general": ["vimMode": true], "ui": ["theme": "Default"],
                                  "context": ["fileName": "GEMINI.md"], "tools": [:], "hooks": [:]]
        for path in [".gemini/settings.json", "repo/.gemini/settings.json"] {
            #expect(Linter.lint(path: env.path(path), text: "{}", tree: tree,
                parseError: nil, format: .json).issues.isEmpty)
        }
    }

    @Test func malformedPermissionTypesAreDiagnosedWithoutLeakingValues() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        for tree: [String: Any] in [
            ["permissions": "FAKE-SENSITIVE"],
            ["permissions": ["allow": "FAKE-SENSITIVE"]],
            ["permissions": ["deny": ["Read(.env)", 42]]]
        ] {
            let issues = Linter.lint(path: env.path("repo/.claude/settings.local.json"), text: "{}", tree: tree,
                parseError: nil, format: .json).issues
            #expect(issues.contains { $0.severity == .error })
            #expect(issues.allSatisfy { !$0.message.contains("FAKE-SENSITIVE") })
        }
    }

    @Test func validCurrentAndLegacyShapesArePreserved() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let fixtures: [(String, [String: Any])] = [
            (".claude/settings.json", ["permissions": ["allow": ["Read"]], "sandbox": ["enabled": true]]),
            (".codex/config.toml", ["approval_policy": ["granular": ["sandbox_approval": true]], "projects": [:]]),
            (".gemini/settings.json", ["model": ["name": "fixture"], "ui": [:]]),
            ("opencode.jsonc", ["permission": "ask"]),
            ("opencode.jsonc", ["permission": ["bash": ["*": "ask"]]])
        ]
        for (path, tree) in fixtures {
            #expect(Linter.lint(path: env.path(path), text: "{}", tree: tree,
                parseError: nil, format: AgentRegistry.inferFormat(path: path)).issues.isEmpty)
        }
    }

    @Test func diagnosticsSurviveARescan() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.write(".claude/settings.json", #"{"permissions":"invalid"}"#)
        try env.write(".claude/skills/sample/SKILL.md", "# Fixture")
        let store = env.makeStore()
        let path = env.path(".claude/settings.json")
        #expect(store.agents.flatMap(\.files).first { $0.path == path }?.issues.contains { $0.severity == .error } == true)
        store.refresh()
        #expect(store.agents.flatMap(\.files).first { $0.path == path }?.issues.contains { $0.severity == .error } == true)
        store.handleWatchEvent(env.path(".claude/skills"))
        #expect(store.agents.flatMap(\.files).first { $0.path == path }?.issues.contains { $0.severity == .error } == true)
    }

    @Test func managedOwnershipUsesTheActualConfigurationDialect() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let codex = Linter.lint(path: env.path("repo/.codex/config.toml"), text: "", tree: ["projects": [:]],
            parseError: nil, format: .toml)
        #expect(codex.managed.allSatisfy { $0.owner != "Claude Code" })
        let claude = Linter.lint(path: env.path(".claude.json"), text: "", tree: ["projects": [:]],
            parseError: nil, format: .json)
        #expect(claude.managed.contains { $0.owner == "Claude Code" })
        let foreign = Linter.lint(path: env.path("unknown.json"), text: "", tree: ["hooks": ["state": [:]]],
            parseError: nil, format: .json)
        #expect(foreign.managed.isEmpty)
    }
}
}
