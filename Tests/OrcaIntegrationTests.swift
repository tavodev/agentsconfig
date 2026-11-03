import Foundation
import Testing

extension AgentsConfigTestSuite {
@Suite("Orca integration", .serialized) @MainActor
struct OrcaIntegrationTests {
    private let orca = "Library/Application Support/orca"

    /// Fictitious Orca layout: one Claude profile (selected) whose skills
    /// link to ~/.claude, one Codex account whose AGENTS.md links to
    /// ~/.codex, and the shared Codex runtime home.
    private func installOrca(_ env: TestEnvironment) throws {
        try env.installClaude()
        try env.installCodex()
        let claude = "\(orca)/claude-profiles/acct-claude-0001/home"
        try env.write("\(claude)/settings.json", #"{"model":"opus","hooks":{}}"#)
        try env.write("\(claude)/CLAUDE.md", "@~/.claude/CLAUDE.md\n")
        try env.write("\(claude)/.claude.json", #"{"mcpServers":{"orca-only":{"command":"echo"}}}"#)
        try FileManager.default.createSymbolicLink(atPath: env.path("\(claude)/skills"), withDestinationPath: env.path(".claude/skills"))
        try env.write("\(orca)/claude-profiles/selected-host", env.path(claude))
        let codex = "\(orca)/codex-accounts/acct-codex-0002/home"
        try env.write("\(codex)/config.toml", "model = \"gpt-fake\"\n")
        try env.write("\(codex)/.orca-managed-home", "acct-codex-0002")
        try env.write("\(codex)/auth.json", #"{"OPENAI_API_KEY":"sk-test-FAKE-2222"}"#)
        try env.write("\(codex)/rules/default.rules", "prefix_rule(pattern = [\"ls\"], decision = \"allow\")\n")
        try FileManager.default.createSymbolicLink(atPath: env.path("\(codex)/AGENTS.md"), withDestinationPath: env.path(".codex/AGENTS.md"))
        try env.write("\(orca)/codex-runtime-home/home/config.toml", "model = \"gpt-fake\"\n")
    }

    @Test func orcaHomesAreDetectedAsSeparateAgents() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try installOrca(env)
        let agents = AgentRegistry.detect()
        let claude = try #require(agents.first { $0.id == "claude-code:orca:acct-claude-0001" })
        let codex = try #require(agents.first { $0.id == "codex:orca:acct-codex-0002" })
        let runtime = try #require(agents.first { $0.id == "codex:orca:runtime" })
        #expect(claude.name == "Claude Code · Orca acct-cla")
        #expect(claude.notes?.contains("the one Orca has selected") == true)
        let home = env.path("\(orca)/claude-profiles/acct-claude-0001/home")
        #expect(claude.files.contains { $0.path == home + "/settings.json" && $0.exists && $0.readOnly })
        #expect(claude.files.contains { $0.path == home + "/.claude.json" && $0.volatile })
        // Linked folders stay with the regular agent: one identity per file.
        #expect(!claude.files.contains { $0.role == .skills })
        #expect(!codex.files.contains { $0.path.hasSuffix("/AGENTS.md") })
        #expect(!codex.files.contains { $0.path.hasSuffix("/auth.json") })
        #expect(codex.files.contains { $0.path.hasSuffix("/rules/default.rules") })
        #expect(runtime.files.contains { $0.path.hasSuffix("/codex-runtime-home/home/config.toml") && $0.exists })
        // Regular agents are unchanged and never list Orca files.
        let regular = agents.filter { $0.id == "claude-code" || $0.id == "codex" }.flatMap(\.files)
        #expect(regular.count > 0 && regular.allSatisfy { !$0.path.contains("/orca/") })
        let definitions = AgentRegistry.definitions.filter { $0.id.contains(OrcaIntegration.idPrefix) }
        #expect(definitions.allSatisfy { $0.mcpDestinationPaths.isEmpty && $0.localSources.isEmpty })
    }

    @Test func orcaFilesShareDocumentationButNotLayerAnalysis() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try installOrca(env)
        let settings = env.path("\(orca)/claude-profiles/acct-claude-0001/home/settings.json")
        let config = env.path("\(orca)/codex-accounts/acct-codex-0002/home/config.toml")
        #expect(ConfigFileContext.settingsKind(for: settings) == .claude)
        #expect(ConfigFileContext.settingsKind(for: config) == .codex)
        #expect(DocsCatalog.settingsScope(filePath: settings) == .user)
        #expect(DocsCatalog.keyDoc(filePath: settings, keyPath: ["model"]) != nil)
        #expect(DocsCatalog.keyDoc(filePath: config, keyPath: ["model"]) != nil)
        #expect(DocsCatalog.fileDoc(for: settings)?.title == DocsCatalog.fileDoc(for: env.path(".claude/settings.json"))?.title)
        #expect(DocsCatalog.settingsCatalog(filePath: settings)?.isEmpty == false)
        let store = env.makeStore()
        #expect(store.layerContext(for: settings) == nil)
        #expect(store.layerContext(for: env.path(".claude/settings.json")) != nil)
        #expect(OrcaIntegration.home(containing: env.path("\(orca)/orca-stats.json")) == nil)
    }

    @Test func orcaIntegrationCanBeTurnedOff() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try installOrca(env)
        let store = env.makeStore()
        #expect(store.agents.contains { $0.id.hasPrefix("claude-code:orca:") })
        store.setOrcaIntegration(enabled: false)
        #expect(!store.agents.contains { $0.id.contains(OrcaIntegration.idPrefix) })
        let settings = env.path("\(orca)/claude-profiles/acct-claude-0001/home/settings.json")
        #expect(ConfigFileContext.settingsKind(for: settings) == nil)
        store.setOrcaIntegration(enabled: true)
        #expect(store.agents.filter { $0.id.contains(OrcaIntegration.idPrefix) }.count == 3)
    }

