import Testing
import Foundation

/// File/key docs must resolve by relative suffix, not by exact global path —
/// otherwise a project-local copy of a known file (e.g. `.codex/config.toml`
/// inside a registered project) silently loses every tooltip.
extension AgentsConfigTestSuite {
@Suite("Docs catalog")
@MainActor
struct DocsCatalogTests {

    @Test func projectLocalCodexConfigGetsTheSameDocsAsGlobal() throws {
        let global = "/Users/fixture/.codex/config.toml"
        let local = "/Users/fixture/Documents/dev/some-repo/.codex/config.toml"

        let globalFileDoc = try #require(DocsCatalog.fileDoc(for: global))
        let localFileDoc = try #require(DocsCatalog.fileDoc(for: local))
        #expect(globalFileDoc.title == localFileDoc.title)

        for keyPath in [["approval_policy"], ["agents", "default_subagent_model"], ["hooks", "PreToolUse"]] {
            let globalDoc = try #require(DocsCatalog.keyDoc(filePath: global, keyPath: keyPath))
            let localDoc = try #require(DocsCatalog.keyDoc(filePath: local, keyPath: keyPath))
            #expect(globalDoc.summary == localDoc.summary)
        }
    }

    @Test func projectMcpJsonHasItsOwnDocDistinctFromNonstandardClaudeMcpJson() throws {
        let projectMcp = try #require(DocsCatalog.fileDoc(for: "/Users/fixture/repo/.mcp.json"))
        let nonstandardGlobalMcp = try #require(DocsCatalog.fileDoc(for: "/Users/fixture/.claude/mcp.json"))
        #expect(projectMcp.title != nonstandardGlobalMcp.title)
        #expect(projectMcp.title.contains("Project"))
    }

    @Test func claudeLocalSettingsOverridesHaveTheirOwnDoc() throws {
        let doc = try #require(DocsCatalog.fileDoc(for: "/Users/fixture/repo/.claude/settings.local.json"))
        #expect(doc.body.localizedCaseInsensitiveContains("gitignored")
                || doc.body.localizedCaseInsensitiveContains("personal"))
    }

    @Test func codexHooksEventsAndSubagentKeysAreDocumented() throws {
        let path = "/Users/fixture/.codex/config.toml"
        for keyPath in [
            ["hooks", "PreToolUse"], ["hooks", "PostToolUse"], ["hooks", "SessionStart"],
            ["hooks", "SessionEnd"], ["hooks", "SubagentStart"], ["hooks", "SubagentStop"],
            ["hooks", "UserPromptSubmit"], ["hooks", "Stop"], ["hooks", "Interrupt"],
            ["agents", "enabled"], ["agents", "default_subagent_model"],
            ["agents", "default_subagent_reasoning_effort"], ["agents", "max_concurrent_threads_per_session"],
        ] {
            #expect(DocsCatalog.keyDoc(filePath: path, keyPath: keyPath) != nil, "missing doc for \(keyPath)")
        }
    }

    @Test func instructionDocsDistinguishUserAndProjectScope() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        for (folder, filename) in [(".claude", "CLAUDE.md"), (".gemini", "GEMINI.md")] {
            let global = try #require(DocsCatalog.fileDoc(for: env.path(folder + "/" + filename)))
            let local = try #require(DocsCatalog.fileDoc(for: env.path("repo/" + filename)))
            #expect(global.title.localizedCaseInsensitiveContains("global"))
            #expect(!local.title.localizedCaseInsensitiveContains("global"))
            #expect(!local.body.contains("every project"))
            #expect(global.docsURL != nil && local.docsURL != nil)
        }
    }

    @Test func fileDocsRequireAWholePathComponent() {
        #expect(DocsCatalog.fileDoc(for: "/fixture/notopencode.json") == nil)
        #expect(DocsCatalog.keyDoc(filePath: "/fixture/notopencode.json", keyPath: ["model"]) == nil)
    }

    @Test func unrelatedFilesGetNoDoc() throws {
        #expect(DocsCatalog.fileDoc(for: "/Users/fixture/repo/README.md") == nil)
        #expect(DocsCatalog.keyDoc(filePath: "/Users/fixture/repo/.codex/config.toml", keyPath: ["totally_unknown_key"]) == nil)
    }
}
}
