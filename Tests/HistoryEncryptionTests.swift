import Foundation
import Testing

private final class MemoryHistoryKeys: HistoryKeyProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var saved = 0
    var saveCount: Int { lock.withLock { saved } }
    func loadKey(id: String) throws -> Data? { lock.withLock { values[id] } }
    func storeKey(_ data: Data, id: String) throws {
        try lock.withLock {
            guard values[id] == nil else { throw HistoryEncryption.Failure.keychainUnavailable }
            values[id] = data; saved += 1
        }
    }
    func forgetKeys() { lock.withLock { values.removeAll() } }
}

extension AgentsConfigTestSuite {
@Suite("History encryption", .serialized) @MainActor
struct HistoryEncryptionTests {
    private func store(_ env: TestEnvironment, _ keys: MemoryHistoryKeys, limit: Int = 100) -> SnapshotStore {
        SnapshotStore(root: env.historyRoot, permissionBoundary: AppPaths.applicationSupport,
                      historyLimit: { limit }, keyProvider: keys, isPathTracked: { _ in false })
    }
    private func dataFiles(_ root: URL) throws -> [URL] {
        var output: [URL] = []
        func visit(_ dir: URL) throws {
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
                if name == ".index.lock" || dir == root && name == HistoryEncryption.markerName { continue }
                let url = dir.appendingPathComponent(name)
                switch HistoryEncryption.type(url) {
                case S_IFDIR: try visit(url)
                case S_IFREG: output.append(url)
                default: continue
                }
            }
        }
        try visit(root)
        return output
    }
    private func blob(_ env: TestEnvironment, path: String, version: FileVersion) -> URL {
        env.historyRoot.appendingPathComponent(SnapshotStore.historyDirName(for: path))
            .appendingPathComponent("objects/" + version.file)
    }
    @Test func absentHistoryReadsAndStatusCreateNothing() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let keys = MemoryHistoryKeys(), s = store(env, keys)
        #expect(try s.loadHistory(for: env.path("fake.json")).isEmpty)
        #expect(try s.encryptionStatus() == .init(enabled: false, needsResume: false, keyID: nil))
        #expect(s.purgeSummary().isEmpty)
        try s.purgeAll()
        #expect(!FileManager.default.fileExists(atPath: env.historyRoot.path))
        #expect(!FileManager.default.fileExists(atPath: env.historyRoot.deletingLastPathComponent().appendingPathComponent(".History.history.lock").path))
        #expect(keys.saveCount == 0)
    }
    @Test func optInEncryptsEntireTreeAndRoundTripsAfterReopening() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let keys = MemoryHistoryKeys(), s = store(env, keys)
        let path = env.path("fake/settings.json")
        let a = try #require(try s.record(path: path, content: "private-A", origin: .baseline, changes: []))
        _ = try s.record(path: path, content: "private-B", origin: .app, changes: [])
        let backup = env.historyRoot.appendingPathComponent("legacy.migrated/secret.txt")
        let stray = env.historyRoot.appendingPathComponent("stray.dat")
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 1, 255, 42]).write(to: stray)
        try Data("legacy-private".utf8).write(to: backup)
        let outside = try env.write("outside/secret.txt", "outside-private")
        try FileManager.default.createSymbolicLink(at: env.historyRoot.appendingPathComponent("outside-link"), withDestinationURL: outside)
        let before = try Dictionary(uniqueKeysWithValues: dataFiles(env.historyRoot).map { ($0.path, try Data(contentsOf: $0)) })
        try s.setEncryption(enabled: true)
        let status = try s.encryptionStatus()
        #expect(status.enabled && !status.needsResume && status.keyID != nil && keys.saveCount == 1)
        for file in try dataFiles(env.historyRoot) {
            let data = try Data(contentsOf: file)
            #expect(data.starts(with: HistoryEncryption.header))
            #expect(data.range(of: Data("private".utf8)) == nil)
            #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        let reopened = store(env, keys)
        #expect(try reopened.loadHistory(for: path).count == 2)
        #expect(reopened.content(for: path, version: a) == "private-A")
        #expect(try env.read("outside/secret.txt") == "outside-private")
        try reopened.setEncryption(enabled: false)
        #expect(!(try reopened.encryptionStatus()).enabled)
        for (path, data) in before { #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == data) }
        #expect(keys.saveCount == 1)
        try reopened.setEncryption(enabled: true)
        #expect(keys.saveCount == 1)
    }
    @Test func encryptedRetentionDedupeRemovalAndPurgeRemainUsable() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let keys = MemoryHistoryKeys(), s = store(env, keys, limit: 2)
        let path = env.path("fake/retention.json")
        try s.setEncryption(enabled: true)
        _ = try s.record(path: path, content: "A", origin: .baseline, changes: [])
        #expect(try s.record(path: path, content: "A", origin: .app, changes: []) == nil)
        _ = try s.record(path: path, content: "B", origin: .app, changes: [])
        _ = try s.record(path: path, content: "C", origin: .app, changes: [])
        var versions = try s.loadHistory(for: path)
        #expect(versions.map { s.content(for: path, version: $0) } == ["C", "B"])
        let remove = try #require(versions.last)
        try s.removeVersions(for: path, ids: [remove.id], expectedIDs: Set(versions.map(\.id)))
        versions = try s.loadHistory(for: path)
        #expect(versions.count == 1 && s.content(for: path, version: versions[0]) == "C")
        #expect(s.purgeSummary().versions == 1)
        let keyID = try s.encryptionStatus().keyID
        try s.purgeAll()
        #expect(try s.purgeSummary().isEmpty && s.encryptionStatus().enabled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: env.historyRoot.path) == [HistoryEncryption.markerName])
        #expect(try s.encryptionStatus().keyID == keyID)
        let fresh = try #require(try store(env, keys).record(path: path, content: "new", origin: .baseline, changes: []))
        #expect(try Data(contentsOf: blob(env, path: path, version: fresh)).starts(with: HistoryEncryption.header))
        #expect(s.content(for: path, version: fresh) == "new")
    }
    @Test func tamperAndWrongLocationNeverFallBackToPlaintext() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let keys = MemoryHistoryKeys(), s = store(env, keys)
        let path = env.path("fake/tamper.json")
        try s.setEncryption(enabled: true)
        let version = try #require(try s.record(path: path, content: "secret", origin: .baseline, changes: []))
        let url = blob(env, path: path, version: version)
        let original = try Data(contentsOf: url)
        var tampered = original; tampered[tampered.count - 1] ^= 1
        try tampered.write(to: url)
        #expect(s.content(for: path, version: version) == nil)
        #expect(throws: (any Error).self) { try s.record(path: path, content: "secret", origin: .app, changes: []) }
        #expect(try Data(contentsOf: url) == tampered)
        let other = env.historyRoot.appendingPathComponent("different-name")
        try original.write(to: other)
        #expect(throws: (any Error).self) { try s.setEncryption(enabled: false) }
        #expect(try s.encryptionStatus().needsResume)
    }
    @Test func missingKeyOrMarkerNeverRegeneratesOrOverwritesHistory() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let keys = MemoryHistoryKeys(), s = store(env, keys)
        let path = env.path("fake/key.json")
        try s.setEncryption(enabled: true)
        _ = try s.record(path: path, content: "secret", origin: .baseline, changes: [])
        let marker = env.historyRoot.appendingPathComponent(HistoryEncryption.markerName)
        let metadata = try Data(contentsOf: marker)
        keys.forgetKeys()
        #expect(throws: (any Error).self) { try s.loadHistory(for: path) }
        #expect(throws: (any Error).self) { try s.record(path: env.path("new.json"), content: "no plaintext", origin: .app, changes: []) }
        #expect(throws: (any Error).self) { try s.setEncryption(enabled: true) }
        #expect(try keys.saveCount == 1 && Data(contentsOf: marker) == metadata)
        try FileManager.default.removeItem(at: marker)
        #expect(throws: (any Error).self) { try s.setEncryption(enabled: true) }
        #expect(throws: (any Error).self) { try s.record(path: env.path("new.json"), content: "no plaintext", origin: .app, changes: []) }
        #expect(keys.saveCount == 1 && !FileManager.default.fileExists(atPath: marker.path))
    }
    @Test func interruptedMigrationReadsMixedStateButBlocksWritesUntilRetry() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let keys = MemoryHistoryKeys(); var s = store(env, keys)
        let path = env.path("fake/retry.json")
        _ = try s.record(path: path, content: "A", origin: .baseline, changes: [])
        _ = try s.record(path: path, content: "B", origin: .app, changes: [])
        var count = 0
        s.writeEncryptionFile = { data, url in
            count += 1
            if count == 2 { throw CocoaError(.fileWriteUnknown) }
            try AtomicWriter.write(data, to: url)
        }
        #expect(throws: (any Error).self) { try s.setEncryption(enabled: true) }
        #expect(try s.encryptionStatus().needsResume)
        let files = try dataFiles(env.historyRoot)
        let flags = try files.map { try Data(contentsOf: $0).starts(with: HistoryEncryption.header) }
        #expect(flags.contains(true) && flags.contains(false))
        #expect(try s.loadHistory(for: path).map { s.content(for: path, version: $0) } == ["B", "A"])
        #expect(throws: (any Error).self) { try s.record(path: path, content: "C", origin: .app, changes: []) }
        #expect(throws: (any Error).self) { try s.setEncryption(enabled: false) }
        s.writeEncryptionFile = { try AtomicWriter.write($0, to: $1) }
        try s.resumeEncryption()
        #expect(try s.encryptionStatus().enabled && !s.encryptionStatus().needsResume)
        #expect(try dataFiles(env.historyRoot).allSatisfy { try Data(contentsOf: $0).starts(with: HistoryEncryption.header) })
        // The reverse migration has the same persistent recovery protocol.
        count = 0
        s.writeEncryptionFile = { data, url in
            count += 1; if count == 2 { throw CocoaError(.fileWriteUnknown) }
            try AtomicWriter.write(data, to: url)
        }
        #expect(throws: (any Error).self) { try s.setEncryption(enabled: false) }
        #expect(try !s.encryptionStatus().enabled && s.encryptionStatus().needsResume)
        s.writeEncryptionFile = { try AtomicWriter.write($0, to: $1) }
        try s.resumeEncryption()
        #expect(try !s.encryptionStatus().needsResume && !s.encryptionStatus().enabled)
        #expect(try s.loadHistory(for: path).map { s.content(for: path, version: $0) } == ["B", "A"])
    }
    @Test func encryptedLegacyAndMigratedBackupsRemainReadable() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let keys = MemoryHistoryKeys(), s = store(env, keys)
        let path = env.path("fake/ñ-cafe\u{301}-🦊.migrated")
        let legacy = env.historyRoot.appendingPathComponent(path.replacingOccurrences(of: "/", with: "__"))
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("legacy-secret".utf8).write(to: legacy.appendingPathComponent("100-legacy.txt"))
        let entries = [SnapshotStore.IndexEntry(ts: 100, hash: "legacy", file: "100-legacy.txt", origin: "baseline", changeCount: 0, summary: "fixture")]
        try JSONEncoder().encode(entries).write(to: legacy.appendingPathComponent("index.json"))
        try s.setEncryption(enabled: true)
        let version = try #require(s.loadHistory(for: path).first)
        #expect(s.content(for: path, version: version) == "legacy-secret")
        let backup = legacy.appendingPathExtension("migrated")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        try s.setEncryption(enabled: false)
        #expect(try String(contentsOf: backup.appendingPathComponent("100-legacy.txt"), encoding: .utf8) == "legacy-secret")
        #expect(s.content(for: path, version: version) == "legacy-secret")
    }
    @Test func markerAuthenticationAndCacheInvalidationPreventDowngrade() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let keys = MemoryHistoryKeys(); var s = store(env, keys)
        let path = env.path("fake/cache.json")
        var scans = 0; s.onEncryptionScan = { scans += 1 }
        for n in 0..<15 { _ = try s.record(path: path, content: "plain-\(n)", origin: .app, changes: []) }
        #expect(scans <= 2)
        try s.setEncryption(enabled: true)
        let initial = scans
        for n in 0..<15 { _ = try s.record(path: path, content: "encrypted-\(n)", origin: .app, changes: []) }
        #expect(scans <= initial + 1)
        let marker = env.historyRoot.appendingPathComponent(HistoryEncryption.markerName)
        let original = try Data(contentsOf: marker)
        var tree = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        tree["phase"] = "plain"
        try JSONSerialization.data(withJSONObject: tree).write(to: marker)
        #expect(throws: (any Error).self) { try s.record(path: env.path("new.json"), content: "no downgrade", origin: .app, changes: []) }
        try original.write(to: marker)
        try FileManager.default.removeItem(at: marker)
        #expect(throws: (any Error).self) { try s.record(path: env.path("new.json"), content: "no downgrade", origin: .app, changes: []) }
        #expect(scans > initial)
    }
    @Test func defaultProviderNeverTouchesKeychainInIsolatedRun() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let s = env.makeSnapshots()
        #expect(throws: (any Error).self) { try s.setEncryption(enabled: true) }
        #expect(!FileManager.default.fileExists(atPath: env.historyRoot.appendingPathComponent(HistoryEncryption.markerName).path))
    }
    @Test func purgeWithDamagedMetadataDeletesContentWithoutDowngrading() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let keys = MemoryHistoryKeys(), s = store(env, keys)
        let path = env.path("fake/damaged.json")
        try s.setEncryption(enabled: true)
        _ = try s.record(path: path, content: "secret", origin: .baseline, changes: [])
        let marker = env.historyRoot.appendingPathComponent(HistoryEncryption.markerName)
        var forged = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
        forged["phase"] = "encrypting"
        try JSONSerialization.data(withJSONObject: forged).write(to: marker)
        try s.purgeAll()
        try s.purgeAll()
        #expect(s.purgeSummary().isEmpty)
        #expect(throws: (any Error).self) { try s.encryptionStatus() }
        try Data("{broken".utf8).write(to: marker)
        try s.purgeAll()
        try s.purgeAll()
        #expect(s.purgeSummary().isEmpty)
        #expect(try Data(contentsOf: marker) == Data("{broken".utf8))
        #expect(throws: (any Error).self) { try s.encryptionStatus() }
        #expect(throws: (any Error).self) { try s.record(path: path, content: "no downgrade", origin: .app, changes: []) }
        let outside = try env.write("outside/metadata.json", "outside-kept")
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: outside)
        try Data("stray-secret".utf8).write(to: env.historyRoot.appendingPathComponent("stray"))
        try s.purgeAll()
        try s.purgeAll()
        #expect(try env.read("outside/metadata.json") == "outside-kept")
        #expect(HistoryEncryption.type(marker) == S_IFLNK && s.purgeSummary().isEmpty)
        #expect(throws: (any Error).self) { try s.record(path: path, content: "no downgrade", origin: .app, changes: []) }
    }
    @Test func authenticatedPlainMarkerCannotAuthorizeWritesBesideCiphertext() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let keys = MemoryHistoryKeys(), s = store(env, keys)
        let path = env.path("fake/replayed-marker.json")
        try s.setEncryption(enabled: true)
        _ = try s.record(path: path, content: "secret", origin: .baseline, changes: [])
        try s.setEncryption(enabled: false)
        let marker = env.historyRoot.appendingPathComponent(HistoryEncryption.markerName)
        let plainMetadata = try Data(contentsOf: marker)
        try s.setEncryption(enabled: true)
        try plainMetadata.write(to: marker)
        #expect(throws: (any Error).self) { try s.record(path: env.path("new.json"), content: "no plaintext", origin: .app, changes: []) }
        #expect(throws: (any Error).self) { try s.setEncryption(enabled: false) }
        #expect(!FileManager.default.fileExists(atPath: env.historyRoot.appendingPathComponent(SnapshotStore.historyDirName(for: env.path("new.json"))).path))
    }
    @Test func recoveryRemovesOnlyReservedAtomicTempsWithoutFollowingLinks() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let keys = MemoryHistoryKeys(), s = store(env, keys)
        let path = env.path("fake/interrupted-atomic.json")
        try s.setEncryption(enabled: true)
        _ = try s.record(path: path, content: "kept-version", origin: .baseline, changes: [])
        let directory = env.historyRoot.appendingPathComponent(SnapshotStore.historyDirName(for: path))
        let index = directory.appendingPathComponent("index.json")
        let encryptedIndex = try Data(contentsOf: index)
        let outsidePattern = directory.appendingPathComponent(".keep.acfg-tmp-invalid-uuid")
        let encryption = HistoryEncryption(root: env.historyRoot, keyProvider: keys)
        let retainedData = try encryption.withRootLock(create: false) { try encryption.encoded(Data("retained-stray".utf8), for: outsidePattern) }
        try AtomicWriter.write(retainedData, to: outsidePattern)
        let complete = directory.appendingPathComponent(".index.json.acfg-tmp-" + UUID().uuidString)
        let partial = directory.appendingPathComponent("objects/.partial.acfg-tmp-" + UUID().uuidString)
        let modeTemp = env.historyRoot.appendingPathComponent("..encryption.json.acfg-tmp-" + UUID().uuidString)
        let link = directory.appendingPathComponent(".link.acfg-tmp-" + UUID().uuidString)
        try encryptedIndex.write(to: complete) // Its tag authenticates index.json, never this temporary name.
        try Data(HistoryEncryption.header.prefix(9)).write(to: partial)
        try Data("{unfinished metadata".utf8).write(to: modeTemp)
        let outside = try env.write("outside/kept.txt", "outside-kept")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(try s.encryptionStatus().needsResume)
        try s.resumeEncryption()
        #expect(try !s.encryptionStatus().needsResume && s.encryptionStatus().enabled)
        for temp in [complete, partial, modeTemp, link] { #expect(HistoryEncryption.type(temp) == nil) }
        #expect(try Data(contentsOf: outsidePattern) == retainedData)
        #expect(try env.read("outside/kept.txt") == "outside-kept")
        #expect(s.latestContent(for: path)?.content == "kept-version")
        _ = try s.record(path: path, content: "after-recovery", origin: .app, changes: [])
        #expect(s.latestContent(for: path)?.content == "after-recovery")
    }
    @Test func purgeDoesNotNeedALostKeyAndPreservesEncryptionIdentity() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let keys = MemoryHistoryKeys(), s = store(env, keys)
        try s.setEncryption(enabled: true)
        _ = try s.record(path: env.path("fake/key.json"), content: "secret", origin: .baseline, changes: [])
        let marker = env.historyRoot.appendingPathComponent(HistoryEncryption.markerName)
        let metadata = try Data(contentsOf: marker)
        keys.forgetKeys()
        try s.purgeAll()
        #expect(s.purgeSummary().isEmpty)
        #expect(try Data(contentsOf: marker) == metadata)
        #expect(keys.saveCount == 1)
        #expect(throws: (any Error).self) { try s.record(path: env.path("new.json"), content: "no plaintext", origin: .app, changes: []) }
    }
    @Test func concurrentStoresSerializeModeChangesAndRecords() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let root = env.historyRoot, keys = MemoryHistoryKeys()
        let group = DispatchGroup()
        for worker in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let s = SnapshotStore(root: root, historyLimit: { 100 }, keyProvider: keys, isPathTracked: { _ in false })
                    for n in 0..<5 {
                        _ = try s.record(path: "/fixture/\(worker).json", content: "value-\(n)", origin: .app, changes: [])
                        if worker == 0 { try s.setEncryption(enabled: n.isMultiple(of: 2)) }
                    }
                } catch { Issue.record(error) }
            }
        }
        #expect(group.wait(timeout: .now() + 15) == .success)
        let s = store(env, keys)
        for worker in 0..<4 {
            let path = "/fixture/\(worker).json"
            let versions = try s.loadHistory(for: path)
            #expect(versions.count == 5 && s.content(for: path, version: versions[0]) == "value-4")
        }
        #expect(try s.encryptionStatus().enabled)
    }
}
}
