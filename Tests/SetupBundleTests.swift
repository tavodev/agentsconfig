import Foundation
import Testing

extension AgentsConfigTestSuite {
@Suite("Setup export and import", .serialized) @MainActor
struct SetupBundleTests {
    private let fakeSecrets = ["sk-test-FAKE-0000", "sk-test-FAKE-1111", "FAKE-PROJECT-KEY-2222", "FAKE-MD-TOKEN-3333",
                               "FAKE-STATE-TOKEN-4444"]

    private func allText(in directory: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if let text = try? String(contentsOf: url, encoding: .utf8) { out[url.path] = text }
        }
        return out
    }

    private func fixture(_ env: TestEnvironment) throws -> URL {
        try env.installAllAgents()
        try env.write(".claude/CLAUDE.md", "# memory\ntoken: FAKE-MD-TOKEN-3333\n")
        try env.write(".claude.json", #"{"oauthAccount":{"accessToken":"FAKE-STATE-TOKEN-4444"},"mcpServers":{}}"#)
        let project = try env.makeProjectRoot("harbor")
        try env.write(root: project, ".mcp.json", #"{"mcpServers":{"docs":{"command":"npx","args":["-y","@fake/docs@1.0.0"],"env":{"API_KEY":"FAKE-PROJECT-KEY-2222"}}}}"#)
        try env.write(root: project, "AGENTS.md", "# project\n")
        return project
    }

    /// Issue #24: no fictitious secret reaches any exported file or the
    /// manifest; state and history-excluded files stay out by default.
    @Test func exportRedactsSecretsAndWritesManifest() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let project = try fixture(env); defer { try? FileManager.default.removeItem(at: project) }
        let store = env.makeStore(); store.addProject(path: project.path)
        let folder = env.home.appendingPathComponent("export-a")
        let manifest = try store.exportSetup(to: folder, options: .init())

        let texts = try allText(in: folder)
        for (path, text) in texts { for secret in fakeSecrets { #expect(!text.contains(secret), "\(secret) leaked into \(path)") } }
        #expect(manifest.files.contains { $0.scope == "global" && $0.path == ".claude/settings.json" && $0.redacted })
        #expect(manifest.files.contains { $0.scope == "project" && $0.project == project.lastPathComponent && $0.path == ".mcp.json" })
        #expect(!manifest.files.contains { $0.path == ".claude.json" || $0.path == ".codex/auth.json" })
        for file in manifest.files {
            let url = SetupBundle.bundlePath(folder, scope: file.scope, project: file.project, path: file.path)
            #expect(SnapshotStore.sha256(try String(contentsOf: url, encoding: .utf8)) == file.sha256)
            #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        #expect(try SetupBundle.readManifest(folder).files == manifest.files)
        #expect(throws: (any Error).self) { try store.exportSetup(to: folder, options: .init()) }

        let sensitive = try store.exportSetup(to: env.home.appendingPathComponent("export-b"),
                                              options: .init(includeProjects: false, includeSensitive: true))
        #expect(sensitive.files.contains { $0.path == ".claude.json" })
        #expect(!sensitive.files.contains { $0.scope == "project" })
        for (_, text) in try allText(in: env.home.appendingPathComponent("export-b")) {
            for secret in fakeSecrets { #expect(!text.contains(secret)) }
        }
    }

    /// Import previews each file and stages a review; masked values take the
    /// local value or are dropped, and a missing file is created only after
    /// confirmation.
    @Test func importRestoresLocalSecretsAndCreatesMissingFilesAfterReview() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let project = try fixture(env); defer { try? FileManager.default.removeItem(at: project) }
        let store = env.makeStore(); store.addProject(path: project.path)
        let folder = env.home.appendingPathComponent("export")
        try store.exportSetup(to: folder, options: .init())

        try env.write(".claude/settings.json", #"{"apiKey":"sk-test-FAKE-0000","theme":"light","model":"opus"}"#)
        store.handleWatchEvent(env.path(".claude/settings.json"))
        try FileManager.default.removeItem(atPath: env.path(".claude/CLAUDE.md"))
        store.refresh()

        let items = try store.setupImportItems(from: folder)
        let settings = try #require(items.first { $0.file.path == ".claude/settings.json" })
        #expect(settings.status == .differs && settings.target == env.path(".claude/settings.json"))
        #expect(items.first { $0.file.path == ".codex/config.toml" }?.status == .identical)
        #expect(items.first { $0.file.path == "AGENTS.md" && $0.file.scope == "project" }?.target == project.appendingPathComponent("AGENTS.md").path)

        #expect(store.stageSetupImport(settings, from: folder))
        let review = try #require(store.pendingMcpReview)
        #expect(review.proposedText.contains("sk-test-FAKE-0000") && review.proposedText.contains("\"dark\""))
        #expect(!review.proposedText.contains(Secrets.maskedValue))
        #expect(store.confirmMcpReview())
        #expect(store.text(for: env.path(".claude/settings.json")).contains("\"dark\""))
        #expect(try env.read(".claude/settings.json").contains("light"))

        let memory = try #require(try store.setupImportItems(from: folder).first { $0.file.path == ".claude/CLAUDE.md" })
        #expect(memory.status == .new)
        #expect(store.stageSetupImport(memory, from: folder))
        #expect(store.pendingMcpReview?.createsFile == true)
        #expect(store.pendingMcpReview?.warnings.contains { $0.contains("line 2") } == true)
        #expect(store.confirmMcpReview())
        #expect(try env.read(".claude/CLAUDE.md") == "# memory\n")
    }

    @Test func tamperedUnsafeAndRedactedEntriesAreHandled() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let project = try fixture(env); defer { try? FileManager.default.removeItem(at: project) }
        let store = env.makeStore(); store.addProject(path: project.path)
        let folder = env.home.appendingPathComponent("export")
        var manifest = try store.exportSetup(to: folder, options: .init())
        try "tampered".write(to: SetupBundle.bundlePath(folder, scope: "global", project: nil, path: ".codex/AGENTS.md"),
                             atomically: true, encoding: .utf8)
        manifest.files.append(.init(agent: "codex", scope: "global", project: nil, path: "../outside.md", format: "markdown",
                                    sha256: "", bytes: 0, redacted: false))
        let items = SetupBundle.importItems(manifest, directory: folder, projectRoots: store.projectRoots) { try? String(contentsOfFile: $0, encoding: .utf8) }
        #expect(items.first { $0.file.path == ".codex/AGENTS.md" }?.status == .tampered)
        #expect(items.first { $0.file.path == "../outside.md" }?.status == .unmapped)
        #expect(!store.stageSetupImport(items.first { $0.file.path == ".codex/AGENTS.md" }!, from: folder))

        let masked = #"{"env":{"API_KEY":"\#(Secrets.maskedValue)","MODE":"x"}}"#
        let restored = SetupBundle.restoringRedactions(masked, local: nil, format: .json)
        #expect(restored.dropped == ["env.API_KEY"] && !restored.text.contains(Secrets.maskedValue) && restored.text.contains("MODE"))
    }
}
}
