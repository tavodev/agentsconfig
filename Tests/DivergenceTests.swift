import Foundation
import Testing

extension AgentsConfigTestSuite {
@Suite("Divergences", .serialized) @MainActor
struct DivergenceTests {
    @Test func instructionFilesDifferUnlessIdenticalOrImportOnly() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.installAllAgents()
        let project = try env.makeProjectRoot(); defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, "AGENTS.md", "# Rules\nUse tabs.\n")
        try env.write(root: project, "CLAUDE.md", "# Rules\nUse spaces.\n")
        let store = env.makeStore(); store.addProject(path: project.path)

        let local = try #require(store.divergences(projectRoot: project.path).first { $0.kind == .instructions })
        #expect(local.subject == "AGENTS.md · CLAUDE.md")
        #expect(Set(local.members.map(\.family)) == ["claude-code", "codex"])
        // The fixtures' global instruction files all say different things.
        #expect(store.divergences(projectRoot: "").contains { $0.kind == .instructions && $0.members.count == 4 })

        try env.write(root: project, "CLAUDE.md", "# Rules  \r\nUse tabs.\n\n")
        store.handleWatchEvent(project.appendingPathComponent("CLAUDE.md").path)
        #expect(!store.divergences(projectRoot: project.path).contains { $0.kind == .instructions })
        try env.write(root: project, "CLAUDE.md", "@AGENTS.md\n")
        store.handleWatchEvent(project.appendingPathComponent("CLAUDE.md").path)
        #expect(!store.divergences(projectRoot: project.path).contains { $0.kind == .instructions })
    }

    /// Aligning stages the existing review; the buffer changes only after
    /// confirmation and the disk only after the usual save.
    @Test func aligningInstructionsGoesThroughReview() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.installClaude(); try env.installCodex()
        let project = try env.makeProjectRoot(); defer { try? FileManager.default.removeItem(at: project) }
        let agents = try env.write(root: project, "AGENTS.md", "# Shared\n").path
        let claude = try env.write(root: project, "CLAUDE.md", "# Old\n").path
        let store = env.makeStore(); store.addProject(path: project.path)

        #expect(store.alignText(target: claude, toMatch: agents))
        let review = try #require(store.pendingMcpReview)
        #expect(review.proposedText == "# Shared\n" && review.originalText == "# Old\n" && !review.createsFile)
        #expect(store.text(for: claude) == "# Old\n")
        #expect(store.confirmMcpReview())
        #expect(store.text(for: claude) == "# Shared\n")
        #expect(try String(contentsOfFile: claude, encoding: .utf8) == "# Old\n")

        store.discardEdit(path: claude)
        #expect(store.alignText(target: claude, toMatch: agents, importOnly: true))
        #expect(store.pendingMcpReview?.proposedText == "@AGENTS.md\n")
        try "# Changed outside\n".write(toFile: claude, atomically: true, encoding: .utf8)
        #expect(!store.confirmMcpReview())
        #expect(store.actionError != nil)
    }

    @Test func skillsMissingOrDifferentAreDetectedAndCopiedAfterReview() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.installAllAgents()
        try env.write(".gemini/skills/demo/SKILL.md", "---\nname: demo\ndescription: other\n---\n")
        try env.write(".claude/skills/bundle/SKILL.md", "---\nname: bundle\ndescription: x\n---\n")
        try env.write(".claude/skills/bundle/scripts/run.sh", "#!/bin/sh\n")
        let store = env.makeStore()

        let global = store.divergences(projectRoot: "")
        let demo = try #require(global.first { $0.kind == .skills && $0.subject == "demo" })
        #expect(demo.summary == "Copies of this skill differ between agents.")
        // OpenCode also reads ~/.claude/skills; Antigravity has its own folder.
        #expect(Set(demo.missingFamilies) == ["codex", "antigravity"])

        let claudeDemo = try #require(demo.members.first { $0.family == "claude-code" }).path
        #expect(store.copySkill(from: claudeDemo, to: "codex", scope: ""))
        let review = try #require(store.pendingMcpReview)
        #expect(review.createsFile && review.path == env.path(".agents/skills/demo/SKILL.md"))
        #expect(!FileManager.default.fileExists(atPath: review.path))
        #expect(store.confirmMcpReview())
        #expect(try env.read(".agents/skills/demo/SKILL.md") == "---\nname: demo\n---\n")
        #expect(env.posixPermissions(".agents/skills/demo/SKILL.md") == 0o600)
        let after = try #require(store.divergences(projectRoot: "").first { $0.kind == .skills && $0.subject == "demo" })
        #expect(after.missingFamilies == ["antigravity"])

        let bundle = try #require(store.divergences(projectRoot: "").first { $0.subject == "bundle" })
        #expect(!store.copySkill(from: bundle.members[0].path, to: "codex", scope: ""))
        #expect(store.pendingMcpReview == nil)
    }

    @Test func mcpDefinitionsThatDifferAcrossFamiliesAreFlagged() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.installClaude(); try env.installCodex()
        let store = env.makeStore()
        #expect(!store.mcpDefinitionsDiverge("docs"))
        #expect(!store.divergences(projectRoot: "").contains { $0.kind == .mcp })

        try env.write(".codex/config.toml", """
        [mcp_servers.docs]
        command = "npx"
        args = ["-y", "@fake/docs-mcp@2.0.0"]
        """)
        store.handleWatchEvent(env.path(".codex/config.toml"))
        #expect(store.mcpDefinitionsDiverge("docs"))
        let mcp = try #require(store.divergences(projectRoot: "").first { $0.kind == .mcp })
        #expect(mcp.subject == "docs" && Set(mcp.members.map(\.family)) == ["claude-code", "codex"])
    }
}
}
