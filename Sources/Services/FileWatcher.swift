import Foundation

/// Watches files (and directories) with DispatchSource vnode events.
/// Debounces bursts and re-attaches after atomic-save rename cycles.
/// Thread-safe: all state is touched only on the serial `queue`; the
/// `onChange` callback hops to main.
final class FileWatcher: @unchecked Sendable {
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: [String: DispatchWorkItem] = [:]
    private let queue = DispatchQueue(label: "agentsconfig.watcher", qos: .utility)
    var onChange: @Sendable (String) -> Void

    init(onChange: @escaping @Sendable (String) -> Void) {
        self.onChange = onChange
    }

    func watch(_ paths: [String]) {
        queue.async {
            let wanted = Set(paths)
            for path in self.sources.keys where !wanted.contains(path) {
                self.sources[path]?.cancel()
                self.sources.removeValue(forKey: path)
            }
            for path in wanted where self.sources[path] == nil {
                self.attach(path)
            }
        }
    }

    func unwatchAll() {
        queue.async {
            for (_, s) in self.sources { s.cancel() }
            self.sources.removeAll()
        }
    }

    private func attach(_ path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .attrib, .extend, .link],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.handleEvent(path: path, flags: src.data)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        sources[path] = src
    }

    private func handleEvent(path: String, flags: DispatchSource.FileSystemEvent) {
        if flags.contains(.delete) || flags.contains(.rename) {
            // Atomic saves replace the file — the fd now points at the old inode.
            sources[path]?.cancel()
            sources.removeValue(forKey: path)
            queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.attach(path)
                self?.schedule(path)
            }
            return
        }
        schedule(path)
    }

    private func schedule(_ path: String) {
        pending[path]?.cancel()
        let handler = onChange
        let work = DispatchWorkItem { [weak self] in
            self?.pending.removeValue(forKey: path)
            DispatchQueue.main.async { handler(path) }
        }
        pending[path] = work
        queue.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}
