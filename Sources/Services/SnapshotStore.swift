import Foundation
import CryptoKit

/// Persists per-file version history under
/// ~/Library/Application Support/AgentsConfig/History/<sanitized-path>/
/// Each version = content file + entry in index.json.
struct SnapshotStore {

    struct IndexEntry: Codable {
        var ts: TimeInterval
        var hash: String
        var file: String
        var origin: String
        var changeCount: Int
        var summary: String
    }

    private var root: URL {
        return AppPaths.applicationSupport
            .appendingPathComponent("AgentsConfig/History", isDirectory: true)
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func dir(for path: String) -> URL {
        let safe = path.replacingOccurrences(of: "/", with: "__")
        return root.appendingPathComponent(safe, isDirectory: true)
    }

    func loadHistory(for path: String) -> [FileVersion] {
        let indexURL = dir(for: path).appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: indexURL),
              let entries = try? JSONDecoder().decode([IndexEntry].self, from: data)
        else { return [] }
        return entries.map {
            FileVersion(
                date: Date(timeIntervalSince1970: $0.ts),
                hash: $0.hash, file: $0.file,
                origin: FileVersion.Origin(rawValue: $0.origin) ?? .external,
                changeCount: $0.changeCount, summary: $0.summary
            )
        }.sorted { $0.date > $1.date }
    }

    func content(for path: String, version: FileVersion) -> String? {
        let url = dir(for: path).appendingPathComponent(version.file)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Latest stored content for a path (used to build baseline diffs on first load).
    func latestContent(for path: String) -> (String, FileVersion)? {
        guard let v = loadHistory(for: path).first,
              let c = content(for: path, version: v) else { return nil }
        return (c, v)
    }

    @discardableResult
    @MainActor
    func record(path: String, content: String, origin: FileVersion.Origin,
                changes: [SemanticChange]) -> FileVersion? {
        let dir = dir(for: path)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hash = Self.sha256(content)

        var entries = loadIndex(for: path)
        if entries.last?.hash == hash { return nil }  // identical to last snapshot

        let ts = Date().timeIntervalSince1970
        let filename = "\(Int(ts))-\(hash.prefix(8)).txt"
        do {
            try content.write(to: dir.appendingPathComponent(filename),
                              atomically: true, encoding: .utf8)
        } catch { return nil }

        let entry = IndexEntry(
            ts: ts, hash: hash, file: filename, origin: origin.rawValue,
            changeCount: changes.count, summary: DiffEngine.summary(changes)
        )
        entries.append(entry)
        while entries.count > AppSettings.historyLimit {   // ring buffer
            let drop = entries.removeFirst()
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(drop.file))
        }
        saveIndex(entries, for: path)
        return FileVersion(date: Date(timeIntervalSince1970: ts), hash: hash,
                           file: filename, origin: origin,
                           changeCount: changes.count, summary: entry.summary)
    }

    private func loadIndex(for path: String) -> [IndexEntry] {
        let url = dir(for: path).appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: url),
              let e = try? JSONDecoder().decode([IndexEntry].self, from: data) else { return [] }
        return e
    }

    private func saveIndex(_ entries: [IndexEntry], for path: String) {
        let url = dir(for: path).appendingPathComponent("index.json")
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
