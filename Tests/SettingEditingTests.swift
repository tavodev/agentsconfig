import Foundation
import Testing

/// Adding documented keys and resetting them to their default: TOML edits
/// must leave every other byte alone, and the catalog must only offer keys
/// valid for the file's scope.
extension AgentsConfigTestSuite {
@Suite("Setting editing")
@MainActor
struct SettingEditingTests {

    @Test func insertsRootKeysBeforeTheFirstTableAndKeepsComments() throws {
        let source = "# top comment\nmodel = \"gpt\" # keep\n\n[tui]\ntheme = \"dark\"\n"
        let result = try TOMLScalarEditor.inserting(in: source, path: ["sandbox_mode"], value: .scalar(.string("read-only")))
        #expect(result == "# top comment\nmodel = \"gpt\" # keep\nsandbox_mode = \"read-only\"\n\n[tui]\ntheme = \"dark\"\n")
    }

    @Test func insertsIntoAnExistingSectionOrCreatesOne() throws {
        let source = "model = \"gpt\"\n\n[tui]\ntheme = \"dark\"\n\n# next section\n[history]\npersistence = \"none\"\n"
        let inSection = try TOMLScalarEditor.inserting(in: source, path: ["tui", "animations"], value: .scalar(.bool(false)))
        #expect(inSection == "model = \"gpt\"\n\n[tui]\ntheme = \"dark\"\nanimations = false\n\n# next section\n[history]\npersistence = \"none\"\n")
        let newSection = try TOMLScalarEditor.inserting(in: source, path: ["otel", "log_user_prompt"], value: .scalar(.bool(true)))
        #expect(newSection.hasPrefix(source))
        #expect(newSection.hasSuffix("\n[otel]\nlog_user_prompt = true\n"))
        let table = try TOMLScalarEditor.inserting(in: source, path: ["mcp_servers", "github"], value: .table)
        #expect(table.hasSuffix("\n[mcp_servers.github]\n"))
        let array = try TOMLScalarEditor.inserting(in: source, path: ["project_root_markers"], value: .emptyArray)
        #expect(array.contains("project_root_markers = []\n"))
    }

    @Test func dottedParentsFallBackToADottedKey() throws {
        // `tui` is defined by a dotted key, so a `[tui]` header would be invalid.
        let source = "tui.theme = \"dark\"\n"
        let result = try TOMLScalarEditor.inserting(in: source, path: ["tui", "animations"], value: .scalar(.bool(false)))
        #expect(result == "tui.theme = \"dark\"\ntui.animations = false\n")
    }

    @Test func insertingAnExistingKeyFails() {
        #expect(throws: TOMLScalarEditor.Failure.self) {
            try TOMLScalarEditor.inserting(in: "model = \"gpt\"\n", path: ["model"], value: .scalar(.string("x")))
        }
    }

    @Test func removingDeletesOnlyThatStatement() throws {
        let source = "# c\nmodel = \"gpt\" # trailing\nsandbox_mode = \"read-only\"\n[tui]\ntheme = \"dark\"\n"
        #expect(try TOMLScalarEditor.removing(in: source, path: ["model"]) == "# c\nsandbox_mode = \"read-only\"\n[tui]\ntheme = \"dark\"\n")
        #expect(try TOMLScalarEditor.removing(in: source, path: ["tui", "theme"]) == "# c\nmodel = \"gpt\" # trailing\nsandbox_mode = \"read-only\"\n[tui]\n")
    }

    @Test func crlfDocumentsKeepTheirLineEndings() throws {
        let result = try TOMLScalarEditor.inserting(in: "a = 1\r\n", path: ["b"], value: .scalar(.integer(2)))
        #expect(result == "a = 1\r\nb = 2\r\n")
    }

