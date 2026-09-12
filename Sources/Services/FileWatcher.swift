import Foundation

/// Watches files (and directories) with DispatchSource vnode events.
/// Debounces bursts and re-attaches after atomic-save rename cycles.
///
/// Recovery policy: a path that can't be opened (missing file, atomic-save
/// gap, temporary failure) is retried with exponential backoff (150ms → 15s
/// cap) for as long as it stays in the wanted set — late creation is picked
/// up without a full refresh. Paths dropped from the wanted set are never
/// retried again. `onAttachedCount` reports the *real* number of attached
/// sources.
///
/// Thread-safe: all state is touched only on the serial `queue`; the
/// `onChange` callback hops to main.
final class FileWatcher: @unchecked Sendable {
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: [String: DispatchWorkItem] = [:]
    private var retryWork: [String: DispatchWorkItem] = [:]
    private var retryAttempts: [String: Int] = [:]
    private var wanted: Set<String> = []
    private var observations: [String: UUID] = [:]
    private var gates: [String: DeliveryGate] = [:]
    private var attachments: [String: UUID] = [:]
    private var deliveries: [String: UUID] = [:]
    private let queue = DispatchQueue(label: "agentsconfig.watcher", qos: .utility)
    private let deliver: @Sendable (@escaping @Sendable () -> Void) -> Void
    private var debounce: TimeInterval
    var onChange: @Sendable (String) -> Void
    /// Fired on `queue` whenever the set of attached sources changes.
    var onAttachedCount: (@Sendable (Int) -> Void)?

    /// Cancellation and starting a callback are mutually exclusive. The
    /// barrier waits for a callback already in progress instead of racing it.
    private final class DeliveryGate: @unchecked Sendable {
        private let lock = NSRecursiveLock()
        private var active = true
        func cancel() { lock.lock(); active = false; lock.unlock() }
        func run(_ action: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            if active { action() }
        }
    }

    init(debounce: TimeInterval = AppSettings.watchDebounce,
         deliver: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         onChange: @escaping @Sendable (String) -> Void) {
        self.debounce = debounce
        self.deliver = deliver
        self.onChange = onChange
    }

    deinit {
        for source in sources.values { source.cancel() }
        for work in pending.values { work.cancel() }
        for work in retryWork.values { work.cancel() }
    }

    /// After this barrier, removed observations cannot begin another callback.
    /// A callback that already began may finish; delivery normally runs on main.
    func synchronize() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    /// Injects a filesystem notification without relying on kernel timing.
    /// Used by cancellation tests; follows the same debounce path as vnode events.
    func signalChange(_ path: String) {
        queue.async { self.schedule(path) }
    }

    func setDebounce(_ interval: TimeInterval) {
        queue.async { self.debounce = max(0.01, interval) }
    }

    func watch(_ paths: [String]) {
        queue.async {
            self.wanted = Set(paths)
            for path in self.observations.keys where !self.wanted.contains(path) {
                self.observations.removeValue(forKey: path)
                self.gates.removeValue(forKey: path)?.cancel()
                self.attachments.removeValue(forKey: path)
                self.deliveries.removeValue(forKey: path)
                self.pending.removeValue(forKey: path)?.cancel()
            }
            for path in self.wanted where self.observations[path] == nil {
                self.observations[path] = UUID()
                self.gates[path] = DeliveryGate()
            }
            for path in self.sources.keys where !self.wanted.contains(path) {
                self.sources[path]?.cancel()
                self.sources.removeValue(forKey: path)
            }
            for path in self.retryWork.keys where !self.wanted.contains(path) {
                self.retryWork[path]?.cancel()
                self.retryWork.removeValue(forKey: path)
                self.retryAttempts.removeValue(forKey: path)
            }
            for path in self.wanted where self.sources[path] == nil {
                self.attach(path, notify: false)
            }
            self.publishCount()
        }
    }

    func unwatchAll() {
        watch([])
    }

    private func publishCount() {
        onAttachedCount?(sources.count)
    }

    /// `notify` emits a change event after a successful attach — used by the
    /// retry path, where the file just appeared/reappeared and its content
    /// may differ from what we last saw.
    private func attach(_ path: String, notify: Bool) {
        guard wanted.contains(path), sources[path] == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            scheduleRetry(path)
            return
        }
        retryAttempts[path] = 0
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .attrib, .extend, .link],
            queue: queue
        )
        let attachment = UUID()
        attachments[path] = attachment
        src.setEventHandler { [weak self] in
            guard self?.attachments[path] == attachment else { return }
            self?.handleEvent(path: path, flags: src.data)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        sources[path] = src
        publishCount()
        if notify { schedule(path) }
    }

    private func handleEvent(path: String, flags: DispatchSource.FileSystemEvent) {
        if flags.contains(.delete) || flags.contains(.rename) {
            // Atomic saves replace the file — the fd now points at the old
            // inode. Re-attach with backoff until the path is stable again.
            sources[path]?.cancel()
            sources.removeValue(forKey: path)
            attachments.removeValue(forKey: path)
            publishCount()
            retryAttempts[path] = 0
            scheduleRetry(path)
            schedule(path)
            return
        }
        schedule(path)
    }

    /// Exponential backoff, 150ms → 15s cap, while the path stays wanted.
    /// This is what picks up late-created files and closed atomic-save gaps.
    private func scheduleRetry(_ path: String) {
        guard wanted.contains(path), retryWork[path] == nil else { return }
        let observation = observations[path]
        let attempt = (retryAttempts[path] ?? 0) + 1
        retryAttempts[path] = attempt
        let delay = min(0.15 * pow(2.0, Double(attempt)), 15.0)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.observations[path] == observation else { return }
            self.retryWork.removeValue(forKey: path)
            guard self.wanted.contains(path), self.sources[path] == nil else { return }
            self.attach(path, notify: true)
        }
        retryWork[path] = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func schedule(_ path: String) {
        guard let observation = observations[path], let gate = gates[path] else { return }
        pending[path]?.cancel()
        let delivery = UUID()
        deliveries[path] = delivery
        let handler = onChange
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.observations[path] == observation,
                  self.deliveries[path] == delivery else { return }
            self.pending.removeValue(forKey: path)
            self.deliver { [weak self] in
                guard let self else { return }
                let active = self.queue.sync {
                    self.observations[path] == observation && self.deliveries[path] == delivery
                }
                if active { gate.run { handler(path) } }
            }
        }
        pending[path] = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
