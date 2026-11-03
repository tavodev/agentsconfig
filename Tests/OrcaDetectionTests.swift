import Foundation
import Testing

extension AgentsConfigTestSuite {
@Suite("Orca detection, hooks and layer notes", .serialized) @MainActor
struct OrcaDetectionTests {
    private let orca = "Library/Application Support/orca"
    private var claudeHome: String { "\(orca)/claude-profiles/acct-claude-0001/home" }
    private var codexHome: String { "\(orca)/codex-accounts/acct-codex-0002/home" }

    private let managedClaudeHook = "/fake/orca/agent-hooks/claude-hook.sh"
    private let managedCodexHook = "/fake/orca/agent-hooks/codex-hook.sh"

    /// Fictitious Orca layout with hooks: the profile copy inherits the user
    /// hook, adds Orca's status hook and keeps one the original dropped.
    private func installOrca(_ env: TestEnvironment, selectClaude: Bool = true) throws {
        try env.installClaude(settingsJSON: """
        {"model":"opus","theme":"dark","permissions":{"allow":["Bash(ls)"]},
         "hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo user-stop"}]}]}}
        """)
        try env.installCodex()
        try env.write(".codex/config.toml", """
        model = "gpt-fake"
        approval_policy = "on-request"
        [tui]
        theme = "light"
        [mcp_servers.shared]
        command = "echo"
        """)
        try env.write("\(claudeHome)/settings.json", """
        {"model":"opus","theme":"light","extra":true,"permissions":{"allow":["Bash(ls)"]},
         "hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo user-stop"},
                                     {"type":"command","command":"\(managedClaudeHook) Stop"}]}],
                  "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo dropped"}]}]}}
        """)
        try env.write("\(claudeHome)/CLAUDE.md", "@~/.claude/CLAUDE.md\n")
        try env.write("\(claudeHome)/.claude.json", """
        {"oauthAccount":{"emailAddress":"fake@example.test"},"mcpServers":{"orca-only":{"command":"echo"}}}
        """)
        try env.write("\(orca)/claude-profiles/selected-host", selectClaude ? env.path(claudeHome) : "")
        try env.write("\(codexHome)/config.toml", """
        model = "gpt-fake"
        approval_policy = "never"
        [tui]
        theme = "dark"
        [projects."/fake/project"]
        trust_level = "trusted"
        [mcp_servers.shared]
        command = "echo"
        [mcp_servers.own]
        command = "echo"
        """)
        try env.write("\(codexHome)/.orca-managed-home", "acct-codex-0002")
        try env.write("\(codexHome)/hooks.json", """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\(managedCodexHook)"},
                                     {"type":"command","command":"echo account-stop"}]}]}}
        """)
    }

    // MARK: - Data folder

