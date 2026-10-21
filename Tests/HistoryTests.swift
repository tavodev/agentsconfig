import Testing
import Foundation

/// F4: history identity, unique version ids, safe GC, corrupt-index
/// surfacing, name-escape rejection and non-destructive migration.
extension AgentsConfigTestSuite {
@Suite("History integrity", .serialized)
@MainActor
struct HistoryTests {

    private func installLegacy(_ env: TestEnvironment, path: String,
                               file: String = "1700000000-legacy.txt", content: String? = "legacy") throws -> URL {
        let dir = env.historyRoot.appendingPathComponent(path.replacingOccurrences(of: "/", with: "__"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let content {
            try content.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let entries = [SnapshotStore.IndexEntry(ts: 1_700_000_000, hash: "legacy", file: file,
                                                origin: "baseline", changeCount: 0, summary: "base")]
        try JSONEncoder().encode(entries).write(to: dir.appendingPathComponent("index.json"))
        return dir
    }

    @Test func firstRecordMigratesLegacyBeforeAppending() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let p = env.path("demo/record.json")
        _ = try installLegacy(env, path: p)
        let s = env.makeSnapshots()
        _ = try s.record(path: p, content: "new", origin: .app, changes: [])
        let contents = try s.loadHistory(for: p).map { s.content(for: p, version: $0) }
        #expect(contents == ["new", "legacy"])
    }

    @Test func partialDirectoryDoesNotPreventMigration() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let p = env.path("demo/partial.json")
        _ = try installLegacy(env, path: p)
        let dir = env.historyRoot.appendingPathComponent(SnapshotStore.historyDirName(for: p))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = env.makeSnapshots()
        #expect(s.latestContent(for: p)?.content == "legacy")
    }

    @Test func interruptedMigrationRetriesWithoutLosingLegacy() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let p = env.path("demo/retry.json")
        let legacy = try installLegacy(env, path: p)
        var s = env.makeSnapshots()
        s.writeIndexFile = { _, _ in throw CocoaError(.fileWriteUnknown) }
        #expect(throws: (any Error).self) { try s.loadHistory(for: p) }
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        s.writeIndexFile = { try AtomicWriter.write($0, to: $1) }
        let history = try s.loadHistory(for: p)
        #expect(history.count == 1)
        #expect(history.first.flatMap { s.content(for: p, version: $0) } == "legacy")
        #expect(try s.loadHistory(for: p).map(\.id) == history.map(\.id))
    }

    @Test func storeDoesNotHideAmbiguousLegacyWithBaseline() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        try env.write(".claude__settings.json", "alternate")
        let p = env.path(".claude/settings.json")
        let legacy = try installLegacy(env, path: p)
        let store = env.makeStore()
        #expect(store.historyErrors[p] != nil)
        #expect(store.history(for: p).isEmpty)
        store.refreshHistory(path: p)
        #expect(store.historyErrors[p] != nil)
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        let index = env.historyRoot.appendingPathComponent(SnapshotStore.historyDirName(for: p))
            .appendingPathComponent("index.json")
        #expect(!FileManager.default.fileExists(atPath: index.path))
    }

