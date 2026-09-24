import Testing
import Foundation
import XCTest

/// Startup/scan performance work must not change what a scan finds: the
/// background path publishes the same state as `refresh()`, directory events
/// only rescan on structural changes, and history reads have no side effects.
extension AgentsConfigTestSuite {
@Suite("Scan performance", .serialized)
@MainActor
struct ScanPerformanceTests {

    private func snapshot(_ store: ConfigStore) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: store.agents.map { ($0.id, $0.files.map(\.path)) })
    }

    @Test func backgroundScanPublishesSameStateAsSynchronousRefresh() async throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let project = try env.makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, ".claude/settings.json", "{}")
        try env.write(root: project, "packages/app/AGENTS.md", "# nested")
        let sync = env.makeStore()
        sync.addProject(path: project.path)
        let expected = snapshot(sync)

        let background = ConfigStore(notifier: nil, backgroundScan: true)
        #expect(background.isScanning)
        await background.waitForRefresh()
        #expect(!background.isScanning)
        #expect(snapshot(background) == expected)
        #expect(Set(background.documents.keys) == Set(sync.documents.keys))
    }

    @Test func scheduledRefreshesCoalesceAndPickUpNewFiles() async throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let project = try env.makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: project) }
        let store = env.makeStore()
        store.addProject(path: project.path)
        #expect(!store.agents.contains { $0.projectRoot == project.path })
        try env.write(root: project, ".mcp.json", "{\"mcpServers\":{}}")
        for _ in 0..<5 { store.scheduleRefresh() }
        await store.waitForRefresh()
        #expect(store.agents.contains { $0.projectRoot == project.path })
    }

    @Test func projectEditsDoNotRescanButConfigMarkersDo() async throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let project = try env.makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, "src/main.swift", "print(1)")
        try env.write(root: project, ".claude/settings.json", "{}")
        let store = env.makeStore()
        store.addProject(path: project.path)
        let src = project.appendingPathComponent("src").path

        // An ordinary source file created or saved: no rescan.
        store.handleTreeEvents([.init(path: src + "/other.swift", isDirectory: false, structural: true, mustRescan: false)])
        #expect(!store.isScanning)
        // Content edits are never structural.
        store.handleTreeEvents([.init(path: src + "/main.swift", isDirectory: false, structural: false, mustRescan: false)])
        #expect(!store.isScanning)
        // Changes inside a skipped dependency tree, or the tree appearing: no rescan.
        store.handleTreeEvents([.init(path: project.path + "/node_modules/x", isDirectory: true, structural: true, mustRescan: false)])
        #expect(!store.isScanning)
        store.handleTreeEvents([.init(path: project.path + "/node_modules", isDirectory: true, structural: true, mustRescan: false)])
        #expect(!store.isScanning)

        // A new folder, a marker file, or a marker nested in `.claude`: rescan.
        for event in [TreeWatcher.Event(path: src + "/feature", isDirectory: true, structural: true, mustRescan: false),
                      .init(path: src + "/AGENTS.md", isDirectory: false, structural: true, mustRescan: false),
                      .init(path: src + "/.claude/settings.json", isDirectory: false, structural: true, mustRescan: false),
                      .init(path: project.path, isDirectory: true, structural: false, mustRescan: true)] {
            store.handleTreeEvents([event])
            #expect(store.isScanning, "\(event.path)")
            await store.waitForRefresh()
        }
    }

    @Test func treeWatcherDeliversStructuralEvents() async throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let root = try env.makeProjectRoot("tree")
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = XCTestExpectation(description: "created")
        let target = root.appendingPathComponent("created.json").path
        let watcher = TreeWatcher(latency: 0.05) { events in
            if events.contains(where: { $0.path == target && $0.structural }) { seen.fulfill() }
        }
        watcher.watch([root.path])
        await watcher.synchronize()
        try await Task.sleep(for: .milliseconds(200))
        try env.write(root: root, "created.json", "{}")
        #expect(await XCTWaiter.fulfillment(of: [seen], timeout: 5) == .completed)
        watcher.stop()
        await watcher.synchronize()
    }

    @Test func minimalRootsDropNestedPaths() {
        #expect(TreeWatcher.minimalRoots(["/a/b", "/a", "/a/b/c", "/ab", "/c"]) == ["/a", "/ab", "/c"])
        #expect(TreeWatcher.minimalRoots(["/a", "/a-b", "/a/b"]) == ["/a", "/a-b"])
    }

    @Test func readdirScanMatchesTypesAndSkipsLinks() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.write("tree/a.json", "{}")
        try env.write("tree/sub/b.md", "#")
        try env.write("tree/.git/config", "x")
        try FileManager.default.createSymbolicLink(atPath: env.path("tree/link"), withDestinationPath: env.path("tree/sub"))
        let result = DiscoveryTree.scan(root: env.path("tree"))
        #expect(result.files == [env.path("tree/a.json"), env.path("tree/sub/b.md")])
        #expect(result.directories == [env.path("tree"), env.path("tree/sub")])
        #expect(result.skippedLinks == 1)
        #expect(result.childNames[env.path("tree")] == [".git", "a.json", "link", "sub"])
    }

    @Test func scanCacheSharesTreesWithinOnePass() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.write("tree/a.json", "{}")
        let first = DiscoveryTree.withCache { () -> (Int, Int) in
            let before = DiscoveryTree.scan(root: env.path("tree")).files.count
            try? env.write("tree/b.json", "{}")
            return (before, DiscoveryTree.scan(root: env.path("tree")).files.count)
        }
        #expect(first.0 == first.1)                                     // memoized in the pass
        #expect(DiscoveryTree.scan(root: env.path("tree")).files.count == 2) // fresh outside it
    }

    @Test func historyReadWithoutHistoryCreatesNothing() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let snapshots = env.makeSnapshots()
        #expect(try snapshots.loadHistory(for: env.path("never/recorded.json")).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: env.historyRoot.path))
        _ = try snapshots.record(path: env.path("never/recorded.json"), content: "{}", origin: .baseline, changes: [])
        #expect(try snapshots.loadHistory(for: env.path("never/recorded.json")).count == 1)
    }

    @Test func globFastPathsMatchRegexSemantics() {
        #expect(DiscoveryTree.matches("a.json", "*"))
        #expect(DiscoveryTree.matches("a.json", "*.json"))
        #expect(!DiscoveryTree.matches("a.jsonc", "*.json"))
        #expect(DiscoveryTree.matches("SKILL.md", "SKILL.md"))
        #expect(!DiscoveryTree.matches("xSKILL.md", "SKILL.md"))
        #expect(DiscoveryTree.matches("rule-1.mdc", "rule-?.mdc"))
        #expect(DiscoveryTree.matches("a.b.toml", "*.b.*"))
        #expect(!DiscoveryTree.matches("A.JSON", "*.json"))
    }

        @Test func nativePathHelpersMatchNSString() {
        for (dir, name) in [("/a/b", "c"), ("/a/b/", "c"), ("/", "x")] {
            #expect(DiscoveryTree.join(dir, name) == (dir as NSString).appendingPathComponent(name))
        }
        #expect(DiscoveryTree.parent("/a/b/c") == "/a/b")
        #expect(DiscoveryTree.parent("/a") == "/")
        #expect(DiscoveryTree.parent("/") == nil)
    }

        /// Repro: `FileHandle.readToEnd()` returns nil for an empty blob, so
    /// recording an empty file failed verification as a corrupt index and
    /// the baseline was retried (and failed) on every launch.
    @Test func emptyFileBaselineIsRecorded() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let snapshots = env.makeSnapshots()
        let path = env.path("empty/AGENTS.md")
        _ = try snapshots.record(path: path, content: "", origin: .baseline, changes: [])
        let history = try snapshots.loadHistory(for: path)
        #expect(history.count == 1)
        #expect(snapshots.content(for: path, version: try #require(history.first)) == "")
    }

        @Test func sha256HexMatchesReferenceDigest() {
        #expect(SnapshotStore.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SnapshotStore.sha256("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
}