    @Test func catalogRespectsScopeAndHidesDeprecatedKeys() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let user = try #require(DocsCatalog.settingsCatalog(filePath: env.path(".claude/settings.json")))
        let keys = Set(user.map(\.key))
        #expect(keys.contains("autoCompactEnabled"))
        #expect(keys.contains("autoMode"))                 // user or managed
        #expect(!keys.contains("voiceEnabled"))            // deprecated
        #expect(!keys.contains("allowManagedHooksOnly"))   // managed only
        let project = try #require(DocsCatalog.settingsCatalog(filePath: env.path("repo/.claude/settings.json")))
        #expect(!Set(project.map(\.key)).contains("autoMode"))
        let codexProject = try #require(DocsCatalog.settingsCatalog(filePath: env.path("repo/.codex/config.toml")))
        #expect(!Set(codexProject.map(\.key)).contains("notify"))  // user-level only
        #expect(Set(codexProject.map(\.key)).contains("mcp_servers.<id>.command"))
        #expect(DocsCatalog.settingsCatalog(filePath: env.path("notes/settings.json")) == nil)
    }

    @Test func specsCarryOptionsDefaultsAndRanges() throws {
        let path = "/Users/fixture/.claude/settings.json"
        let effort = try #require(DocsCatalog.keyDoc(filePath: path, keyPath: ["effortLevel"])?.spec)
        #expect(effort.isEnum && effort.options == ["low", "medium", "high", "xhigh"])
        let theme = try #require(DocsCatalog.keyDoc(filePath: path, keyPath: ["theme"])?.spec)
        #expect(theme.allowsCustom && theme.options.contains("dark"))
        let window = try #require(DocsCatalog.keyDoc(filePath: path, keyPath: ["autoCompactWindow"])?.spec)
        #expect(window.rangeProblem(50) != nil && window.rangeProblem(200_000) == nil)
        let cleanup = try #require(DocsCatalog.keyDoc(filePath: path, keyPath: ["cleanupPeriodDays"])?.spec)
        #expect(cleanup.initialValue as? Int == 30)
        let sandbox = try #require(DocsCatalog.keyDoc(filePath: "/Users/fixture/.codex/config.toml", keyPath: ["sandbox_mode"])?.spec)
        #expect(sandbox.isEnum && sandbox.options.contains("workspace-write"))
    }

    @Test func tomlStringListsRewriteOnlyTheArray() throws {
        let source = "# c\nproject_root_markers = [\".git\", \"hg\"] # keep\n[tui]\nkeys = [\n  \"a\",\n]\n"
        let lists = try TOMLScalarEditor.stringLists(in: source)
        #expect(lists.map(\.path) == [["project_root_markers"], ["tui", "keys"]])
        let single = try TOMLScalarEditor.replacingStringList(in: source, path: ["project_root_markers"], with: [".git", "say \"hi\""])
        #expect(single == "# c\nproject_root_markers = [\".git\", \"say \\\"hi\\\"\"] # keep\n[tui]\nkeys = [\n  \"a\",\n]\n")
        let multi = try TOMLScalarEditor.replacingStringList(in: source, path: ["tui", "keys"], with: ["a", "b"])
        #expect(multi.hasSuffix("[tui]\nkeys = [\n  \"a\",\n  \"b\",\n]\n"))
        #expect(try TOMLScalarEditor.replacingStringList(in: source, path: ["tui", "keys"], with: []).hasSuffix("keys = []\n"))
    }

    @Test func tomlArraysWithCommentsOrOtherTypesStayInSource() throws {
        let source = "a = [\n  \"x\", # why\n]\nb = [1, 2]\n"
        #expect(try TOMLScalarEditor.stringLists(in: source).isEmpty)
    }

    @Test func geminiAndOpenCodeHaveReferenceDocsAndCatalogs() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let gemini = try #require(DocsCatalog.keyDoc(filePath: env.path(".gemini/settings.json"), keyPath: ["general", "defaultApprovalMode"]))
        #expect(gemini.spec?.isEnum == true && gemini.summaryES != nil)
        let server = try #require(DocsCatalog.keyDoc(filePath: env.path(".gemini/settings.json"), keyPath: ["mcpServers", "github", "command"]))
        #expect(server.spec?.kind == .string)
        let geminiKeys = Set(try #require(DocsCatalog.settingsCatalog(filePath: env.path(".gemini/settings.json"))).map(\.key))
        #expect(geminiKeys.contains("ui.theme"))
        #expect(!geminiKeys.contains { $0.hasPrefix("admin.") })
        let opencode = try #require(DocsCatalog.settingsCatalog(filePath: env.path("repo/opencode.json")))
        #expect(opencode.contains { $0.key == "share" && $0.spec.isEnum })
    }

    @Test func curatedSubFieldsAndObjectChildrenAreOffered() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let catalog = try #require(DocsCatalog.settingsCatalog(filePath: env.path(".claude/settings.json")))
        #expect(catalog.contains { $0.key == "statusLine.command" })
        let children = SettingCatalogEntry.children(of: ["modelSettings", "claude-opus-5-5"], in: catalog)
        let effort = try #require(children.first { $0.key == "modelSettings.claude-opus-5-5.effortLevel" })
        #expect(effort.placeholders.isEmpty && effort.spec.isEnum)
        #expect(SettingCatalogEntry.children(of: ["worktree"], in: catalog).contains { $0.key == "worktree.baseRef" })
    }

    @Test func layerNotesExplainValuesReplacedByAnotherLayer() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let project = try env.makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: project) }
        _ = try env.write(root: project, ".claude/settings.json", #"{"model":"opus","theme":"dark"}"#)
        _ = try env.write(root: project, ".claude/settings.local.json", #"{"model":"sonnet"}"#)
        let store = env.makeStore(); store.addProject(path: project.path)
        let shared = project.appendingPathComponent(".claude/settings.json").path
        let notes = store.layerNotes(for: shared)
        let model = try #require(notes["model"])
        #expect(model.state == "Shadowed")
        #expect(model.effectiveValue == "sonnet")
        #expect(model.effectiveSource?.hasSuffix("settings.local.json") == true)
        #expect(notes["theme"] == nil)
        #expect(store.layerNotes(for: project.appendingPathComponent(".claude/settings.local.json").path)["model"] == nil)
    }

    @Test func placeholderEntriesResolveUserSuppliedNames() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let entry = try #require(DocsCatalog.settingsCatalog(filePath: env.path(".codex/config.toml"))?
            .first { $0.key == "mcp_servers.<id>.command" })
        #expect(entry.placeholders == ["<id>"])
        #expect(entry.resolvedPath(["github"]) == ["mcp_servers", "github", "command"])
    }
}
}