    @Test func dataFolderFollowsSettingsThenEnvironmentThenDefault() {
        typealias O = OrcaIntegration
        let home = "/fake/home"
        #expect(O.dataRoot(custom: nil, environment: nil, isolated: false, home: home)
            == ("/fake/home/Library/Application Support/orca", .standard))
        #expect(O.dataRoot(custom: nil, environment: "/fake/orca-data/", isolated: false, home: home)
            == ("/fake/orca-data", .environment))
        // Orca treats an empty variable as unset.
        #expect(O.dataRoot(custom: nil, environment: "", isolated: false, home: home).origin == .standard)
        #expect(O.dataRoot(custom: nil, environment: "~/orca-alt", isolated: false, home: home).path == "/fake/home/orca-alt")
        // Isolated runs never read the app environment.
        #expect(O.dataRoot(custom: nil, environment: "/fake/orca-data", isolated: true, home: home)
            == ("/fake/home/Library/Application Support/orca", .standard))
        // A folder chosen in Settings wins over the environment.
        #expect(O.dataRoot(custom: "/fake/chosen", environment: "/fake/orca-data", isolated: false, home: home)
            == ("/fake/chosen", .chosen))
    }

    @Test func isolatedRunUsesIsolatedHomeAndChosenFolderRedirectsDetection() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        #expect(OrcaIntegration.root == env.path(orca))
        #expect(OrcaIntegration.dataRootResolution.origin == .standard)

        let custom = "orca-alt"
        try env.write("\(custom)/claude-profiles/acct-alt-0003/home/settings.json", #"{"model":"opus"}"#)
        let store = env.makeStore()
        #expect(!store.agents.contains { $0.id == "claude-code:orca:acct-alt-0003" })
        store.setOrcaDataFolder(path: env.path(custom))
        #expect(OrcaIntegration.dataRootResolution == (env.path(custom), .chosen))
        #expect(store.agents.contains { $0.id == "claude-code:orca:acct-alt-0003" })
        let settings = env.path("\(custom)/claude-profiles/acct-alt-0003/home/settings.json")
        #expect(OrcaIntegration.relation(for: settings) == .mirroredCopy)
        store.setOrcaDataFolder(path: nil)
        #expect(OrcaIntegration.root == env.path(orca))
        #expect(!store.agents.contains { $0.id.contains(OrcaIntegration.idPrefix) })
    }

    // MARK: - Selected account

    @Test func selectedAccountComesFromTheClaudePointerOnly() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try installOrca(env)
        var homes = OrcaIntegration.homes()
        #expect(homes.first { $0.kind == .claude }?.selected == true)
        // Codex selection lives in Orca's settings store: never inferred.
        #expect(homes.filter { $0.kind == .codex }.allSatisfy { !$0.selected })

        // An empty pointer means "System default": no profile is selected.
        try env.write("\(orca)/claude-profiles/selected-host", "")
        homes = OrcaIntegration.homes()
        #expect(homes.allSatisfy { !$0.selected })
        #expect(OrcaIntegration.selectedClaudeHome(root: OrcaIntegration.root) == nil)
    }

    @Test func profilesWithoutRegistryOrMarkerAreNotMarkedOrphaned() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try installOrca(env)
        // No `profile.json`, no Orca settings store: still an ordinary profile.
        try env.write("\(orca)/claude-profiles/acct-retired-0009/home/settings.json", #"{"model":"opus"}"#)
        let agents = AgentRegistry.detect()
        let retired = try #require(agents.first { $0.id == "claude-code:orca:acct-retired-0009" })
        #expect(retired.notes?.contains("the one Orca has selected") == false)
        #expect(!retired.notes!.localizedCaseInsensitiveContains("orphan"))
    }

    // MARK: - Hooks

    @Test func managedHookCommandsAreRecognizedPerAgent() {
        typealias O = OrcaIntegration
        #expect(O.isManagedCodexHookCommand("/fake/agent-hooks/codex-hook.sh"))
        #expect(O.isManagedCodexHookCommand(#"C:\fake\agent-hooks\codex-hook.cmd"#))
        #expect(O.isManagedCodexHookCommand("/fake/agent-hooks/orca-agent-hook.exe codex Stop"))
        let encoded = Data("& 'C:/fake/agent-hooks/codex-hook.ps1'".utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }).base64EncodedString()
        #expect(O.isManagedCodexHookCommand("powershell -NoProfile -EncodedCommand " + encoded))
        #expect(!O.isManagedCodexHookCommand("/fake/agent-hooks/claude-hook.sh"))
        #expect(!O.isManagedCodexHookCommand("echo codex-hook"))
        #expect(O.isManagedHook("/fake/agent-hooks/claude-hook.sh", agentID: "claude-code:orca:acct"))
        #expect(!O.isManagedHook("/fake/agent-hooks/claude-hook.sh", agentID: "codex"))
        #expect(!O.isManagedHook("/fake/agent-hooks/claude-hook.sh", agentID: "gemini-cli"))
    }

    @Test func hookMapShowsOrcaAccountsAndInheritedHooks() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try installOrca(env)
        try env.write(".codex/hooks.json", """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\(managedCodexHook)"}]}]}}
        """)
        let store = env.makeStore()
        let entries = store.hookMap(projectRoot: "")
        let claudeSettings = env.path("\(claudeHome)/settings.json")
        let fromOrca = entries.filter { $0.sourcePath == claudeSettings }
        #expect(fromOrca.count == 3)
        #expect(fromOrca.allSatisfy { $0.orcaAccount == "acct-cla" && $0.orcaSelected && $0.layer == .user })

        let origin = env.path(".claude/settings.json")
        let inherited = try #require(fromOrca.first { $0.command == "echo user-stop" })
        #expect(inherited.orcaRole == .inherited(origin: origin))
        #expect(fromOrca.first { $0.command.hasPrefix(managedClaudeHook) }?.orcaRole == .managed)
        #expect(fromOrca.first { $0.command == "echo dropped" }?.orcaRole == .staleCopy(origin: origin))

        // The regular agent keeps its hook, unmarked; same event, two agents.
        let regular = try #require(entries.first { $0.sourcePath == origin })
        #expect(regular.orcaRole == nil && regular.orcaAccount == nil && regular.agentID == "claude-code")

        // Codex account hooks.json belongs to the account; Orca's hook is managed.
        let codexHooks = entries.filter { $0.sourcePath == env.path("\(codexHome)/hooks.json") }
        #expect(codexHooks.first { $0.command == managedCodexHook }?.orcaRole == .managed)
        #expect(codexHooks.first { $0.command == "echo account-stop" }?.orcaRole == .accountOwned)
        #expect(codexHooks.allSatisfy { $0.orcaAccount == "acct-cod" && !$0.orcaSelected })
        // Orca's status hook in the regular Codex home ("System default").
        let systemDefault = try #require(entries.first { $0.sourcePath == env.path(".codex/hooks.json") })
        #expect(systemDefault.orcaRole == .managed && systemDefault.orcaAccount == nil)
    }

    @Test func unreadableOriginKeepsHooksInheritedWithoutComparison() {
        let source = HookMapSource(agentID: "claude-code:orca:acct", agentName: "Claude Code · Orca acct",
                                   path: "/fake/orca/claude-profiles/acct/home/settings.json",
                                   tree: ["hooks": ["Stop": [["hooks": [["command": "echo x"]]]]]],
                                   orca: OrcaHookSource(account: "acct", selected: false,
                                                        originPath: "/fake/.claude/settings.json", originCommands: nil))
        let entries = HookMap.build([source], projectRoot: nil)
        #expect(entries.map(\.orcaRole) == [.inherited(origin: "/fake/.claude/settings.json")])
    }

    // MARK: - Layer notes

    @Test func claudeSettingsNotesExplainTheOriginInsteadOfSilence() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try installOrca(env)
        let store = env.makeStore()
        let settings = env.path("\(claudeHome)/settings.json")
        #expect(store.layerContext(for: settings) == nil)  // the resolver is unchanged
        let notes = store.layerNotes(for: settings)
        let origin = env.path(".claude/settings.json")

        let model = try #require(notes["model"])
        #expect(model.state == OrcaIntegration.noteCopied && model.informational && model.project == nil)
        #expect(model.reason == OrcaIntegration.reasonSettingsCopied)
        #expect(notes["permissions.allow"]?.state == OrcaIntegration.noteCopied)

        let theme = try #require(notes["theme"])
        #expect(theme.state == OrcaIntegration.noteDiffers && !theme.informational)
        #expect(theme.effectiveValue == "dark" && theme.effectiveSource == origin)

        #expect(notes["extra"]?.state == OrcaIntegration.noteMissing)
        #expect(notes["hooks"]?.state == OrcaIntegration.noteStatusHooks)
        #expect(notes["hooks.Stop"] == nil)

        // Regular homes still go through the resolver, never through Orca notes.
        #expect(store.layerContext(for: origin) != nil)
        #expect(!store.layerNotes(for: origin).values.contains { $0.state == OrcaIntegration.noteCopied })
    }

    @Test func claudeStateAndCodexConfigNotesSeparateOwnAndPromotedKeys() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try installOrca(env)
        let store = env.makeStore()

        let state = store.layerNotes(for: env.path("\(claudeHome)/.claude.json"))
        #expect(state["oauthAccount"]?.state == OrcaIntegration.noteAccountOwned)
        #expect(state["oauthAccount"]?.reason == OrcaIntegration.reasonStateAccount)
        #expect(state["mcpServers"]?.state == OrcaIntegration.noteMerged)
        #expect(state["mcpServers.orca-only"]?.reason == OrcaIntegration.reasonStateOnlyHere)

        let config = store.layerNotes(for: env.path("\(codexHome)/config.toml"))
        #expect(config["model"]?.state == OrcaIntegration.notePromoted)
        #expect(config["model"]?.informational == true)
        let approval = try #require(config["approval_policy"])
        #expect(approval.state == OrcaIntegration.noteDiffers)
        #expect(approval.reason == OrcaIntegration.reasonCodexPromotedDiffers)
        #expect(approval.effectiveValue == "on-request" && approval.effectiveSource == env.path(".codex/config.toml"))
        #expect(config["tui.theme"]?.reason == OrcaIntegration.reasonCodexPromotedDiffers)
        #expect(config["projects"]?.reason == OrcaIntegration.reasonCodexHomeOwned)
        #expect(config["mcp_servers.own"]?.reason == OrcaIntegration.reasonCodexOwnServer)
        #expect(config["mcp_servers.shared"]?.state == OrcaIntegration.noteCopied)
        #expect(config["mcp_servers.shared"]?.reason == OrcaIntegration.reasonCodexMirrored)

        // Files Orca does not regenerate from a settings file get no notes.
        #expect(store.layerNotes(for: env.path("\(codexHome)/hooks.json")).isEmpty)
    }

    @Test func missingOriginIsReportedPerKey() {
        let notes = OrcaIntegration.layerNotes(relation: .mirroredCopy, kind: .claude, fileName: "settings.json",
                                               copy: ["model": "opus"], origin: nil, originPath: "/fake/.claude/settings.json")
        #expect(notes["model"]?.state == OrcaIntegration.noteUnreadable)
        #expect(notes["model"]?.informational == false)
        #expect(OrcaIntegration.layerNotes(relation: .accountOwned, kind: .codex, fileName: "hooks.json",
                                           copy: ["hooks": [:]], origin: nil, originPath: nil).isEmpty)
    }
}
}
