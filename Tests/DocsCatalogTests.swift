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

    @Test func claudeKeysFromTheOfficialReferenceLinkToTheirAnchor() throws {
        let path = "/Users/fixture/.claude/settings.json"
        for (keyPath, anchor) in [
            (["agentPushNotifEnabled"], "agentpushnotifenabled"),
            (["autoCompactEnabled"], "autocompactenabled"),
            (["disableClaudeAiConnectors"], "disableclaudeaiconnectors"),
            (["attribution", "commit"], "attribution-commit"),
            (["permissions", "allow"], "permissions-allow"),
        ] {
            let doc = try #require(DocsCatalog.keyDoc(filePath: path, keyPath: keyPath), "missing doc for \(keyPath)")
            #expect(doc.summaryES != nil)
            #expect(doc.docsURL?.absoluteString == "https://code.claude.com/docs/en/settings-reference#" + anchor)
        }
    }

    @Test func claudeSubFieldsAndPerModelEntriesResolve() throws {
        let path = "/Users/fixture/.claude/settings.json"
        let command = try #require(DocsCatalog.keyDoc(filePath: path, keyPath: ["statusLine", "command"]))
        #expect(command.docsURL?.fragment == "statusline")
        let perModel = try #require(DocsCatalog.keyDoc(filePath: path, keyPath: ["modelSettings", "claude-opus-5-5", "effortLevel"]))
        #expect(perModel.docsURL?.fragment == "modelsettings")
    }

    @Test func curatedValueListsSurviveTheReferenceSummary() throws {
        let doc = try #require(DocsCatalog.keyDoc(filePath: "/Users/fixture/.claude/settings.json", keyPath: ["effortLevel"]))
        #expect(doc.values?["high"] != nil)
        #expect(doc.docsURL != nil)
    }

    @Test func codexPlaceholderKeysResolveAndPreferTheMostSpecificPattern() throws {
        let path = "/Users/fixture/.codex/config.toml"
        let command = try #require(DocsCatalog.keyDoc(filePath: path, keyPath: ["mcp_servers", "github", "command"]))
        #expect(command.docsURL == DocsCatalog.codexReferenceURL)
        let defaults = try #require(DocsCatalog.keyDoc(filePath: path, keyPath: ["apps", "_default", "enabled"]))
        let perApp = try #require(DocsCatalog.keyDoc(filePath: path, keyPath: ["apps", "slack", "enabled"]))
        #expect(defaults.summary != perApp.summary)
        // A curated event description beats the generic `hooks.<Event>` pattern.
        let hook = try #require(DocsCatalog.keyDoc(filePath: path, keyPath: ["hooks", "PreToolUse"]))
        #expect(hook.summary.contains("before"))
    }

    @Test func curatedOnlyTablesStillLinkToTheirOfficialPage() throws {
        let gemini = try #require(DocsCatalog.keyDoc(filePath: "/Users/fixture/.gemini/settings.json", keyPath: ["theme"]))
        #expect(gemini.docsURL != nil)
        let opencode = try #require(DocsCatalog.keyDoc(filePath: "/Users/fixture/repo/opencode.json", keyPath: ["model"]))
        #expect(opencode.docsURL != nil)
    }

    @Test func unrelatedFilesGetNoDoc() throws {
        #expect(DocsCatalog.fileDoc(for: "/Users/fixture/repo/README.md") == nil)
        #expect(DocsCatalog.keyDoc(filePath: "/Users/fixture/repo/.codex/config.toml", keyPath: ["totally_unknown_key"]) == nil)
    }
}
}
