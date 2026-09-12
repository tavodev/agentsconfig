import Testing
import Foundation

/// Local (per-repository) config inspection: registering a project root
/// surfaces the same per-agent grouping, watching, history and MCP indexing
/// as global agents, without becoming a valid MCP copy destination.
extension AgentsConfigTestSuite {
@Suite("Project-local config", .serialized)
@MainActor
struct ProjectLocalTests {

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
