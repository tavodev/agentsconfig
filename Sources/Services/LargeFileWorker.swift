import Foundation

/// Source-only processing for 2–16 MB files. All parsing and storage operations
/// here run outside MainActor. Results contain immutable Sendable values only.
actor LargeFileWorker {
    struct HistoryPolicy: Sendable {
        let root: URL
        let boundary: URL
        let enabled: Bool
        let limit: Int
        func store() -> SnapshotStore {
            SnapshotStore(root: root, permissionBoundary: boundary,
                          historyLimit: { limit }, isPathTracked: { FileManager.default.fileExists(atPath: $0) })
        }
    }
    enum Disk: Equatable, Sendable { case missing, content(String) }
    struct Loaded: Sendable {
        let text: String
        let hash: String
        let parseError: String?
        let historyError: String?
    }
    enum SaveResult: Sendable {
        case saved(Loaded)
        case conflict(Disk)
        case failed(String)
    }

    func versionContent(path: String, version: FileVersion, history: HistoryPolicy) -> String? {
        history.store().content(for: path, version: version)
    }

    func hash(_ text: String) -> String { SnapshotStore.sha256(text) }

    func read(_ path: String, format: ConfigFormat) throws -> Loaded {
        try Task.checkCancellation()
        let text = try Parsers.readText(at: path, limit: Parsers.maximumBackgroundBytes)
        let error = Parsers.parseInBackground(text, format: format).error
        try Task.checkCancellation()
        return Loaded(text: text, hash: SnapshotStore.sha256(text), parseError: error, historyError: nil)
    }

    func validate(_ text: String, format: ConfigFormat) throws -> String? {
        try Task.checkCancellation()
        return Parsers.parseInBackground(text, format: format).error
    }

    func disk(_ path: String) throws -> Disk {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        return .content(try Parsers.readText(at: path, limit: Parsers.maximumBackgroundBytes))
    }

    func load(_ path: String, format: ConfigFormat, previousHash: String?, history: HistoryPolicy) throws -> Loaded {
        let loaded = try read(path, format: format)
        var historyError: String?
        if history.enabled {
            do {
                let snapshots = history.store()
                let versions = try snapshots.loadHistory(for: path)
                if versions.isEmpty || versions.first?.hash != loaded.hash {
                    try Task.checkCancellation()
                    _ = try snapshots.record(path: path, content: loaded.text,
                        origin: versions.isEmpty ? .baseline : .external, changes: [])
                }
            } catch { historyError = error.localizedDescription }
        }
        return Loaded(text: loaded.text, hash: loaded.hash, parseError: loaded.parseError, historyError: historyError)
    }

    func save(_ path: String, proposed: String, format: ConfigFormat,
              expected: Disk, history: HistoryPolicy, origin: FileVersion.Origin = .app,
              draft: String? = nil) -> SaveResult {
        do {
            if let error = try validate(proposed, format: format) { return .failed(error) }
            let current = try disk(path)
            guard current == expected else { return .conflict(current) }
            let snapshots = history.store()
            if let draft {
                guard history.enabled else { return .failed("History is disabled; unsaved edits cannot be archived.") }
                _ = try snapshots.record(path: path, content: draft, origin: .app, changes: [])
            }
            if history.enabled, case .content(let old) = current, old != proposed {
                _ = try snapshots.record(path: path, content: old, origin: .app, changes: [])
            }
            try Task.checkCancellation()
            // Revalidate after a potentially slow backup. Still not filesystem CAS.
            let rechecked = try disk(path)
            guard rechecked == current else { return .conflict(rechecked) }
            try AtomicWriter.writePreservingPermissions(proposed, toPath: path)
            var historyError: String?
            if history.enabled {
                do { _ = try snapshots.record(path: path, content: proposed, origin: origin, changes: []) }
                catch { historyError = error.localizedDescription }
            }
            return .saved(Loaded(text: proposed, hash: SnapshotStore.sha256(proposed), parseError: nil, historyError: historyError))
        } catch { return .failed(error.localizedDescription) }
    }
}
