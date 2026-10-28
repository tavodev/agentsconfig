import Foundation
import Testing

extension AgentsConfigTestSuite {
@Suite(.serialized) @MainActor
struct HistoryEncryptionFlowTests {
    private final class Keys: HistoryKeyProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]
        var count: Int { lock.withLock { values.count } }
        func loadKey(id: String) throws -> Data? { lock.withLock { values[id] } }
        func storeKey(_ data: Data, id: String) throws { lock.withLock { values[id] = data } }
        func forget() { lock.withLock { values = [:] } }
    }

    @Test func encryptionReviewIsCancelableAndDoesNotCreateKeys() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.installClaude()
        let keys = Keys()
        let store = ConfigStore(notifier: nil, historyKeyProvider: keys)
        let path = env.path(".claude/settings.json")
        let before = try env.read(".claude/settings.json")
        let versions = store.history(for: path)
        store.requestHistoryEncryption(enabled: true)
        #expect(store.pendingHistoryEncryption?.enabled == true)
        #expect(!store.historyEncryptionBusy && keys.count == 0)
        #expect(!FileManager.default.fileExists(atPath: env.historyRoot.appendingPathComponent(HistoryEncryption.markerName).path))
        store.cancelHistoryEncryption()
        #expect(store.pendingHistoryEncryption == nil)
        #expect(store.history(for: path) == versions)
        #expect(try env.read(".claude/settings.json") == before)
    }

    @Test func encryptedHistoryKeepsReviewedSavesAndRestores() async throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.installClaude()
        let keys = Keys()
        let store = ConfigStore(notifier: nil, historyKeyProvider: keys)
        let path = env.path(".claude/settings.json")
        let original = try env.read(".claude/settings.json")
        let baseline = try #require(store.history(for: path).first)
        store.selectedPath = path
        store.updateEdit(path: path, text: #"{"model":"encrypted-fixture"}"#)
        store.requestSave(path: path)
        #expect(store.pendingSaveReview != nil)
        store.requestHistoryEncryption(enabled: true)
        store.confirmHistoryEncryption()
        #expect(store.historyEncryptionBusy && store.historyPurgeBlocked)
        #expect(!store.canSaveSelected && store.pendingSaveReview == nil)
        store.requestSave(path: path)
        #expect(store.pendingSaveReview == nil)
        await store.waitForHistoryEncryption()
        await store.waitForRefresh()
        #expect(store.historyEncryptionError == nil && store.historyEncryptionStatus?.enabled == true)
        #expect(keys.count == 1)
        #expect(try env.read(".claude/settings.json") == original)
        store.requestSave(path: path)
        #expect(store.pendingSaveReview != nil)
        #expect(try env.read(".claude/settings.json") == original)
        store.confirmSaveReview()
        #expect(store.saveErrors[path] == nil)
        #expect(try env.read(".claude/settings.json").contains("encrypted-fixture"))
        store.requestRestore(path: path, version: baseline)
        #expect(store.restoreProposedText == original)
        #expect(try env.read(".claude/settings.json").contains("encrypted-fixture"))
        store.confirmRestore()
        #expect(try env.read(".claude/settings.json") == original)
        store.requestHistoryEncryption(enabled: false)
        store.confirmHistoryEncryption()
        await store.waitForHistoryEncryption()
        await store.waitForRefresh()
        #expect(store.historyEncryptionError == nil && store.historyEncryptionStatus?.enabled == false)
        #expect(store.versionContent(path: path, version: baseline) == original)
    }

    @Test func backgroundLargeFileHistoryUsesTheSameEncryptionKeys() async throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let keys = Keys()
        let snapshots = SnapshotStore(keyProvider: keys)
        try snapshots.setEncryption(enabled: true)
        let original = String(repeating: "# large history fixture\n", count: 100_000)
        let url = try env.write(".codex/config.toml", original)
        let worker = LargeFileWorker()
        let policy = LargeFileWorker.HistoryPolicy(root: env.historyRoot, boundary: AppPaths.applicationSupport,
            enabled: true, limit: 20, keyProvider: keys)
        let loaded = try await worker.load(url.path, format: .toml, previousHash: nil, history: policy)
        #expect(loaded.historyError == nil && loaded.parseError == nil)
        let version = try #require(try snapshots.loadHistory(for: url.path).first)
        #expect(snapshots.content(for: url.path, version: version) == original)
        let updated = original + "model = 'encrypted-large-fixture'\n"
        let result = await worker.save(url.path, proposed: updated, format: .toml,
            expected: .content(original), history: policy)
        if case .saved(let saved) = result { #expect(saved.historyError == nil) }
        else { Issue.record("The encrypted large-file save failed.") }
        #expect(try String(contentsOf: url, encoding: .utf8) == updated)
        #expect(try snapshots.loadHistory(for: url.path).count == 2)
    }

    @Test func unavailableKeyIsVisibleAndDoesNotRegenerateOnReview() async throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.installClaude()
        let keys = Keys()
        let store = ConfigStore(notifier: nil, historyKeyProvider: keys)
        store.requestHistoryEncryption(enabled: true)
        store.confirmHistoryEncryption()
        await store.waitForHistoryEncryption()
        await store.waitForRefresh()
        keys.forget()
        store.loadHistoryEncryptionStatus()
        #expect(store.historyEncryptionStatus == nil && store.historyEncryptionError != nil)
        store.requestHistoryEncryption(enabled: false)
        #expect(store.pendingHistoryEncryption == nil && keys.count == 0)
        #expect(store.historyEncryptionError != nil)
    }
}
}
