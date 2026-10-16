import Foundation
import Testing

extension AgentsConfigTestSuite {
@Suite("Hook map", .serialized) @MainActor
struct HookMapTests {
    /// Issue #22: hooks from user, project and local layers of several agents
    /// land in one event × matcher map with their origin and orphan mark.
    @Test func combinesLayersAndAgentsByEventAndMatcher() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.write(".claude/hooks/lint.sh", "#!/bin/sh\nexit 0\n", permissions: 0o700)
        try env.write(".claude/settings.json", """
        {"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"\(env.path(".claude/hooks/lint.sh"))"}]}],
                  "Stop":[{"hooks":[{"type":"command","command":"echo user-stop"}]}]}}
        """)
        try env.write(".codex/hooks.json", """
        {"hooks":{"state":{"trusted":"fixture"},"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo codex"}]}]}}
        """)
        let project = try env.makeProjectRoot(); defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, ".claude/settings.json", """
        {"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/private/tmp/fake-missing-hook.sh"}]}]}}
        """)
        try env.write(root: project, ".claude/settings.local.json", """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo local-stop"}]}]}}
        """)
        try env.write(root: project, ".cursor/hooks.json", #"{"version":1,"hooks":{"afterFileEdit":[{"command":"echo cursor"}]}}"#)
        let store = env.makeStore(); store.addProject(path: project.path)

        let entries = store.hookMap(projectRoot: project.path)
        let groups = HookMap.grouped(entries)
        let bash = try #require(groups.first { $0.event == "PreToolUse" && $0.matcher == "Bash" })
        #expect(bash.entries.map(\.agentID) == ["claude-code", "claude-code", "codex"])
        #expect(bash.entries.prefix(2).map(\.layer) == [.user, .project])
        #expect(bash.entries[0].missingPaths.isEmpty)
        #expect(bash.entries[1].missingPaths == ["/private/tmp/fake-missing-hook.sh"])

        let stop = try #require(groups.first { $0.event == "Stop" })
        #expect(stop.matcher == nil)
        #expect(stop.entries.map(\.layer) == [.user, .local])
        #expect(groups.contains { $0.event == "afterFileEdit" && $0.entries.first?.agentID == "cursor" })
        #expect(!entries.contains { $0.event == "state" })
        #expect(entries.allSatisfy { !$0.sourcePath.isEmpty })

        // The global context never shows a project's hooks.
        let global = store.hookMap(projectRoot: "")
        #expect(!global.contains { $0.sourcePath.hasPrefix(project.path + "/") })
        #expect(global.contains { $0.command == "echo codex" })
    }

    @Test func managedLayerAndArgvCommandsAreRecognized() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let managed = AppPaths.systemPath("/Library/Application Support/ClaudeCode/managed-settings.json")
        let entries = HookMap.build([
            .init(agentID: "claude-code", agentName: "Claude Code", path: managed,
                  tree: ["hooks": ["SessionStart": [["matcher": "*", "hooks": [["command": ["echo", "argv"]]]]]]]),
            .init(agentID: "windsurf", agentName: "Windsurf", path: env.path(".codeium/windsurf/hooks.json"),
                  tree: ["hooks": ["pre_run_command": [["command": "echo windsurf", "show_output": true]]]]),
        ], projectRoot: nil)
        #expect(entries.count == 2)
        let start = try #require(entries.first { $0.event == "SessionStart" })
        #expect(start.layer == .managed && start.matcher == nil && start.command == "echo argv")
        #expect(entries.first { $0.agentID == "windsurf" }?.layer == .user)
    }
}
}