    // MARK: - Mirror model (Fase 1)

    private var claudeHome: String { "\(orca)/claude-profiles/acct-claude-0001/home" }
    private var codexHome: String { "\(orca)/codex-accounts/acct-codex-0002/home" }

    @Test func eachOrcaFileKnowsItsSourceAndRelation() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try installOrca(env)
        typealias O = OrcaIntegration
        func c(_ name: String) -> String { env.path("\(claudeHome)/\(name)") }
        func x(_ name: String) -> String { env.path("\(codexHome)/\(name)") }
        #expect(O.relation(for: c("settings.json")) == .mirroredCopy)
        #expect(O.sourcePath(for: c("settings.json")) == env.path(".claude/settings.json"))
        #expect(O.relation(for: c("CLAUDE.md")) == .importStub)
        #expect(O.sourcePath(for: c("CLAUDE.md")) == env.path(".claude/CLAUDE.md"))
        #expect(O.relation(for: c(".claude.json")) == .mergedState)
        #expect(O.sourcePath(for: c(".claude.json")) == env.path(".claude.json"))
        #expect(O.relation(for: c("statusline.sh")) == .mirroredCopy)
        #expect(O.sourcePath(for: c("statusline.sh")) == env.path(".claude/statusline.sh"))
        // Runtime state and nested files in unlinked folders belong to the account.
        #expect(O.relation(for: c("history.jsonl")) == .accountOwned)
        #expect(O.relation(for: c("hooks/own.sh")) == .accountOwned)
        #expect(O.sourcePath(for: c("hooks/own.sh")) == nil)
        #expect(O.relation(for: x("config.toml")) == .mergedState)
        #expect(O.sourcePath(for: x("config.toml")) == env.path(".codex/config.toml"))
        #expect(O.relation(for: x("rules/_orca-global-default.rules")) == .mirroredCopy)
        #expect(O.sourcePath(for: x("rules/_orca-global-default.rules")) == env.path(".codex/rules/default.rules"))
        #expect(O.relation(for: x("rules/default.rules")) == .accountOwned)
        #expect(O.relation(for: x("hooks.json")) == .accountOwned)
        #expect(O.sourcePath(for: env.path("\(orca)/codex-runtime-home/home/config.toml")) == env.path(".codex/config.toml"))
        #expect(O.relation(for: env.path(".claude/settings.json")) == nil)
        #expect(O.sourcePath(for: env.path(".codex/config.toml")) == nil)
    }

