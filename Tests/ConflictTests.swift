import Testing
import Foundation

/// F2: save/restore must verify the real disk state before overwriting,
/// back up what was actually found, and only log success after the write.
extension AgentsConfigTestSuite {
@Suite("Save conflict control", .serialized)
@MainActor
struct ConflictTests {

    @Test(arguments: [false, true])
    func useDiskReadsCurrentContentBeforeWatcher(changesAgain: Bool) throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let path = env.path(".claude/settings.json")
        store.updateEdit(path: path, text: "{\"draft\":true}")
        let b = "{\"mcpServers\":{\"b\":{\"command\":\"fake-b\"}}}"
        let c = "{\"mcpServers\":{\"c\":{\"command\":\"fake-c\"}}}"
        try env.write(".claude/settings.json", b)
        store.save(path: path)
        if changesAgain { try env.write(".claude/settings.json", c) }
        store.resolveConflictUseDisk(path: path)
        #expect(store.text(for: path) == (changesAgain ? c : b))
        #expect(store.document(for: path)?.text == (changesAgain ? c : b))
        #expect(!store.dirtyPaths.contains(path))
        #expect(!store.conflicts.contains(path))
        #expect(store.externalChanges[path] == nil)
        #expect(store.mcpNames.contains(changesAgain ? "c" : "b"))
        store.updateEdit(path: path, text: "{}")
        store.save(path: path)
        #expect(store.saveErrors[path] == nil)
        #expect(!store.conflicts.contains(path))
    }

