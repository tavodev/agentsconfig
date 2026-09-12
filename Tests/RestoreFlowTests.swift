import Testing
import Foundation

/// F8: every restore/revert entry point must pass through the same explicit
/// confirmation, and errors must stay visible regardless of dirty state.
extension AgentsConfigTestSuite {
@Suite("Protected restore flow", .serialized)
@MainActor
struct RestoreFlowTests {

    @Test func failedDraftArchiveAbortsEvenWhenRestoringCurrentDisk() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let p = env.path(".claude/settings.json")
        let before = try env.read(".claude/settings.json")
        let version = try #require(store.history(for: p).first)
        let draft = "{\"model\":\"unsaved\"}"
        store.updateEdit(path: p, text: draft)
        let index = env.historyRoot.appendingPathComponent(SnapshotStore.historyDirName(for: p))
            .appendingPathComponent("index.json")
        let validIndex = try Data(contentsOf: index)
        try "{broken".write(to: index, atomically: true, encoding: .utf8)
        let events = store.activity.count
        store.requestRestore(path: p, version: version)
        store.confirmRestore()
        #expect(store.dirtyPaths.contains(p))
        #expect(store.text(for: p) == draft)
        #expect(try env.read(".claude/settings.json") == before)
        #expect(store.saveErrors[p] != nil)
        #expect(store.historyErrors[p] != nil)
        #expect(store.activity.count == events)

        try validIndex.write(to: index, options: .atomic)
        store.requestRestore(path: p, version: version)
        store.confirmRestore()
        #expect(store.saveErrors[p] == nil)
        #expect(store.historyErrors[p] == nil)
        #expect(!store.dirtyPaths.contains(p))
        #expect(store.history(for: p).contains { store.versionContent(path: p, version: $0) == draft })
    }

