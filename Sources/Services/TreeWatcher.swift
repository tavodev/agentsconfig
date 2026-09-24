import Foundation
import CoreServices

/// Watches whole directory trees with a single FSEvents stream.
///
/// Replaces one vnode descriptor per directory: thousands of project and
/// skill folders used to exhaust `RLIMIT_NOFILE` (see `FileWatcher`), and
/// every entry change in any of them triggered a full rescan. FSEvents costs
/// no descriptor per folder and reports per-item flags, so callers can react
/// only to structural changes (entries created, removed or renamed).
///
/// FSEvents reports resolved paths; events are translated back to the root
/// spelling the caller registered, so they match tracked-path strings.
final class TreeWatcher: @unchecked Sendable {
    struct Event: Sendable, Equatable {
        var path: String
        var isDirectory: Bool
        /// Created, removed or renamed — not a content or metadata edit.
        var structural: Bool
        /// The kernel coalesced or dropped detail; the tree must be rescanned.
        var mustRescan: Bool
    }

    private let queue = DispatchQueue(label: "agentsconfig.treewatcher", qos: .utility)
    private var stream: FSEventStreamRef?
    /// Retained by the stream context; the weak hop means a callback racing
    /// deinit finds nil instead of a freed watcher.
    private final class Box { weak var watcher: TreeWatcher? }
    private var box: Unmanaged<Box>?
    private var roots: [String] = []
    /// Resolved root → registered spelling.
    private var aliases: [(resolved: String, given: String)] = []
    private let latency: TimeInterval
    /// Called on the watcher's queue with each coalesced batch.
    var onEvents: @Sendable ([Event]) -> Void

    init(latency: TimeInterval = AppSettings.watchDebounce,
         onEvents: @escaping @Sendable ([Event]) -> Void = { _ in }) {
        self.latency = max(0.01, latency)
        self.onEvents = onEvents
    }

    deinit { stopStream() }

    /// Smallest set of directories covering `paths`: a path whose ancestor
    /// is already listed adds nothing to a recursive stream. Ancestors are
    /// looked up by walking parents (shortest paths first), so siblings such
    /// as `/a-b` never break coverage of `/a/b` the way a sorted scan would.
    static func minimalRoots(_ paths: some Sequence<String>) -> [String] {
        var roots = Set<String>()
        for path in Set(paths).sorted(by: { $0.utf8.count < $1.utf8.count }) {
            var current = path, covered = false
            while let parent = DiscoveryTree.parent(current) {
                if roots.contains(parent) { covered = true; break }
                current = parent
            }
            if !covered { roots.insert(path) }
        }
        return roots.sorted(by: DiscoveryTree.byteOrder)
    }

    func watch(_ roots: [String]) {
        queue.async {
            guard roots != self.roots else { return }
            self.roots = roots
            self.stopStream()
            self.startStream()
        }
    }

    func stop() { watch([]) }

    /// Waits until previously requested `watch` calls have taken effect.
    func synchronize() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    private func startStream() {
        guard !roots.isEmpty else { return }
        aliases = roots.map { root in
            (URL(fileURLWithPath: root).resolvingSymlinksInPath().path, root)
        }.sorted { $0.resolved.count > $1.resolved.count }
        let holder = Box(); holder.watcher = self
        let retained = Unmanaged.passRetained(holder)
        var context = FSEventStreamContext(version: 0, info: retained.toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, Self.callback, &context,
                                               roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               latency, flags) else { retained.release(); return }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); retained.release(); return
        }
        self.stream = stream
        self.box = retained
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        box?.release(); box = nil
    }

    private func registeredSpelling(_ path: String) -> String {
        for alias in aliases where alias.resolved != alias.given {
            if path == alias.resolved { return alias.given }
            if path.hasPrefix(alias.resolved + "/") { return alias.given + path.dropFirst(alias.resolved.count) }
        }
        return path
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info, let watcher = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().watcher else { return }
        let list = unsafeBitCast(paths, to: NSArray.self)
        let structuralMask = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated
            | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
        let rescanMask = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagRootChanged)
        var events: [Event] = []
        events.reserveCapacity(count)
        for index in 0..<count {
            guard let raw = list[index] as? String else { continue }
            let flag = flags[index]
            var path = watcher.registeredSpelling(raw)
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            events.append(Event(path: path,
                                isDirectory: flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0,
                                structural: flag & structuralMask != 0,
                                mustRescan: flag & rescanMask != 0))
        }
        if !events.isEmpty { watcher.onEvents(events) }
    }
}
