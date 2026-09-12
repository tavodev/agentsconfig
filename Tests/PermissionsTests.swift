import Testing
import Foundation

/// F1: private permissions, safe temp files, symlink policy, legacy audit.
extension AgentsConfigTestSuite {
@Suite("Private permissions & atomic writes", .serialized)
@MainActor
struct PermissionTests {

    @Test(arguments: [false, true])
    func danglingSymlinkIsRejected(absolute: Bool) throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let path = env.path(".claude/mcp.json")
        let destination = absolute ? env.path(".claude/missing.json") : "missing.json"
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destination)
        #expect(throws: (any Error).self) {
            try AtomicWriter.writePreservingPermissions("{}", toPath: path)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path) == destination)
        #expect(!FileManager.default.fileExists(atPath: env.path(".claude/missing.json")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: env.path(".claude"))
            .allSatisfy { !$0.contains("acfg-tmp") })
    }

    @Test func validChainAndLinkedParentPreserveLinksAndPermissions() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let fm = FileManager.default
        try env.write("real/config.json", "old", permissions: 0o640)
        try fm.createSymbolicLink(atPath: env.path("alias"), withDestinationPath: "real")
        try fm.createSymbolicLink(atPath: env.path("real/first"), withDestinationPath: "second")
        try fm.createSymbolicLink(atPath: env.path("real/second"), withDestinationPath: "config.json")
        try AtomicWriter.writePreservingPermissions("new", toPath: env.path("alias/first"))
        #expect(try env.read("real/config.json") == "new")
        #expect(env.posixPermissions("real/config.json") == 0o640)
        #expect(try fm.destinationOfSymbolicLink(atPath: env.path("real/first")) == "second")
        #expect(try fm.destinationOfSymbolicLink(atPath: env.path("real/second")) == "config.json")
        try AtomicWriter.write("created", to: URL(fileURLWithPath: env.path("alias/new.json")))
        #expect(try env.read("real/new.json") == "created")
        #expect(env.posixPermissions("real/new.json") == 0o600)
    }

    @Test func cyclesAndDanglingParentsAreRejected() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: env.path("a"), withDestinationPath: "b")
        try fm.createSymbolicLink(atPath: env.path("b"), withDestinationPath: "a")
        try fm.createSymbolicLink(atPath: env.path("parent"), withDestinationPath: "missing")
        for relativePath in ["a", "parent/config.json"] {
            #expect(throws: (any Error).self) {
                try AtomicWriter.write("new", to: URL(fileURLWithPath: env.path(relativePath)))
            }
        }
        #expect(try fm.destinationOfSymbolicLink(atPath: env.path("a")) == "b")
        #expect(try fm.destinationOfSymbolicLink(atPath: env.path("b")) == "a")
        #expect(try fm.destinationOfSymbolicLink(atPath: env.path("parent")) == "missing")
        #expect(try fm.contentsOfDirectory(atPath: env.home.path).count == 3)
    }

    @Test func deletedSymlinkTargetKeepsDraftAndSurfacesError() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let fm = FileManager.default
        let target = try env.write(".claude/real.json", "{}")
        let path = env.path(".claude/mcp.json")
        try fm.createSymbolicLink(atPath: path, withDestinationPath: "real.json")
        let store = env.makeStore()
        store.updateEdit(path: path, text: "{\"draft\":true}")
        try fm.removeItem(at: target)
        store.save(path: path)
        #expect(store.conflicts.contains(path))
        store.resolveConflictKeepMine(path: path)
        #expect(store.saveErrors[path] != nil)
        #expect(store.dirtyPaths.contains(path))
        #expect(store.text(for: path) == "{\"draft\":true}")
        #expect(try fm.destinationOfSymbolicLink(atPath: path) == "real.json")
        #expect(!fm.fileExists(atPath: target.path))
    }

    /// Repro of audit failure #1: with a permissive umask, snapshot content,
    /// index and their directories must still be private (0600 / 0700).
    @Test func snapshotFilesAndDirsArePrivateEvenWithPermissiveUmask() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }

        let old = umask(0o000)
        defer { umask(old) }

        let snapshots = env.makeSnapshots()
        _ = try snapshots.record(path: env.path("demo/config.json"),
                                 content: "{}", origin: .baseline, changes: [])

        let fm = FileManager.default
        let enumerator = fm.enumerator(
            at: env.historyRoot, includingPropertiesForKeys: [.isDirectoryKey])!
        var sawFile = false, sawDir = false
        for case let url as URL in enumerator {
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
            let perms = try #require((attrs[.posixPermissions] as? NSNumber)?.intValue)
            if isDir {
                sawDir = true
                #expect(perms == 0o700, "\(url.lastPathComponent) is \(String(perms, radix: 8))")
            } else {
                sawFile = true
                #expect(perms == 0o600, "\(url.lastPathComponent) is \(String(perms, radix: 8))")
            }
        }
        #expect(sawFile && sawDir)
        #expect(env.posixPermissions(
            "Library/Application Support/AgentsConfig/History") == 0o700)
    }

    /// Saving over an existing file preserves its POSIX permissions.
    @Test func savePreservesExistingPermissions() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()

        let store = env.makeStore()
        let settings = env.path(".claude/settings.json")
        #expect(env.posixPermissions(".claude/settings.json") == 0o600)

        store.updateEdit(path: settings, text: "{\"theme\":\"light\"}\n")
        store.save(path: settings)
        #expect(store.saveErrors[settings] == nil)
        #expect(env.posixPermissions(".claude/settings.json") == 0o600)
    }

    /// A file with non-private permissions keeps them after save.
    @Test func savePreservesNonPrivatePermissions() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        try env.write(".claude/mcp.json", "{}", permissions: 0o644)

        let store = env.makeStore()
        let p = env.path(".claude/mcp.json")
        store.updateEdit(path: p, text: "{\"a\":1}\n")
        store.save(path: p)
        #expect(store.saveErrors[p] == nil)
        #expect(env.posixPermissions(".claude/mcp.json") == 0o644)
    }

    /// A file created by the app does not inherit public permissions.
    @Test func newFileDefaultsToPrivate() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()   // ~/.claude/mcp.json is absent in the fixture

        let store = env.makeStore()
        let p = env.path(".claude/mcp.json")
        store.updateEdit(path: p, text: "{}\n")
        store.save(path: p)

        #expect(store.saveErrors[p] == nil)
        #expect(env.posixPermissions(".claude/mcp.json") == 0o600)
    }

    /// When the final replace fails, the temp file must not leak and the
    /// original must be untouched. A non-empty directory at the destination
    /// makes the replace fail deterministically.
    @Test func failedReplaceCleansTempAndKeepsOriginal() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        // ~/.claude/mcp.json exists as a non-empty directory → rename fails.
        try env.write(".claude/mcp.json/inner.txt", "occupied\n")

        let store = env.makeStore()
        let p = env.path(".claude/mcp.json")
        store.updateEdit(path: p, text: "{}\n")
        store.save(path: p)

        #expect(store.saveErrors[p] != nil)
        #expect(store.dirtyPaths.contains(p))   // buffer kept for retry
        // no *.acfg-tmp-* leftovers anywhere under .claude
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: env.path(".claude"))
        #expect(!entries.contains { $0.contains("acfg-tmp") })
        // the original is still the directory with its contents
        #expect(try env.read(".claude/mcp.json/inner.txt") == "occupied\n")
    }

    /// Symlink policy: writes go through to the target — the link itself must
    /// never be replaced by a plain file.
    @Test func symlinkedConfigWritesThroughToTarget() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let real = try env.write(".claude/real-mcp.json", "{\"a\":1}\n",
                                 permissions: 0o600)
        try FileManager.default.createSymbolicLink(
            atPath: env.path(".claude/mcp.json"),
            withDestinationPath: real.path)

        let store = env.makeStore()
        let p = env.path(".claude/mcp.json")
        store.updateEdit(path: p, text: "{\"a\":2}\n")
        store.save(path: p)

        #expect(store.saveErrors[p] == nil)
        // link still a link, target updated, permissions preserved
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: p)
        #expect(dest == real.path)
        #expect(try String(contentsOf: real, encoding: .utf8) == "{\"a\":2}\n")
        #expect(env.posixPermissions(".claude/real-mcp.json") == 0o600)
    }

    /// Legacy audit: history trees created before the fix (0755/0644) get
    /// tightened in place, without deleting any content.
    @Test func auditTightensLegacyHistoryPermissions() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }

        // simulate a pre-fix history tree
        let dir = env.historyRoot.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: dir.path)
        for name in ["index.json", "1700000000-deadbeef.txt"] {
            let u = dir.appendingPathComponent(name)
            try "x".write(to: u, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: u.path)
        }

        let failed = env.makeSnapshots().secureExistingPermissions()
        #expect(failed.isEmpty)
        for name in ["index.json", "1700000000-deadbeef.txt"] {
            let u = dir.appendingPathComponent(name)
            let perms = try #require((try FileManager.default.attributesOfItem(
                atPath: u.path)[.posixPermissions] as? NSNumber)?.intValue)
            #expect(perms == 0o600)
            #expect(try String(contentsOf: u, encoding: .utf8) == "x")
        }
        let dirPerms = try #require((try FileManager.default.attributesOfItem(
            atPath: dir.path)[.posixPermissions] as? NSNumber)?.intValue)
        #expect(dirPerms == 0o700)
    }

    /// Sources flagged `excludeFromHistory` (may hold secrets) never get
    /// on-disk snapshots, while sibling files keep their history.
    @Test func historyOptOutRecordsNothing() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installGemini()

        let store = env.makeStore()
        let flagged = env.path(".gemini/config/config.json")
        _ = store.document(for: flagged)
        #expect(store.history(for: flagged).isEmpty)
        #expect(!store.history(for: env.path(".gemini/settings.json")).isEmpty)
    }
}

}