    @Test func useDiskReadFailureKeepsBufferAndConflict() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let path = env.path(".claude/settings.json")
        store.updateEdit(path: path, text: "{\"draft\":true}")
        try env.write(".claude/settings.json", "{}")
        store.save(path: path)
        try Data([0xff, 0xfe]).write(to: URL(fileURLWithPath: path))
        store.resolveConflictUseDisk(path: path)
        #expect(store.text(for: path) == "{\"draft\":true}")
        #expect(store.dirtyPaths.contains(path))
        #expect(store.conflicts.contains(path))
        #expect(store.saveErrors[path] != nil)
    }

    @Test func acceptingDeletedDiskClearsDocumentAndMcpMetadata() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let path = env.path(".claude.json")
        store.updateEdit(path: path, text: "{\"draft\":true}")
        try FileManager.default.removeItem(atPath: path)
        store.save(path: path)
        store.resolveConflictUseDisk(path: path)
        #expect(store.document(for: path) == nil)
        #expect(store.text(for: path).isEmpty)
        #expect(!store.mcpNames.contains("docs"))
        #expect(!store.dirtyPaths.contains(path))
        #expect(!store.conflicts.contains(path))
        #expect(store.agents.flatMap(\.files).first { $0.path == path }?.exists == false)
    }

    private func historyDirName(for path: String) -> String {
        SnapshotStore.historyDirName(for: path)
    }

    /// Repro: an external write that lands before the watcher debounce must be
    /// detected at save time — the disk content can not be silently clobbered.
    @Test func saveDetectsExternalChangeBeforeDebounce() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let rel = ".claude/settings.json"
        let p = env.path(rel)

        store.updateEdit(path: p, text: "{\"theme\":\"mine\"}\n")
        try env.write(rel, "{\"theme\":\"external-B\"}\n")   // pre-debounce write

        store.save(path: p)
        #expect(store.conflicts.contains(p) || store.saveErrors[p] != nil)
        #expect(try env.read(rel) == "{\"theme\":\"external-B\"}\n")
        #expect(store.dirtyPaths.contains(p))   // buffer kept for resolution
    }

    /// "Keep mine" is an explicit overwrite: it backs up the real disk
    /// content first, so the external version stays recoverable.
    @Test func overwriteResolutionBacksUpDiskContent() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let rel = ".claude/settings.json"
        let p = env.path(rel)
        let b = "{\"theme\":\"external-B\"}\n"
        let mine = "{\"theme\":\"mine\"}\n"

        store.updateEdit(path: p, text: mine)
        try env.write(rel, b)
        store.save(path: p)
        #expect(store.conflicts.contains(p) || store.saveErrors[p] != nil)

        store.resolveConflictKeepMine(path: p)
        #expect(try env.read(rel) == mine)
        // B recoverable in history
        let found = store.history(for: p).contains {
            store.versionContent(path: p, version: $0) == b
        }
        #expect(found)
        #expect(!store.dirtyPaths.contains(p))
    }

    /// After resolving one conflict, a *new* external change re-arms the
    /// control — a previous confirmation never authorizes newer overwrites.
    @Test func newExternalChangeAfterResolutionDetectedAgain() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let rel = ".claude/settings.json"
        let p = env.path(rel)

        store.updateEdit(path: p, text: "{\"v\":1}\n")
        try env.write(rel, "{\"v\":2}\n")
        store.save(path: p)
        store.resolveConflictKeepMine(path: p)
        #expect(try env.read(rel) == "{\"v\":1}\n")

        // external change #2 after resolution, again pre-debounce
        store.updateEdit(path: p, text: "{\"v\":3}\n")
        try env.write(rel, "{\"v\":4}\n")
        store.save(path: p)
        #expect(try env.read(rel) == "{\"v\":4}\n")
        #expect(store.dirtyPaths.contains(p))
    }

    /// An externally deleted file is a conflict, not an authorization to
    /// silently recreate it on top of the user's buffer.
    @Test func externalDeletionIsConflictNotRecreate() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let rel = ".claude/settings.json"
        let p = env.path(rel)

        store.updateEdit(path: p, text: "{\"theme\":\"mine\"}\n")
        try FileManager.default.removeItem(atPath: p)

        store.save(path: p)
        #expect(!FileManager.default.fileExists(atPath: p))   // not recreated
        #expect(store.dirtyPaths.contains(p))
        #expect(store.conflicts.contains(p) || store.saveErrors[p] != nil)
    }

    /// Restore/revert on a read-only file is rejected without touching disk.
    @Test func restoreReadOnlyRejectedWithoutTouchingDisk() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installCodex()
        let store = env.makeStore()
        let rel = ".codex/auth.json"
        let p = env.path(rel)
        let before = try env.read(rel)

        store.restoreVersion(
            path: p,
            version: FileVersion(date: Date(), hash: "x", file: "none.txt",
                                 origin: .external, changeCount: 0, summary: ""))
        #expect(store.saveErrors[p] != nil)
        #expect(try env.read(rel) == before)
    }

    /// If the required backup fails, the write must not happen: error shown,
    /// buffer kept dirty, and no fake success activity is logged.
    @Test func failedBackupAbortsSaveAndKeepsDirty() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let rel = ".claude/settings.json"
        let p = env.path(rel)
        let before = try env.read(rel)

        // poison the history dir *before* the store exists: a file occupies
        // the per-file history directory's future location
        try FileManager.default.createDirectory(
            at: env.historyRoot, withIntermediateDirectories: true)
        try "blocker".write(
            to: env.historyRoot.appendingPathComponent(historyDirName(for: p)),
            atomically: true, encoding: .utf8)

        let store = env.makeStore()

        store.updateEdit(path: p, text: "{\"theme\":\"mine\"}\n")
        store.save(path: p)

        #expect(store.saveErrors[p] != nil)
        #expect(store.dirtyPaths.contains(p))
        #expect(try env.read(rel) == before)
        #expect(!store.activity.contains { $0.path == p && $0.origin == .app })
    }

    /// Restoring with an unsaved buffer must not silently drop it: the
    /// operation is rejected, buffer/disk/history all unchanged.
    @Test func restoreWithDirtyBufferIsRejected() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let rel = ".claude/settings.json"
        let p = env.path(rel)
        let before = try env.read(rel)
        let histBefore = store.history(for: p).count

        store.updateEdit(path: p, text: "{\"theme\":\"mine\"}\n")
        let v = try #require(store.history(for: p).first)
        store.restoreVersion(path: p, version: v)

        #expect(store.saveErrors[p] != nil || store.conflicts.contains(p))
        #expect(store.dirtyPaths.contains(p))
        #expect(try env.read(rel) == before)
        #expect(store.history(for: p).count == histBefore)
    }

    /// Clean restore: disk becomes the version content and the pre-restore
    /// disk state is backed up first.
    @Test func cleanRestoreWritesAndBacksUpPrevious() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let rel = ".claude/settings.json"
        let p = env.path(rel)

        // make a second version on disk via a save
        store.updateEdit(path: p, text: "{\"theme\":\"v2\"}\n")
        store.save(path: p)
        #expect(try env.read(rel) == "{\"theme\":\"v2\"}\n")

        let baseline = try #require(
            store.history(for: p).first { $0.origin == .baseline })
        store.restoreVersion(path: p, version: baseline)
        #expect(store.saveErrors[p] == nil)
        #expect(try env.read(rel) == baselineContent(in: store, path: p,
                                                     version: baseline))
    }

    private func baselineContent(in store: ConfigStore, path: String,
                                 version: FileVersion) -> String {
        store.versionContent(path: path, version: version) ?? "<missing>"
    }
}

}