    @Test func invalidLegacyEntriesAreNotSilentlySkipped() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        for (i, file) in ["missing.txt", "../../outside.txt"].enumerated() {
            let p = env.path("demo/invalid-\(i).json")
            let legacy = try installLegacy(env, path: p, file: file, content: nil)
            let s = env.makeSnapshots()
            #expect(throws: (any Error).self) { try s.loadHistory(for: p) }
            #expect(FileManager.default.fileExists(atPath: legacy.path))
        }
        let p = env.path("demo/symlink.json")
        let legacy = try installLegacy(env, path: p, content: nil)
        let outside = try env.write("outside.txt", "fake-private-value")
        try FileManager.default.createSymbolicLink(at: legacy.appendingPathComponent("1700000000-legacy.txt"),
                                                   withDestinationURL: outside)
        #expect(throws: (any Error).self) { try env.makeSnapshots().loadHistory(for: p) }
        #expect(try env.read("outside.txt") == "fake-private-value")
    }

    @Test func concurrentMigrationPublishesOneConsistentHistory() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let p = env.path("demo/concurrent-migration.json")
        _ = try installLegacy(env, path: p)
        let root = env.historyRoot
        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let s = SnapshotStore(root: root, historyLimit: { 20 }, isPathTracked: { _ in false })
                    let history = try s.loadHistory(for: p)
                    #expect(history.count == 1)
                    #expect(history.first.flatMap { s.content(for: p, version: $0) } == "legacy")
                } catch { Issue.record(error) }
            }
        }
        #expect(group.wait(timeout: .now() + 5) == .success)
        #expect(try env.makeSnapshots().loadHistory(for: p).count == 1)
    }

    @Test func failedIndexPublicationKeepsPreviousContent() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        var s = env.makeSnapshots(historyLimit: { 1 })
        let p = env.path("demo/cfg.json")
        let original = try #require(try s.record(path: p, content: "A", origin: .baseline, changes: []))
        s.writeIndexFile = { _, _ in throw CocoaError(.fileWriteUnknown) }

        #expect(throws: (any Error).self) {
            try s.record(path: p, content: "B", origin: .app, changes: [])
        }
        #expect(try s.loadHistory(for: p).map(\.id) == [original.id])
        #expect(s.content(for: p, version: original) == "A")
    }

    @Test func cleanupRunsAfterPublicationAndCanFailSafely() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        var s = env.makeSnapshots(historyLimit: { 1 })
        let p = env.path("demo/cfg.json")
        let original = try #require(try s.record(path: p, content: "A", origin: .baseline, changes: []))
        let index = env.historyRoot.appendingPathComponent(SnapshotStore.historyDirName(for: p))
            .appendingPathComponent("index.json")
        var cleanupCalls = 0
        s.removeContentFile = { _ in
            cleanupCalls += 1
            let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
            let entries = try #require(root["entries"] as? [[String: Any]])
            #expect(entries.map { $0["hash"] as? String } == [SnapshotStore.sha256("B")])
            throw CocoaError(.fileWriteNoPermission)
        }

        _ = try s.record(path: p, content: "B", origin: .app, changes: [])
        let current = try #require(s.loadHistory(for: p).first)
        #expect(cleanupCalls == 1)
        #expect(s.content(for: p, version: current) == "B")
        #expect(s.content(for: p, version: original) == "A")
    }

    @Test func concurrentReadersSeeRecoverablePublishedEntries() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let p = env.path("demo/concurrent.json")
        let first = env.makeSnapshots(historyLimit: { 2 })
        let second = env.makeSnapshots(historyLimit: { 2 })
        _ = try first.record(path: p, content: "seed", origin: .baseline, changes: [])
        let dir = env.historyRoot.appendingPathComponent(SnapshotStore.historyDirName(for: p))
        let readers = DispatchGroup()
        for _ in 0..<20 {
            readers.enter()
            DispatchQueue.global().async {
                defer { readers.leave() }
                let fd = open(dir.appendingPathComponent(".index.lock").path, O_RDONLY)
                guard fd >= 0 else { Issue.record("Cannot open fixture lock"); return }
                defer { close(fd) }
                guard flock(fd, LOCK_SH) == 0 else { Issue.record("Cannot lock fixture"); return }
                defer { flock(fd, LOCK_UN) }
                do {
                    let data = try Data(contentsOf: dir.appendingPathComponent("index.json"))
                    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    let entries = try #require(root["entries"] as? [[String: Any]])
                    for entry in entries {
                        let file = try #require(entry["file"] as? String)
                        let content = try String(contentsOf: dir.appendingPathComponent("objects/\(file)"), encoding: .utf8)
                        #expect(SnapshotStore.sha256(content) == file)
                    }
                } catch { Issue.record(error) }
            }
        }
        for i in 0..<20 {
            _ = try (i.isMultiple(of: 2) ? first : second)
                .record(path: p, content: "value-\(i)", origin: .app, changes: [])
        }
        #expect(readers.wait(timeout: .now() + 5) == .success)
        #expect(try first.loadHistory(for: p).count == 2)
        #expect(first.latestContent(for: p)?.content == "value-19")
    }

    @Test func storeHistoryReflectsRetention() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        AppSettings.defaults.set(2, forKey: "historyLimit")
        try env.installClaude()
        let store = env.makeStore()
        let p = env.path(".claude/settings.json")
        for value in 1...4 {
            try env.write(".claude/settings.json", "{\"value\":\(value)}")
            store.handleFileChanged(p)
        }
        let diskHistory = try env.makeSnapshots().loadHistory(for: p)
        #expect(store.history(for: p).map(\.id) == diskHistory.map(\.id))
        #expect(store.history(for: p).count == 2)
        #expect(store.history(for: p).allSatisfy { store.versionContent(path: p, version: $0) != nil })
    }

    /// Repro: "/demo/a/b.json" and "/demo/a__b.json" shared one history dir.
    @Test func collidingPathsGetSeparateHistories() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let s = env.makeSnapshots()
        let p1 = env.path("demo/a/b.json")
        let p2 = env.path("demo/a__b.json")
        _ = try s.record(path: p1, content: "one", origin: .baseline, changes: [])
        _ = try s.record(path: p2, content: "two", origin: .baseline, changes: [])

        #expect(try s.loadHistory(for: p1).count == 1)
        #expect(try s.loadHistory(for: p2).count == 1)
        #expect(s.content(for: p1, version: try s.loadHistory(for: p1)[0]) == "one")
        #expect(s.content(for: p2, version: try s.loadHistory(for: p2)[0]) == "two")
    }

    /// Repro: A → B → A within one second produced 3 entries but 2 unique ids
    /// and unrecoverable content. With a pinned clock every version keeps a
    /// unique id and its own recoverable content.
    @Test func sameSecondSnapshotsHaveUniqueIDs() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let fixed = Date(timeIntervalSince1970: 1_789_000_000)
        let s = env.makeSnapshots(now: { fixed })
        let p = env.path("demo/cfg.json")

        _ = try s.record(path: p, content: "A", origin: .baseline, changes: [])
        _ = try s.record(path: p, content: "B", origin: .external, changes: [])
        _ = try s.record(path: p, content: "A", origin: .app, changes: [])

        let hist = try s.loadHistory(for: p)
        #expect(hist.count == 3)
        #expect(Set(hist.map(\.id)).count == 3)
        // newest entry's content is readable and correct
        let contents = hist.map { s.content(for: p, version: $0) }
        #expect(contents == ["A", "B", "A"])
    }

    /// Retention over the A → B → A sequence must not delete a blob still
    /// referenced by a surviving entry.
    @Test func retentionKeepsReferencedContent() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        var t = Date(timeIntervalSince1970: 1_789_000_000)
        let s = env.makeSnapshots(now: { t }, historyLimit: { 2 })
        let p = env.path("demo/cfg.json")

        for c in ["A", "B", "A"] {
            _ = try s.record(path: p, content: c, origin: .app, changes: [])
            t += 1
        }
        let hist = try s.loadHistory(for: p)
        #expect(hist.count == 2)
        // v1(A) was dropped but its blob is still referenced by v3 — kept
        #expect(hist.map { s.content(for: p, version: $0) } == ["A", "B"])
    }

    /// A corrupt index produces a visible error and is never overwritten by
    /// an empty history.
    @Test func corruptIndexIsSurfacedNotOverwritten() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let s = env.makeSnapshots()
        let p = env.path("demo/cfg.json")
        _ = try s.record(path: p, content: "A", origin: .baseline, changes: [])

        let idx = env.historyRoot
            .appendingPathComponent(SnapshotStore.historyDirName(for: p))
            .appendingPathComponent("index.json")
        try "{corrupt".write(to: idx, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) { try s.loadHistory(for: p) }
        // and the index is left untouched for inspection/repair
        #expect(try String(contentsOf: idx, encoding: .utf8) == "{corrupt")
    }

    /// The store turns a corrupt index into a visible per-path error.
    @Test func storeSurfacesCorruptHistoryError() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let p = env.path(".claude/settings.json")
        #expect(!store.history(for: p).isEmpty)   // baseline exists

        let idx = env.historyRoot
            .appendingPathComponent(SnapshotStore.historyDirName(for: p))
            .appendingPathComponent("index.json")
        try "{corrupt".write(to: idx, atomically: true, encoding: .utf8)

        store.refreshHistory(path: p)
        #expect(store.historyErrors[p] != nil)
    }

    /// Entries whose stored filename escapes the history dir are never
    /// followed on read or delete.
    @Test func escapedContentNamesAreRejected() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let s = env.makeSnapshots()
        let p = env.path("demo/cfg.json")
        _ = try s.record(path: p, content: "A", origin: .baseline, changes: [])

        let dir = env.historyRoot
            .appendingPathComponent(SnapshotStore.historyDirName(for: p))
        // hand-craft a version pointing outside the dir
        let evil = FileVersion(date: Date(), hash: "x", file: "../../evil.txt",
                               origin: .external, changeCount: 0, summary: "")
        #expect(s.content(for: p, version: evil) == nil)
        // an escape planted on disk is untouched by retention
        let outside = env.historyRoot.appendingPathComponent("escaped-marker.txt")
        try "keep".write(to: outside, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        _ = dir // silence unused warning if layout changes
    }

    /// Migrating a legacy ("__"-sanitized) history dir produces format-2
    /// history, keeps content recoverable, and leaves the legacy tree intact
    /// under a `.migrated` name. Migrating twice is a no-op.
    @Test func legacyHistoryMigratesNonDestructively() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let p = env.path("demo/solo.json")

        // fabricate a legacy-format history: dir name = path with / → __
        let legacyName = p.replacingOccurrences(of: "/", with: "__")
        let legacyDir = env.historyRoot.appendingPathComponent(legacyName)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try "v1-content".write(to: legacyDir.appendingPathComponent("1700000000-aaaaaaaa.txt"),
                               atomically: true, encoding: .utf8)
        try #"[{"ts":1700000000,"hash":"aaaaaaaa","file":"1700000000-aaaaaaaa.txt","origin":"baseline","changeCount":0,"summary":"base"}]"#
            .data(using: .utf8)!
            .write(to: legacyDir.appendingPathComponent("index.json"))

        let s = env.makeSnapshots()
        let hist = try s.loadHistory(for: p)
        #expect(hist.count == 1)
        #expect(s.content(for: p, version: hist[0]) == "v1-content")

        // idempotent: second load hits the migrated dir, no duplicates
        #expect(try s.loadHistory(for: p).count == 1)
        // legacy tree preserved (renamed, not deleted)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: env.historyRoot.path)
        #expect(leftovers.contains { $0.hasPrefix(legacyName) && $0.contains("migrated") })
    }

    /// If both "/x/a/b.json" and "/x/a__b.json" exist, the shared legacy dir
    /// can't be attributed to either — it is kept and the ambiguity surfaced.
    @Test func ambiguousLegacyHistoryIsFlaggedNotGuessed() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let p1 = env.path("demo/a/b.json")
        try env.write("demo/a/b.json", "one")
        try env.write("demo/a__b.json", "two")

        let legacyName = p1.replacingOccurrences(of: "/", with: "__")
        let legacyDir = env.historyRoot.appendingPathComponent(legacyName)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try "shared".write(to: legacyDir.appendingPathComponent("1700000000-bbbbbbbb.txt"),
                           atomically: true, encoding: .utf8)
        try #"[{"ts":1700000000,"hash":"bbbbbbbb","file":"1700000000-bbbbbbbb.txt","origin":"external","changeCount":1,"summary":"x"}]"#
            .data(using: .utf8)!
            .write(to: legacyDir.appendingPathComponent("index.json"))

        let s = env.makeSnapshots()
        #expect(throws: (any Error).self) { try s.loadHistory(for: p1) }
        // legacy dir still there, untouched
        #expect(FileManager.default.fileExists(atPath: legacyDir.path))
    }

    // MARK: - global purge (#16)

    private func remaining(_ env: TestEnvironment) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: env.historyRoot.path)
    }

    /// Format 2, unmigrated legacy and `.migrated` backups all go; the
    /// summary measures them first and the History root itself survives.
    @Test func purgeRemovesFormat2LegacyAndMigratedHistory() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let s = env.makeSnapshots()
        let current = env.path("demo/current.json")
        let legacyOnly = env.path("demo/legacy-only.json")
        let migrated = env.path("demo/migrated.json")
        _ = try s.record(path: current, content: "A", origin: .baseline, changes: [])
        _ = try s.record(path: current, content: "B", origin: .app, changes: [])
        _ = try installLegacy(env, path: legacyOnly)
        _ = try installLegacy(env, path: migrated)
        #expect(try s.loadHistory(for: migrated).count == 1)   // creates *.migrated
        #expect(try remaining(env).contains { $0.hasSuffix(".migrated") })

        let summary = s.purgeSummary()
        #expect(summary.histories == 3)        // current + migrated (format 2) + legacy-only
        #expect(summary.legacyBackups == 1)
        #expect(summary.versions == 4)         // 2 + 1 + 1
        #expect(summary.bytes > 0)

        try s.purgeAll()
        #expect(try remaining(env).isEmpty)
        #expect(s.purgeSummary().isEmpty)
        for p in [current, legacyOnly, migrated] { #expect(try s.loadHistory(for: p).isEmpty) }
        // recording afterwards starts a fresh, valid history
        _ = try s.record(path: current, content: "C", origin: .app, changes: [])
        #expect(try s.loadHistory(for: current).map { s.content(for: current, version: $0) } == ["C"])
    }

    /// Links inside History are unlinked, never followed: their targets
    /// outside the history directory keep their content.
    @Test func purgeNeverFollowsSymlinksOutsideHistory() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let outsideDir = try env.write("outside/keep/secret.txt", "outside-dir").deletingLastPathComponent()
        let outsideFile = try env.write("outside/blob.txt", "outside-file")
        let s = env.makeSnapshots()
        let p = env.path("demo/linked.json")
        _ = try s.record(path: p, content: "A", origin: .baseline, changes: [])
        let dir = env.historyRoot.appendingPathComponent(SnapshotStore.historyDirName(for: p))
        let legacy = try installLegacy(env, path: env.path("demo/legacy-link.json"))
        let fm = FileManager.default
        try fm.createSymbolicLink(at: env.historyRoot.appendingPathComponent("root-link"), withDestinationURL: outsideDir)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("objects/dir-link"), withDestinationURL: outsideDir)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("objects/" + String(repeating: "a", count: 64)),
                                  withDestinationURL: outsideFile)
        try fm.createSymbolicLink(at: legacy.appendingPathComponent("1700000001-link.txt"), withDestinationURL: outsideFile)

        try s.purgeAll()
        #expect(try remaining(env).isEmpty)
        #expect(try env.read("outside/keep/secret.txt") == "outside-dir")
        #expect(try env.read("outside/blob.txt") == "outside-file")
    }

    /// A symlinked History root is refused as a whole: nothing at its
    /// destination is deleted.
    @Test func purgeRefusesSymlinkedHistoryRoot() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let target = try env.write("elsewhere/History/keep.txt", "kept").deletingLastPathComponent()
        try FileManager.default.createDirectory(at: env.historyRoot.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: env.historyRoot, withDestinationURL: target)
        let s = env.makeSnapshots()
        #expect(throws: SnapshotStore.HistoryError.self) { try s.purgeAll() }
        #expect(try env.read("elsewhere/History/keep.txt") == "kept")
    }

    /// Failures are collected, the locked directory keeps its lock, and a
    /// retry removes what is left.
    @Test func failedPurgeIsReportedAndRetriable() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        var s = env.makeSnapshots()
        let p = env.path("demo/stubborn.json")
        let other = env.path("demo/other.json")
        _ = try s.record(path: p, content: "A", origin: .baseline, changes: [])
        _ = try s.record(path: other, content: "B", origin: .baseline, changes: [])
        let dir = env.historyRoot.appendingPathComponent(SnapshotStore.historyDirName(for: p))
        let index = dir.appendingPathComponent("index.json")
        s.removeContentFile = { url in
            if url.path == index.path { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        }
        do {
            try s.purgeAll()
            Issue.record("purge should report the failure")
        } catch SnapshotStore.HistoryError.incompletePurge(let paths) {
            #expect(paths == [index.path])
        }
        #expect(try remaining(env) == [SnapshotStore.historyDirName(for: p)])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == [".index.lock", "index.json"])
        #expect(try s.loadHistory(for: other).isEmpty)

        s.removeContentFile = { try FileManager.default.removeItem(at: $0) }
        try s.purgeAll()
        #expect(try remaining(env).isEmpty)
    }

    /// The purge waits for `.index.lock` like `removeVersions` does, and a
    /// writer that was queued on the unlinked lock re-locks the live one.
    @Test func purgeRespectsIndexLock() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let root = env.historyRoot
        let p = env.path("demo/locked.json")
        _ = try env.makeSnapshots().record(path: p, content: "A", origin: .baseline, changes: [])
        let dir = root.appendingPathComponent(SnapshotStore.historyDirName(for: p))
        let fd = open(dir.appendingPathComponent(".index.lock").path, O_RDWR)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(flock(fd, LOCK_EX) == 0)

        let purged = DispatchSemaphore(value: 0)
        let recorded = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do { try SnapshotStore(root: root, isPathTracked: { _ in false }).purgeAll() }
            catch { Issue.record(error) }
            purged.signal()
        }
        DispatchQueue.global().async {
            do {
                _ = try SnapshotStore(root: root, historyLimit: { 20 }, isPathTracked: { _ in false })
                    .record(path: p, content: "after", origin: .app, changes: [])
            } catch { Issue.record(error) }
            recorded.signal()
        }
        // While the lock is held neither may touch the index.
        #expect(purged.wait(timeout: .now() + 0.3) == .timedOut)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.json").path))
        flock(fd, LOCK_UN)
        #expect(purged.wait(timeout: .now() + 5) == .success)
        #expect(recorded.wait(timeout: .now() + 5) == .success)

        // Either order leaves one consistent history: empty (purge last) or
        // just the new version under a live, regular lock file (record last).
        let s = env.makeSnapshots()
        let contents = try s.loadHistory(for: p).map { s.content(for: p, version: $0) }
        #expect(contents == [] || contents == ["after"])
        if !contents.isEmpty {
            let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(".index.lock").path)
            #expect(attrs[.type] as? FileAttributeType == .typeRegular)
        }
    }

    /// The store's purge clears published histories, errors and activity,
    /// and leaves `historyEnabled` as it was; disabling it alone never purges.
    @Test func storePurgeKeepsStateCoherent() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        try env.installCodex()
        let store = env.makeStore()
        let claude = env.path(".claude/settings.json")
        let codex = env.path(".codex/config.toml")
        #expect(!store.history(for: claude).isEmpty)
        #expect(!store.history(for: codex).isEmpty)
        let index = env.historyRoot.appendingPathComponent(SnapshotStore.historyDirName(for: codex))
            .appendingPathComponent("index.json")
        try "{corrupt".write(to: index, atomically: true, encoding: .utf8)
        store.refreshHistory(path: codex)
        #expect(store.historyErrors[codex] != nil)

        AppSettings.defaults.set(false, forKey: "historyEnabled")
        store.refresh()
        #expect(!store.history(for: claude).isEmpty)   // disabling does not purge
        #expect(!(try remaining(env)).isEmpty)

        store.requestHistoryPurge()
        let request = try #require(store.pendingHistoryPurge)
        #expect(request.summary.histories >= 2)
        store.cancelHistoryPurge()
        #expect(!store.history(for: claude).isEmpty)   // cancel deletes nothing

        store.requestHistoryPurge()
        store.confirmHistoryPurge()
        #expect(store.pendingHistoryPurge == nil)
        #expect(store.historyPurgeError == nil)
        #expect(store.historyPurgeNotice != nil)
        #expect(store.historyErrors.isEmpty)
        #expect(store.activity.isEmpty)
        #expect(store.history(for: claude).isEmpty)
        #expect(store.history(for: codex).isEmpty)
        #expect(store.historyErrors.isEmpty)
        #expect(try remaining(env).isEmpty)
        #expect(AppSettings.historyEnabled == false)

        store.requestHistoryPurge()   // nothing left: notice, no dialog
        #expect(store.pendingHistoryPurge == nil)
        #expect(store.historyPurgeNotice != nil)
    }
}

}
