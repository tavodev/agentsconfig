import Testing
import Foundation
import XCTest

/// F6: the watcher must attach late-created files, survive delete/rename
/// cycles (atomic saves), re-attach with backoff, and report the *real*
/// number of attached watchers.
extension AgentsConfigTestSuite {
@Suite("FileWatcher recovery", .serialized)
@MainActor
struct FileWatcherTests {

    private final class Deliveries: @unchecked Sendable {
        private let lock = NSLock()
        private var actions: [@Sendable () -> Void] = []
        let queued = XCTestExpectation(description: "callback queued")
        func enqueue(_ action: @escaping @Sendable () -> Void) {
            lock.lock(); actions.append(action); lock.unlock()
            queued.fulfill()
        }
        func flush() {
            lock.lock(); let pending = actions; actions = []; lock.unlock()
            pending.forEach { $0() }
        }
    }

    @Test(arguments: [false, true])
    func removedObservationCannotDeliverQueuedCallback(reinsert: Bool) async throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.write("queued.json", "{}")
        let path = env.path("queued.json")
        let deliveries = Deliveries()
        let count = LockedBox()
        let watcher = FileWatcher(debounce: 0.01, deliver: { deliveries.enqueue($0) }, onChange: { _ in count.set(1) })
        watcher.watch([path])
        await watcher.synchronize()
        watcher.signalChange(path)
        let result = await XCTWaiter.fulfillment(of: [deliveries.queued], timeout: 2)
        #expect(result == .completed)
        watcher.unwatchAll()
        if reinsert { watcher.watch([path]) }
        await watcher.synchronize()
        deliveries.flush()
        #expect(count.get() == 0)
        watcher.unwatchAll()
        await watcher.synchronize()
    }

    @Test(arguments: [false, true])
    func removalCancelsPendingDebounce(removeAll: Bool) async throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        try env.write("pending.json", "{}")
        let path = env.path("pending.json")
        let unexpected = XCTestExpectation(description: "cancelled callback")
        unexpected.isInverted = true
        let watcher = FileWatcher(debounce: 0.1) { _ in unexpected.fulfill() }
        watcher.watch([path])
        watcher.signalChange(path)
        await watcher.synchronize() // debounce is now pending, not a timing guess
        if removeAll { watcher.unwatchAll() } else { watcher.watch([]) }
        await watcher.synchronize()
        #expect(await XCTWaiter.fulfillment(of: [unexpected], timeout: 0.3) == .completed)
    }

    /// Collects change notifications off the watcher's serial queue.
    private actor Events {
        var paths: [String] = []
        func add(_ p: String) { paths.append(p) }
        func contains(_ p: String) -> Bool { paths.contains(p) }
    }

    private func makeWatcher(_ events: Events,
                             counts: LockedBox? = nil) -> FileWatcher {
        let w = FileWatcher { p in Task { await events.add(p) } }
        if let counts {
            w.onAttachedCount = { n in counts.set(n) }
        }
        return w
    }

    /// Mutable box for the synchronous (non-async) count callback.
    private final class LockedBox: @unchecked Sendable {
        private var v = 0
        private let lock = NSLock()
        func set(_ n: Int) { lock.lock(); v = n; lock.unlock() }
        func get() -> Int { lock.lock(); defer { lock.unlock() }; return v }
    }

    /// Repro: a file missing at watch() time was never picked up — its later
    /// creation went unobserved until a full refresh.
    @Test func lateCreatedFileIsPickedUp() async throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        AppSettings.defaults.set(0.05, forKey: "watchDebounce")

        let p = env.path("later.json")          // does not exist yet
        let events = Events()
        let counts = LockedBox()
        let w = makeWatcher(events, counts: counts)
        defer { w.unwatchAll() }
        w.watch([p])
        #expect(counts.get() == 0)

        // created after watching started — must still be observed
        try env.write("later.json", "{\"v\":1}")
        try await Task.sleep(for: .milliseconds(600))
        #expect(counts.get() == 1)

        try env.write("later.json", "{\"v\":2}")
        try await Task.sleep(for: .milliseconds(400))
        #expect(await events.contains(p))
    }

    /// Repro: atomic save (tmp + rename) detached the source; a single 150ms
    /// retry raced the write and then the file was watched no more.
    @Test func atomicSaveCyclesKeepWatching() async throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        AppSettings.defaults.set(0.05, forKey: "watchDebounce")

        let rel = "cfg.json"
        try env.write(rel, "{\"v\":0}")
        let p = env.path(rel)
        let events = Events()
        let w = makeWatcher(events)
        defer { w.unwatchAll() }
        w.watch([p])
        try await Task.sleep(for: .milliseconds(300))

        // two atomic-save cycles back to back
        for i in 1...2 {
            let tmp = env.home.appendingPathComponent(".\(rel).tmp\(i)")
            try "{\"v\":\(i)}".write(to: tmp, atomically: false, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(
                URL(fileURLWithPath: p), withItemAt: tmp)
            try await Task.sleep(for: .milliseconds(300))
        }
        #expect(await events.contains(p))
    }

    /// Deletion followed by recreation must both be observed.
    @Test func deleteThenRecreateIsObserved() async throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        AppSettings.defaults.set(0.05, forKey: "watchDebounce")

        let rel = "cfg.json"
        try env.write(rel, "a")
        let p = env.path(rel)
        let events = Events()
        let counts = LockedBox()
        let w = makeWatcher(events, counts: counts)
        defer { w.unwatchAll() }
        w.watch([p])
        try await Task.sleep(for: .milliseconds(300))
        #expect(counts.get() == 1)

        try FileManager.default.removeItem(atPath: p)
        try await Task.sleep(for: .milliseconds(300))
        #expect(counts.get() == 0)

        try env.write(rel, "b")   // recreated later — backoff re-attaches
        try await Task.sleep(for: .milliseconds(1500))
        #expect(counts.get() == 1)
        #expect(await events.contains(p))
    }

    /// Removed paths stop producing events and stop being retried.
    @Test func unwatchedPathsGoSilent() async throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        AppSettings.defaults.set(0.05, forKey: "watchDebounce")

        try env.write("a.json", "1")
        let pa = env.path("a.json")
        let pb = env.path("b.json")   // missing — would be retried forever
        let events = Events()
        let counts = LockedBox()
        let w = makeWatcher(events, counts: counts)
        defer { w.unwatchAll() }
        w.watch([pa, pb])
        try await Task.sleep(for: .milliseconds(400))
        #expect(counts.get() == 1)    // only the existing file attached

        w.watch([])                  // drop everything
        try env.write("a.json", "2")
        try env.write("b.json", "3")
        try await Task.sleep(for: .milliseconds(400))
        #expect(counts.get() == 0)
        #expect(await events.paths.isEmpty)
    }
}

}