    @Test func restoringWithSmallRetentionKeepsDraftAndDiskRecoverable() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        AppSettings.defaults.set(1, forKey: "historyLimit")
        try env.installClaude()
        let store = env.makeStore()
        let p = env.path(".claude/settings.json")
        let target = try #require(store.history(for: p).first)
        let targetContent = try #require(store.versionContent(path: p, version: target))
        let disk = "{\"model\":\"saved\"}"
        let draft = "{\"model\":\"draft\"}"
        store.updateEdit(path: p, text: disk)
        store.save(path: p)
        store.updateEdit(path: p, text: draft)
        store.requestRestore(path: p, version: target)
        store.confirmRestore()
        #expect(store.saveErrors[p] == nil)
        #expect(!store.dirtyPaths.contains(p))
        #expect(try env.read(".claude/settings.json") == targetContent)
        let contents = store.history(for: p).compactMap { store.versionContent(path: p, version: $0) }
        #expect(contents.contains(draft))
        #expect(contents.contains(disk))
        #expect(contents.contains(targetContent))
    }

    @Test(arguments: [".claude.json", ".gemini/config/config.json"])
    func excludedHistoryDoesNotDiscardDirtyBufferOnRevert(relativePath: String) throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        try env.installGemini()
        try env.write(".gemini/config/config.json", "{}")
        let store = env.makeStore()
        let p = env.path(relativePath)
        let disk = "{\"mcpServers\":{}}"
        let draft = "{\"mcpServers\":{},\"draft\":true}"
        try env.write(relativePath, disk)
        store.handleFileChanged(p)
        store.updateEdit(path: p, text: draft)
        store.requestRevertExternal(p)
        let request = try #require(store.pendingRestore)
        #expect(store.restoreExplanation(for: request) == L("Restore is blocked: this file has unsaved edits and history is disabled. Save or discard the edits first."))
        store.confirmRestore()
        #expect(store.saveErrors[p] != nil)
        #expect(store.text(for: p) == draft)
        #expect(store.dirtyPaths.contains(p))
        #expect(store.externalChanges[p] != nil)
        #expect(try env.read(relativePath) == disk)
        #expect(try env.makeSnapshots().loadHistory(for: p).isEmpty)
    }

    @Test func cancellingRestorePreservesDirtyBufferAndHistory() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let p = env.path(".claude/settings.json")
        let disk = try env.read(".claude/settings.json")
        let history = store.history(for: p).map(\.id)
        let target = try #require(store.history(for: p).first)
        let draft = "{\"draft\":true}"
        store.updateEdit(path: p, text: draft)
        store.requestRestore(path: p, version: target)
        store.cancelRestore()
        store.confirmRestore()
        #expect(store.pendingRestore == nil)
        #expect(store.text(for: p) == draft)
        #expect(store.dirtyPaths.contains(p))
        #expect(store.history(for: p).map(\.id) == history)
        #expect(try env.read(".claude/settings.json") == disk)
    }

    @Test func newExternalChangeDuringRestoreKeepsDiskAndDraft() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let p = env.path(".claude/settings.json")
        let version = try #require(store.history(for: p).first)
        let draft = "{\"model\":\"draft\"}"
        let disk = "{\"model\":\"external\"}"
        store.updateEdit(path: p, text: draft)
        store.requestRestore(path: p, version: version)
        try env.write(".claude/settings.json", disk)
        store.confirmRestore()
        #expect(store.conflicts.contains(p))
        #expect(store.text(for: p) == draft)
        #expect(store.dirtyPaths.contains(p))
        #expect(try env.read(".claude/settings.json") == disk)
    }

    @Test func restoringInvalidConfigIsRejectedBeforeWriting() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let p = env.path(".claude/settings.json")
        let before = try env.read(".claude/settings.json")
        let version = try #require(try env.makeSnapshots().record(path: p, content: "{invalid",
                                                                  origin: .external, changes: []))
        store.requestRestore(path: p, version: version)
        store.confirmRestore()
        #expect(store.saveErrors[p] != nil)
        #expect(try env.read(".claude/settings.json") == before)
    }

    /// Repro: `restorePrevious` from the context menu / inspector wrote to
    /// disk with no confirmation at all.
    @Test func restoreEntriesRequireConfirmation() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let p = env.path(".claude/settings.json")

        store.updateEdit(path: p, text: #"{"model":"opus"}"#)
        store.save(path: p)
        store.updateEdit(path: p, text: #"{"model":"sonnet"}"#)
        store.save(path: p)
        #expect(store.history(for: p).count >= 2)

        // a bare request changes nothing on disk
        store.requestRestorePrevious(p)
        #expect(store.pendingRestore != nil)
        #expect(try env.read(".claude/settings.json") == #"{"model":"sonnet"}"#)

        store.cancelRestore()
        #expect(store.pendingRestore == nil)
        #expect(try env.read(".claude/settings.json") == #"{"model":"sonnet"}"#)

        // confirmed restore goes through F2 guarantees
        store.requestRestorePrevious(p)
        store.confirmRestore()
        #expect(store.pendingRestore == nil)
        #expect(try env.read(".claude/settings.json") == #"{"model":"opus"}"#)
    }

    /// Confirming a restore with unsaved edits must archive the buffer in
    /// history before dropping it — never silently lose it.
    @Test func confirmedRestoreArchivesDirtyBuffer() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let p = env.path(".claude/settings.json")

        store.updateEdit(path: p, text: #"{"model":"opus"}"#)
        store.save(path: p)
        // newest history entry = the original fixture content (backup)
        let target = try #require(store.history(for: p).first)
        let targetContent = try #require(
            store.versionContent(path: p, version: target))

        // unsaved buffer + request + confirm → buffer lands in history
        store.updateEdit(path: p, text: #"{"model":"dirty-draft"}"#)
        store.requestRestore(path: p, version: target)
        store.confirmRestore()

        #expect(try env.read(".claude/settings.json") == targetContent)
        #expect(!store.dirtyPaths.contains(p))
        let contents = store.history(for: p)
            .compactMap { store.versionContent(path: p, version: $0) }
        #expect(contents.contains(#"{"model":"dirty-draft"}"#))
    }

    /// Repro: the Revert button on the external-change banner wrote
    /// immediately, no confirmation.
    @Test func externalRevertRequiresConfirmation() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let p = env.path(".claude/settings.json")

        try env.write(".claude/settings.json", #"{"model":"extern"}"#)
        store.handleFileChanged(p)
        #expect(store.externalChanges[p] != nil)

        store.requestRevertExternal(p)
        #expect(store.pendingRestore?.kind == .revertExternal)
        #expect(try env.read(".claude/settings.json") == #"{"model":"extern"}"#)

        store.confirmRestore()
        #expect(try env.read(".claude/settings.json")
                == #"{"apiKey":"sk-test-FAKE-0000","theme":"dark","model":"opus"}"#)
    }

    /// A failed restore must not clear the conflict/external banners —
    /// the user still needs them to retry or resolve.
    @Test func failedRestoreKeepsBannerState() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let p = env.path(".claude/settings.json")

        try env.write(".claude/settings.json", #"{"model":"extern"}"#)
        store.handleFileChanged(p)
        let change = try #require(store.externalChanges[p])

        // a version whose blob is missing → restore fails visibly
        let ghost = FileVersion(date: .now, hash: String(repeating: "f", count: 64),
                                file: String(repeating: "f", count: 64),
                                origin: .app, changeCount: 0, summary: "x")
        store.requestRestore(path: p, version: ghost)
        store.confirmRestore()

        #expect(store.saveErrors[p] != nil)
        #expect(store.externalChanges[p]?.diskContent == change.diskContent)
    }

    /// Errors are visible and dismissible independently of the dirty flag.
    @Test func saveErrorIsRetriableAndDismissibleWhileDirty() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let p = env.path(".claude/settings.json")

        store.updateEdit(path: p, text: "{ invalid")
        store.save(path: p)
        #expect(store.saveErrors[p] != nil)     // error surfaces while dirty
        #expect(store.dirtyPaths.contains(p))

        store.clearSaveError(path: p)
        #expect(store.saveErrors[p] == nil)
        #expect(store.dirtyPaths.contains(p))   // buffer untouched
    }

    /// Read-only rejection also applies through the confirm path.
    @Test func confirmRestoreRespectsReadOnly() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.installCodex()   // auth.json is readOnly
        let store = env.makeStore()
        let p = env.path(".codex/auth.json")
        let v = FileVersion(date: .now, hash: "x", file: "x",
                            origin: .app, changeCount: 0, summary: "x")
        store.requestRestore(path: p, version: v)
        store.confirmRestore()
        #expect(store.saveErrors[p] == L("Read-only file"))
        #expect(try env.read(".codex/auth.json") == #"{"OPENAI_API_KEY":"sk-test-FAKE-1111"}"#)
    }
}

}
