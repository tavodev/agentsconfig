import Testing
import Foundation

/// Local (per-repository) config inspection: registering a project root
/// surfaces the same per-agent grouping, watching, history and MCP indexing
/// as global agents, without becoming a valid MCP copy destination.
extension AgentsConfigTestSuite {
@Suite("Project-local config", .serialized)
@MainActor
struct ProjectLocalTests {

    @Test func submodulePathsRespectGitSectionsQuotesCommentsAndEscapes() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let project = try env.makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, ".gitmodules", #"""
        [include]
          path = ignored
        [submodule "quoted"]
          path = "quoted module" # comment
        [SUBMODULE "hash"]
          PATH = "hash#semi;quote\"folder"
        [submodule.old]
          path = legacy ; comment
        [submodule "continued"]
          path = child\
        /nested
        """#)
        #expect(AgentRegistry.directSubmodulePaths(at: project.path) == [
            "quoted module", "hash#semi;quote\"folder", "legacy", "child/nested"
        ])
    }

    @Test func repeatedSubmodulePathUsesTheLastDeclaration() {
        let parsed = SubmoduleDiscovery.parse("""
        [submodule "same"]
        path = old
        [submodule "same"]
        path = current
        [submodule "other"]
        path = second
        """)
        #expect(parsed == ["current", "second"])
    }

    @Test func unsafeSubmoduleRootsNeverEnterStoreOrHistory() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let project = try env.makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: project) }
        let outside = try env.makeProjectRoot("outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        try env.write(root: outside, ".claude/settings.json", "{\"model\":\"outside-fixture\"}")
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("linked"), withDestinationURL: outside)
        try env.write(root: project, ".gitmodules", """
        [submodule "parent"]
        path = ../\(outside.lastPathComponent)
        [submodule "absolute"]
        path = \(outside.path)
        [submodule "link"]
        path = linked
        """)
        let store = env.makeStore()
        store.addProject(path: project.path)
        #expect(store.agents.filter { $0.projectRoot == project.path }.isEmpty)
        #expect(store.documents.isEmpty)
        #expect(store.histories.isEmpty)
    }

    @Test func submoduleAliasesAndCyclesAreNotRepeated() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let project = try env.makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, "child/AGENTS.md", "# Fixture")
        try FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent("alias").path,
            withDestinationPath: "child")
        try FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent("child/loop").path,
            withDestinationPath: "..")
        try env.write(root: project, ".gitmodules", """
        [submodule "first"]
        path = child
        [submodule "duplicate"]
        path = child
        [submodule "alias"]
        path = alias
        """)
        try env.write(root: project, "child/.gitmodules", "[submodule \"loop\"]\npath = loop\n")
        #expect(AgentRegistry.submodulePaths(root: project.path) == ["child"])
    }

    @Test func symlinkedGitmodulesIsNotRead() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let project = try env.makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: project) }
        let manifest = try env.write("manifest", "[submodule \"fake\"]\npath = child\n")
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent(".gitmodules"), withDestinationURL: manifest)
        #expect(AgentRegistry.directSubmodulePaths(at: project.path).isEmpty)
    }

    @Test func submoduleLimitsAndRejectedManifestsProduceNotices() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let project = try env.makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, ".gitmodules", "[submodule \"child\"]\npath = child\n[submodule \"other\"]\npath = other\n")
        try env.write(root: project, "child/.gitmodules", "[submodule \"nested\"]\npath = nested\n")
        let count = SubmoduleDiscovery.scan(root: project.path, maxCount: 1)
        #expect(count.paths == ["child"])
        #expect(count.notices.contains { $0.problem == .countLimit })
        let depth = SubmoduleDiscovery.scan(root: project.path, maxDepth: 1)
        #expect(!depth.paths.contains("child/nested"))
        #expect(depth.notices.contains { $0.problem == .depthLimit })
        for invalid in ["[submodule \"oops]\npath = child\n", "[submodule \"x\"]\npath = bad\\q\n",
                        String(repeating: "#", count: 1_000_001)] {
            try env.write(root: project, ".gitmodules", invalid)
            let scan = SubmoduleDiscovery.scan(root: project.path)
            #expect(scan.paths.isEmpty)
            #expect(scan.notices.contains { $0.problem == .invalidManifest })
        }
    }

    @Test func projectNoticesUpdateWhenManifestIsReplaced() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let project = try env.makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, ".gitmodules", "[submodule \"escape\"]\npath = ../outside\n")
        let store = env.makeStore()
        store.addProject(path: project.path)
        #expect(store.projectDiscoveryNotices[project.path]?.contains { $0.problem == .invalidPath } == true)
        try env.write(root: project, ".gitmodules", "# Empty manifest\n")
        store.handleWatchEvent(project.path)
        #expect(store.projectDiscoveryNotices[project.path]?.isEmpty == true)
    }

    @Test func missingSkillFoldersDoNotProduceFalseEscapeNotices() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let project = try env.makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, ".claude/settings.json", "{}")
        let local = try #require(AgentRegistry.detectLocal(projectRoot: project.path).first {
            $0.agent.id.hasPrefix("claude-code::")
        })
        #expect(local.agent.notes?.contains("Skipped skill") == false)
        #expect(local.def.sources.contains { $0.path == project.appendingPathComponent(".claude/skills").path })
    }

    @Test func skillRootsOutsideProjectAreNotTraversed() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let project = try env.makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, ".codex/config.toml", "model = 'fixture'")
        try env.write(root: project, ".agents/README.md", "Fixture")
        try FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent(".agents/skills").path,
            withDestinationPath: project.deletingLastPathComponent().path)
        let store = env.makeStore()
        store.addProject(path: project.path)
        let agent = try #require(store.agents.first { $0.id == "codex::\(project.path)" })
        #expect(agent.files.filter { $0.role == .skills }.isEmpty)
    }

    @Test func sharedProjectSkillsAppearForCodexAndClaude() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let project = try env.makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, ".agents/skills/flutter-expert/SKILL.md", "# Fixture skill")
        try env.write(root: project, ".claude/settings.json", "{}")
        try FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent(".claude/skills").path,
            withDestinationPath: "../.agents/skills")
        try FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent(".agents/skills/cycle").path,
            withDestinationPath: ".")
        let store = env.makeStore()
        store.addProject(path: project.path)
        for id in ["codex", "claude-code"] {
            let agent = try #require(store.agents.first { $0.id == "\(id)::\(project.path)" })
            let skills = agent.files.filter { $0.role == .skills }
            #expect(skills.count == 1)
            #expect(skills.first?.displayName == "flutter-expert")
        }
        // TestEnvironment already gives a physical, realpath-canonical root.
        let sharedPath = project.appendingPathComponent(".agents/skills/flutter-expert/SKILL.md").path
        let owners = store.agents.filter { $0.projectRoot == project.path && $0.files.contains { $0.path == sharedPath } }
        #expect(Set(owners.map { String($0.id.split(separator: ":").first!) }) == ["codex", "claude-code", "gemini-cli", "antigravity", "opencode"])
        store.updateEdit(path: sharedPath, text: "# Shared draft")
        for owner in owners {
            let file = try #require(owner.files.first { $0.role == .skills })
            #expect(store.text(for: file.path) == "# Shared draft")
        }
        store.save(path: sharedPath)
        #expect(try String(contentsOfFile: sharedPath, encoding: .utf8) == "# Shared draft")
        #expect(!store.history(for: sharedPath).isEmpty)
    }

    @Test func codexProjectDiscoversAgentsHooksAndActivityWithoutMainConfig() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let project = try env.makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, ".codex/agents/backend-dev.toml", "model = 'fixture'\n")
        try env.write(root: project, ".codex/agents/notes.txt", "Not an agent definition")
        try env.write(root: project, ".codex/hooks/check.sh", "# Fixture: never execute\n")
        try env.write(root: project, ".codex/activity-2026-09.jsonl", "{\"event\":\"fixture\"}\n")
        try env.write(root: project, ".codex/unrelated.jsonl", "{}\n")
        let store = env.makeStore()
        store.addProject(path: project.path)
        let agent = try #require(store.agents.first { $0.id == "codex::\(project.path)" })
        let files = Dictionary(uniqueKeysWithValues: agent.files.map { (URL(fileURLWithPath: $0.path).lastPathComponent, $0) })
        #expect(files["backend-dev.toml"]?.role == .agents)
        #expect(files["check.sh"]?.role == .hooks)
        #expect(files["notes.txt"] == nil)
        #expect(files["unrelated.jsonl"] == nil)
        let log = try #require(files["activity-2026-09.jsonl"])
        #expect(log.volatile && log.excludeFromHistory && log.readOnly)
        #expect(store.history(for: log.path).isEmpty)
    }

    @Test func detectsOnlyAgentsWithMatchingLocalFiles() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let project = try env.makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, ".claude/settings.json", "{}")
        try env.write(root: project, ".mcp.json", #"{"mcpServers":{"docs":{"command":"npx","args":["-y","@fake/docs"]}}}"#)
        try env.write(root: project, ".codex/config.toml", "model = \"fixture\"\n")

        let store = env.makeStore()
        store.addProject(path: project.path)

        let claudeID = "claude-code::\(project.path)"
        let codexID = "codex::\(project.path)"
        let claude = try #require(store.agents.first { $0.id == claudeID })
        #expect(claude.projectRoot == project.path)
        #expect(claude.name.contains(project.lastPathComponent))
        // All declared local sources are listed (parity with global agents),
        // but only the ones actually written on disk are marked as existing.
        let filesByPath = Dictionary(uniqueKeysWithValues: claude.files.map { ($0.path, $0) })
        #expect(filesByPath[project.appendingPathComponent(".claude/settings.json").path]?.exists == true)
        #expect(filesByPath[project.appendingPathComponent(".mcp.json").path]?.exists == true)
        #expect(filesByPath[project.appendingPathComponent("CLAUDE.md").path]?.exists == false)
        #expect(store.agents.contains { $0.id == codexID })
        #expect(!store.agents.contains { $0.id.hasPrefix("antigravity::") })
        #expect(!store.agents.contains { $0.id.hasPrefix("opencode::") })

        // Doesn't leak into the global "Detected agents" grouping.
        #expect(store.agents.first { $0.id == "claude-code" }?.projectRoot == nil)
    }

    @Test func emptyProjectStaysRegisteredWithNoAgentGroups() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let project = try env.makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: project) }

        let store = env.makeStore()
        store.addProject(path: project.path)

        #expect(store.projectRoots.contains(project.path))
        #expect(!store.agents.contains { $0.projectRoot == project.path })
    }

    @Test func addingTheSameRootTwiceIsIgnored() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let project = try env.makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: project) }

        let store = env.makeStore()
        store.addProject(path: project.path)
        store.addProject(path: project.path)
        #expect(store.projectRoots.filter { $0 == project.path }.count == 1)
    }

    @Test func removingAProjectStopsTrackingButKeepsHistory() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let project = try env.makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, ".claude/settings.json", "{\"theme\":\"dark\"}")

        let store = env.makeStore()
        store.addProject(path: project.path)
        let path = project.appendingPathComponent(".claude/settings.json").path
        #expect(store.agents.first { $0.projectRoot == project.path }?.files.map(\.path).contains(path) == true)
        store.updateEdit(path: path, text: "{\"theme\":\"light\"}")
        store.save(path: path)
        #expect(!store.history(for: path).isEmpty)

        store.removeProject(path: project.path)
        #expect(!store.projectRoots.contains(project.path))
        #expect(!store.agents.contains { $0.projectRoot == project.path })

        // History on disk survives unregistering and resumes on re-add.
        store.addProject(path: project.path)
        #expect(!store.history(for: path).isEmpty)
    }

    @Test func projectMcpServerIsIndexedButNotACopyDestination() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let project = try env.makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, ".mcp.json", #"{"mcpServers":{"docs":{"command":"npx","args":["-y","@fake/docs"]}}}"#)

        let store = env.makeStore()
        store.addProject(path: project.path)
        let mcpPath = project.appendingPathComponent(".mcp.json").path

        let entry = try #require(store.mcpIndex.first { $0.name == "docs" && $0.sourcePath == mcpPath })
        #expect(entry.agentID == "claude-code::\(project.path)")
        #expect(!store.isMcpDestination(mcpPath))
        #expect(store.mcpTargetFiles(for: entry.agentID).isEmpty)
    }

    @Test func submoduleWithLocalConfigAppearsNestedUnderItsProject() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let project = try env.makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, ".gitmodules", """
        [submodule "backend-olon"]
        \tpath = backend-olon
        \turl = git@example.test:olon/backend-olon.git
        [submodule "no-config-here"]
        \tpath = no-config-here
        \turl = git@example.test:olon/no-config-here.git
        """)
        try env.write(root: project, "backend-olon/.codex/config.toml", "model = \"fixture\"\n")
        try env.write(root: project, "backend-olon/AGENTS.md", "# backend rules\n")
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("no-config-here"), withIntermediateDirectories: true)

        let store = env.makeStore()
        store.addProject(path: project.path)

        let submoduleRoot = project.appendingPathComponent("backend-olon").path
        let codexID = "codex::\(submoduleRoot)"
        let codex = try #require(store.agents.first { $0.id == codexID })
        #expect(codex.projectRoot == project.path)
        #expect(codex.submodulePath == "backend-olon")
        #expect(codex.detectionPath == submoduleRoot)
        #expect(codex.files.map(\.path).contains(project.appendingPathComponent("backend-olon/.codex/config.toml").path))

        // An uninitialized/empty submodule (declared, but no known files) contributes nothing.
        #expect(!store.agents.contains { ($0.submodulePath ?? "").hasPrefix("no-config-here") })

        // Doesn't get confused with the project's own top-level agents.
        #expect(!store.agents.contains { $0.id == "codex::\(project.path)" })
    }

    @Test func nestedSubmodulesAreDetectedUpToTheDepthBound() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let project = try env.makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, ".gitmodules", "[submodule \"outer\"]\n\tpath = outer\n\turl = git@example.test:x/outer.git\n")
        try env.write(root: project, "outer/.gitmodules", "[submodule \"inner\"]\n\tpath = inner\n\turl = git@example.test:x/inner.git\n")
        try env.write(root: project, "outer/inner/AGENTS.md", "# inner rules\n")

        let store = env.makeStore()
        store.addProject(path: project.path)

        let innerRoot = project.appendingPathComponent("outer/inner").path
        let opencode = try #require(store.agents.first { $0.id == "opencode::\(innerRoot)" })
        #expect(opencode.submodulePath == "outer/inner")
    }
}
}
