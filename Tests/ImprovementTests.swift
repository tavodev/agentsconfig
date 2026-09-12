import Foundation
import Testing
import SwiftUI
import AppKit

extension AgentsConfigTestSuite {
@Suite("Requested improvements", .serialized)
@MainActor struct ImprovementTests {
    @Test func pageEditorRejectsOversizedReplacementWithoutMutatingBuffer() {
        var text = "initial"
        var rejected = false
        let editor = CodeEditor(documentID: "page", text: Binding(get: { text }, set: { text = $0 }),
            format: .text, maximumEditableLength: 20, onLimitExceeded: { rejected = true })
        let coordinator = editor.makeCoordinator()
        let view = NSTextView()
        view.string = text
        #expect(!coordinator.textView(view, shouldChangeTextIn: NSRange(location: 0, length: 7),
                                    replacementString: String(repeating: "x", count: 21)))
        #expect(rejected)
        #expect(text == "initial")
    }

    @Test func backgroundLimitAndInvalidContentDoNotReachWrite() async throws {
        let worker = LargeFileWorker()
        let error = try await worker.validate(String(repeating: "x", count: Parsers.maximumBackgroundBytes + 1), format: .json)
        #expect(error != nil)
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let path = env.path(".claude/settings.json")
        let original = try env.read(".claude/settings.json")
        store.updateEdit(path: path, text: "{invalid" + String(repeating: "x", count: 2_100_000))
        store.requestSave(path: path)
        await store.waitForBackgroundWork(path: path)
        #expect(store.pendingSaveReview == nil)
        #expect(store.saveErrors[path] != nil)
        #expect(try env.read(".claude/settings.json") == original)
    }

    @Test func largeSourcePagesPreserveUnicodeAndOtherPages() {
        let text = String(repeating: "a", count: LargeSourceEditor.pageSize - 1) + "👩🏽‍💻" + String(repeating: "b", count: LargeSourceEditor.pageSize)
        for page in 0...1 {
            let range = LargeSourceEditor.pageRange(in: text, page: page)
            let chunk = (text as NSString).substring(with: range)
            #expect(LargeSourceEditor.replacingPage(in: text, page: page, with: chunk) == text)
            #expect(!chunk.contains("�"))
        }
        let updated = LargeSourceEditor.replacingPage(in: text, page: 0, with: "changed")
        #expect(updated.hasPrefix("changed"))
        #expect(updated.hasSuffix(String(repeating: "b", count: LargeSourceEditor.pageSize)))
    }

    @Test func sharedHistoryObjectsSurviveSingleVersionRemovalAndCleanupCanRetry() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        var snapshots = env.makeSnapshots()
        let path = env.path("versions.json")
        let first = try #require(try snapshots.record(path: path, content: "A", origin: .app, changes: []))
        _ = try snapshots.record(path: path, content: "B", origin: .app, changes: [])
        let last = try #require(try snapshots.record(path: path, content: "A", origin: .app, changes: []))
        let ids = Set(try snapshots.loadHistory(for: path).map(\.id))
        try snapshots.removeVersions(for: path, ids: [first.id], expectedIDs: ids)
        #expect(snapshots.content(for: path, version: last) == "A")
        let remaining = Set(try snapshots.loadHistory(for: path).map(\.id))
        snapshots.removeContentFile = { _ in throw CocoaError(.fileWriteNoPermission) }
        #expect(throws: (any Error).self) { try snapshots.removeVersions(for: path, ids: remaining, expectedIDs: remaining) }
        #expect(try snapshots.loadHistory(for: path).isEmpty)
        #expect(snapshots.content(for: path, version: last) != nil)
        snapshots.removeContentFile = { try FileManager.default.removeItem(at: $0) }
        try snapshots.cleanupOrphans(for: path)
        #expect(snapshots.content(for: path, version: last) == nil)
    }

    @Test func deletedFileCannotBeResurrectedByPendingBackgroundRead() async throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.installClaude(settingsJSON: "{\"payload\":\"" + String(repeating: "x", count: 2_100_000) + "\"}")
        let store = env.makeStore()
        let path = env.path(".claude/settings.json")
        _ = store.document(for: path)
        try FileManager.default.removeItem(atPath: path)
        store.handleFileChanged(path)
        await store.waitForBackgroundWork(path: path)
        #expect(store.document(for: path) == nil)
        #expect(!store.loadingPaths.contains(path))
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func cleanRestoreReviewRejectsDiskRebasedByWatcher() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let path = env.path(".claude/settings.json")
        let target = try #require(store.history(for: path).first)
        store.requestRestore(path: path, version: target)
        try env.write(".claude/settings.json", "{\"newExternal\":true}")
        store.handleFileChanged(path)
        store.confirmRestore()
        #expect(store.conflicts.contains(path))
        #expect(try env.read(".claude/settings.json") == "{\"newExternal\":true}")
    }

    @Test func perFileOptOutAndConfirmedHistoryRemoval() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let path = env.path(".claude/settings.json")
        let original = try env.read(".claude/settings.json")
        store.setHistoryEnabled(false, for: path)
        store.updateEdit(path: path, text: "{}")
        store.save(path: path)
        #expect(store.history(for: path).count == 1)
        #expect(AppSettings.defaults.stringArray(forKey: "excludedHistoryPaths")?.contains(path) == true)
        store.requestHistoryRemoval(path: path)
        store.cancelHistoryRemoval()
        #expect(store.history(for: path).count == 1)
        store.requestHistoryRemoval(path: path)
        store.confirmHistoryRemoval()
        #expect(store.history(for: path).isEmpty)
        #expect(try env.read(".claude/settings.json") == "{}")
        #expect(!original.isEmpty)
    }

    @Test func historyRemovalDoesNotDeleteNewlyRecordedVersions() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let path = env.path(".claude/settings.json")
        store.requestHistoryRemoval(path: path)
        _ = try env.makeSnapshots().record(path: path, content: "{}", origin: .external, changes: [])
        store.confirmHistoryRemoval()
        #expect(store.historyRemovalErrors[path] != nil)
        #expect(store.history(for: path).count == 2)
    }

    @Test func failedHistoryRemovalPublicationKeepsAllBlobs() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        var snapshots = env.makeSnapshots()
        let path = env.path("history.json")
        let version = try #require(try snapshots.record(path: path, content: "{}", origin: .app, changes: []))
        snapshots.writeIndexFile = { _, _ in throw CocoaError(.fileWriteUnknown) }
        #expect(throws: (any Error).self) {
            try snapshots.removeVersions(for: path, ids: [version.id], expectedIDs: [version.id])
        }
        #expect(snapshots.content(for: path, version: version) == "{}")
        #expect(try snapshots.loadHistory(for: path).count == 1)
    }

    @Test func largeFileLoadsReviewsSavesAndRestoresInBackground() async throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let original = "{\"payload\":\"" + String(repeating: "x", count: 2_100_000) + "\"}"
        try env.installClaude(settingsJSON: original)
        let store = env.makeStore()
        let path = env.path(".claude/settings.json")
        #expect(store.document(for: path) == nil)
        await store.waitForBackgroundWork(path: path)
        #expect(store.text(for: path) == original)
        let baseline = try #require(store.history(for: path).first)
        let changed = original.replacingOccurrences(of: "payload", with: "updated")
        store.updateEdit(path: path, text: changed)
        store.requestSave(path: path)
        await store.waitForBackgroundWork(path: path)
        #expect(store.pendingSaveReview != nil)
        #expect(try env.read(".claude/settings.json") == original)
        store.confirmSaveReview()
        await store.waitForBackgroundWork(path: path)
        #expect(store.saveErrors[path] == nil)
        #expect(try env.read(".claude/settings.json") == changed)
        #expect(!store.dirtyPaths.contains(path))
        store.updateEdit(path: path, text: "{\"draft\":true}")
        store.requestRestore(path: path, version: baseline)
        await store.waitForBackgroundWork(path: path)
        store.confirmRestore()
        await store.waitForBackgroundWork(path: path)
        #expect(try env.read(".claude/settings.json") == original)
        #expect(store.history(for: path).contains { store.versionContent(path: path, version: $0) == "{\"draft\":true}" })
    }

    @Test func largeFileReviewDetectsConflictsAndCanAcceptDisk() async throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let original = "{\"payload\":\"" + String(repeating: "x", count: 2_100_000) + "\"}"
        try env.installClaude(settingsJSON: original)
        let store = env.makeStore()
        let path = env.path(".claude/settings.json")
        _ = store.document(for: path)
        await store.waitForBackgroundWork(path: path)
        store.updateEdit(path: path, text: "{\"draft\":true}")
        store.requestSave(path: path)
        await store.waitForBackgroundWork(path: path)
        let external = original.replacingOccurrences(of: "payload", with: "external")
        try env.write(".claude/settings.json", external)
        store.confirmSaveReview()
        await store.waitForBackgroundWork(path: path)
        #expect(store.conflicts.contains(path))
        #expect(store.dirtyPaths.contains(path))
        store.resolveConflictUseDisk(path: path)
        await store.waitForBackgroundWork(path: path)
        #expect(store.text(for: path) == external)
        #expect(!store.dirtyPaths.contains(path))
    }

    @Test func saveReviewDoesNotWriteUntilConfirmed() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let path = env.path(".claude/settings.json")
        let original = try env.read(".claude/settings.json")
        let proposed = "{\"model\":\"reviewed\"}"
        store.updateEdit(path: path, text: proposed)
        store.requestSave(path: path)
        #expect(store.pendingSaveReview?.proposed == proposed)
        #expect(try env.read(".claude/settings.json") == original)
        store.cancelSaveReview()
        #expect(store.dirtyPaths.contains(path))
        store.requestSave(path: path)
        store.confirmSaveReview()
        #expect(try env.read(".claude/settings.json") == proposed)
        #expect(!store.dirtyPaths.contains(path))
    }

    @Test(arguments: [false, true])
    func changingBufferOrDiskInvalidatesSaveReview(disk: Bool) throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.installClaude()
        let store = env.makeStore()
        let path = env.path(".claude/settings.json")
        store.updateEdit(path: path, text: "{\"model\":\"reviewed\"}")
        store.requestSave(path: path)
        if disk { try env.write(".claude/settings.json", "{\"external\":true}") }
        else { store.updateEdit(path: path, text: "{\"newDraft\":true}") }
        store.confirmSaveReview()
        #expect(store.dirtyPaths.contains(path))
        #expect(store.saveErrors[path] != nil || store.conflicts.contains(path))
        #expect(try !env.read(".claude/settings.json").contains("reviewed"))
    }
}
}