    @Test func sourcePathsFollowCustomRoots() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try installOrca(env)
        AppSettings.defaults.set(["claude-code": "~/alt-claude", "codex": "~/alt-codex"], forKey: "agentConfigRoots")
        defer { AppSettings.defaults.removeObject(forKey: "agentConfigRoots") }
        let claudeMd = env.path("\(claudeHome)/CLAUDE.md")
        // A custom CLAUDE_CONFIG_DIR gets a plain copy, not the import stub.
        #expect(OrcaIntegration.relation(for: claudeMd) == .mirroredCopy)
        #expect(OrcaIntegration.sourcePath(for: claudeMd) == env.path("alt-claude/CLAUDE.md"))
        #expect(OrcaIntegration.sourcePath(for: env.path("\(claudeHome)/.claude.json")) == env.path("alt-claude/.claude.json"))
        #expect(OrcaIntegration.sourcePath(for: env.path("\(codexHome)/config.toml")) == env.path("alt-codex/config.toml"))
    }

    @Test func regeneratedFilesAreReadOnlyWithStaticNotes() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try installOrca(env)
        try env.write(".codex/rules/default.rules", "prefix_rule(pattern = [\"pwd\"], decision = \"allow\")\n")
        try env.write("\(codexHome)/rules/_orca-global-default.rules", "prefix_rule(pattern = [\"pwd\"], decision = \"allow\")\n")
        let agents = AgentRegistry.detect()
        let claude = try #require(agents.first { $0.id == "claude-code:orca:acct-claude-0001" })
        let codex = try #require(agents.first { $0.id == "codex:orca:acct-codex-0002" })
        let runtime = try #require(agents.first { $0.id == "codex:orca:runtime" })
        func file(_ agent: Agent, _ suffix: String) throws -> TrackedFile {
            try #require(agent.files.first { $0.path.hasSuffix(suffix) })
        }
        for f in [try file(claude, "/settings.json"), try file(claude, "/CLAUDE.md"), try file(claude, "/.claude.json"),
                  try file(codex, "/config.toml"), try file(codex, "/_orca-global-default.rules"),
                  try file(runtime, "/config.toml")] {
            #expect(f.readOnly, "\(f.path)")
            let note = try #require(f.note)
            #expect(note == OrcaIntegration.note(for: f.path))
            #expect(!note.contains("/Users/") && !note.contains("acct-"))
            #expect(Loc.esTranslation(note) != nil, "missing Spanish note: \(note)")
        }
        #expect(try file(codex, "/rules/default.rules").readOnly == false)
        let store = env.makeStore()
        #expect(store.isReadOnly(env.path("\(claudeHome)/settings.json")))
        #expect(!store.isReadOnly(env.path("\(codexHome)/rules/default.rules")))
        // Regular homes stay editable.
        #expect(!store.isReadOnly(env.path(".claude/settings.json")))
    }

    @Test func managedHookMatcherFollowsOrca() {
        typealias O = OrcaIntegration
        #expect(O.isManagedHookCommand(#"if [ -z "${HOME-}" ]; then :; else "${HOME}/.orca/agent-hooks/claude-hook.sh"; fi"#))
        #expect(O.isManagedHookCommand(#"C:\Users\u\.orca\agent-hooks\claude-hook.cmd"#))
        #expect(O.isManagedHookCommand(#"C:/x/.orca/agent-hooks/orca-agent-hook.exe claude"#))
        let encoded = Data("& $env:HOME\\.orca\\agent-hooks\\claude-hook.ps1".utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }).base64EncodedString()
        #expect(O.isManagedHookCommand("powershell.exe -NoProfile -EncodedCommand \(encoded)"))
        #expect(!O.isManagedHookCommand("~/.claude/hooks/lint.sh"))
        #expect(!O.isManagedHookCommand(#"C:/x/agent-hooks/orca-agent-hook.exe codex"#))
        #expect(!O.isManagedHookCommand("agent-hooks/codex-hook.sh"))
        #expect(!O.isManagedHookCommand(nil))
    }

    @Test func settingsComparisonIgnoresOrcaHooks() {
        let source = #"{"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/.claude/hooks/lint.sh"}]}]}}"#
        let orcaHook = #"{"type":"command","command":"\"${HOME}/.orca/agent-hooks/claude-hook.sh\""}"#
        let copy = #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/.claude/hooks/lint.sh"},"# + orcaHook + #"]}],"Stop":[{"hooks":["# + orcaHook + #"]}]},"model":"opus"}"#
        #expect(OrcaIntegration.settingsMatch(copy: copy, source: source) == true)
        // Orca compares `{}` and a missing hooks key alike.
        #expect(OrcaIntegration.settingsMatch(copy: #"{"model":"opus","hooks":{"Stop":[{"hooks":["# + orcaHook + #"]}]}}"#,
                                              source: #"{"model":"opus"}"#) == true)
        // A user hook missing from the copy is a real difference.
        #expect(OrcaIntegration.settingsMatch(copy: #"{"model":"opus"}"#, source: source) == false)
        #expect(OrcaIntegration.settingsMatch(copy: "not json", source: source) == nil)
    }

    @Test func syncStatusCoversEveryOutcome() {
        typealias O = OrcaIntegration
        let old = Date(timeIntervalSince1970: 1_000), new = Date(timeIntervalSince1970: 2_000)
        func state(_ text: String?, _ date: Date?) -> O.FileState { O.FileState(text: text, modified: date) }
        func status(_ relation: O.Relation, _ kind: O.Kind, _ name: String, _ copy: O.FileState, _ source: O.FileState) -> O.SyncStatus {
            O.syncStatus(relation: relation, kind: kind, fileName: name, copy: copy, source: source)
        }
        // Mirrored copies.
        #expect(status(.mirroredCopy, .claude, "statusline.sh", state("a", new), state("a", old)) == .synced)
        #expect(status(.mirroredCopy, .claude, "statusline.sh", state("a", old), state("b", new)) == .pending)
        #expect(status(.mirroredCopy, .claude, "statusline.sh", state("a", new), state("b", old)) == .differs)
        #expect(status(.mirroredCopy, .claude, "statusline.sh", state("a", new), state(nil, nil)) == .sourceMissing)
        #expect(status(.mirroredCopy, .claude, "statusline.sh", state(nil, nil), state("b", old)) == .pending)
        #expect(status(.mirroredCopy, .codex, "AGENTS.md", state(nil, nil), state(nil, nil)) == .notApplicable)
        // settings.json ignores Orca's hooks.
        let orca = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"$HOME/.orca/agent-hooks/claude-hook.sh"}]}]}}"#
        #expect(status(.mirroredCopy, .claude, "settings.json", state(orca, new), state(#"{"model":"opus"}"#, old)) == .synced)
        #expect(status(.mirroredCopy, .claude, "settings.json", state(orca, old), state(#"{"model":"sonnet"}"#, new)) == .pending)
        #expect(status(.mirroredCopy, .claude, "settings.json", state(orca, new), state(#"{"model":"sonnet"}"#, old)) == .differs)
        // CLAUDE.md is synced only as the exact import stub.
        #expect(status(.importStub, .claude, "CLAUDE.md", state("@~/.claude/CLAUDE.md\n", old), state("# mine", new)) == .synced)
        #expect(status(.importStub, .claude, "CLAUDE.md", state("# edited", new), state("# mine", old)) == .differs)
        #expect(status(.importStub, .claude, "CLAUDE.md", state("@~/.claude/CLAUDE.md\n", old), state(nil, nil)) == .sourceMissing)
        // Claude state: shared keys merged, account keys and account trust kept.
        let sourceState = #"{"theme":"dark","userID":"src","mcpServers":{"a":{"command":"x"}},"projects":{"/p":{"allowedTools":[]}}}"#
        let copyState = #"{"theme":"dark","userID":"acct","oauthAccount":{},"mcpServers":{"a":{"command":"x"},"own":{"command":"y"}},"projects":{"/p":{"allowedTools":[],"hasTrustDialogAccepted":true}}}"#
        #expect(status(.mergedState, .claude, ".claude.json", state(copyState, old), state(sourceState, new)) == .synced)
        let changed = sourceState.replacingOccurrences(of: "dark", with: "light")
        #expect(status(.mergedState, .claude, ".claude.json", state(copyState, old), state(changed, new)) == .pending)
        #expect(status(.mergedState, .claude, ".claude.json", state(copyState, new), state(changed, old)) == .undetermined)
        // Codex config: home-owned tables ignored; other differences are not a verdict.
        let sourceToml = "model = \"gpt-fake\"\n[mcp_servers.docs]\ncommand = \"docs\"\n"
        let copyToml = sourceToml + "[mcp_servers.own]\ncommand = \"own\"\n[projects.\"/p\"]\ntrust_level = \"trusted\"\n[features]\ndaemon_auto_start = false\n"
        #expect(status(.mergedState, .codex, "config.toml", state(copyToml, new), state(sourceToml, old)) == .synced)
        let promoted = copyToml.replacingOccurrences(of: "gpt-fake", with: "gpt-other")
        #expect(status(.mergedState, .codex, "config.toml", state(promoted, new), state(sourceToml, old)) == .undetermined)
        #expect(status(.mergedState, .codex, "config.toml", state(promoted, old), state(sourceToml, new)) == .pending)
        #expect(status(.mergedState, .codex, "config.toml", state("model = ", new), state(sourceToml, old)) == .undetermined)
        #expect(status(.accountOwned, .codex, "hooks.json", state("{}", new), state(nil, nil)) == .notApplicable)
    }

    @Test func syncStatusReadsBothFilesFromDisk() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try installOrca(env)
        let settings = env.path("\(claudeHome)/settings.json")
        let source = try env.read(".claude/settings.json")
        try env.write("\(claudeHome)/settings.json", source)
        let past = Date(timeIntervalSinceNow: -60)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: env.path(".claude/settings.json"))
        #expect(OrcaIntegration.syncStatus(for: settings) == .synced)
        #expect(OrcaIntegration.syncStatus(for: env.path("\(claudeHome)/CLAUDE.md")) == .synced)
        try env.write(".claude/settings.json", #"{"model":"changed"}"#)
        #expect(OrcaIntegration.syncStatus(for: settings) == .pending)
        #expect(OrcaIntegration.syncStatus(for: env.path("\(codexHome)/rules/default.rules")) == .notApplicable)
        #expect(OrcaIntegration.syncStatus(for: env.path(".claude/settings.json")) == .notApplicable)
    }
}
}
