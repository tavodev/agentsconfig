import Foundation
import CryptoKit

/// Per-file snapshot history under
/// `~/Library/Application Support/AgentsConfig/History` (or the
/// `AGENTSCONFIG_HOME` equivalent in test/demo runs).
///
/// Layout (index format 2):
///   History/<sha256(canonical tracked path)>/   0700
///     index.json      {"format":2,"path":…,"entries":[…]}   0600
///     .index.lock     flock for cross-instance index ops
///     objects/<sha256(content)>                 0600, deduplicated blobs
///
/// Identity: every version has a UUID `id`, independent of timestamp and
/// content — A→B→A inside one second stays three distinct, recoverable
/// versions. Content is content-addressed and shared between entries; the
/// GC only deletes a blob when no surviving entry references it.
///
/// Path identity: the *tracked* path spelling, standardized — symlinks are
/// never resolved, so history survives delete/recreate cycles (writes go
/// through to the real target anyway, see AtomicWriter). Two different
/// spellings of the same file get separate histories.
///
/// Legacy dirs (path with "/"→"__") are migrated lazily and never
/// destructively: they are renamed `*.migrated` only after the new index
/// verifies. A legacy dir shared by two colliding spellings is ambiguous —
/// it is kept untouched and surfaced as an error instead of being guessed.
struct SnapshotStore {

    enum HistoryError: LocalizedError {
        case corruptIndex(String)
        case ambiguousLegacy(legacy: String, alternate: String)
        case cannotLock(String)
        case changedDuringReview
        case incompleteRemoval(String)

        var errorDescription: String? {
            switch self {
            case .corruptIndex(let p):
                return "History index is corrupt: \(p)"
            case .ambiguousLegacy(let l, let alt):
                return "Ambiguous legacy history \(l) — also maps to \(alt)"
            case .cannotLock(let p):
                return "Cannot lock history index: \(p)"
            case .changedDuringReview:
                return "History changed during review. Review the removal again."
            case .incompleteRemoval(let error):
                return "History entries were updated, but content cleanup failed: \(error)"
            }
        }
    }

    struct IndexEntry: Codable {
        var id: String
        var ts: TimeInterval
        var hash: String
        var file: String          // content blob name (= hash, format 2)
        var origin: String
        var changeCount: Int
        var summary: String

        init(id: String = UUID().uuidString, ts: TimeInterval, hash: String,
             file: String, origin: String, changeCount: Int, summary: String) {
            self.id = id; self.ts = ts; self.hash = hash; self.file = file
            self.origin = origin; self.changeCount = changeCount
            self.summary = summary
        }

        // Tolerant decode: format-1 entries carry no `id`.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
            ts = try c.decode(TimeInterval.self, forKey: .ts)
            hash = try c.decode(String.self, forKey: .hash)
            file = try c.decode(String.self, forKey: .file)
            origin = try c.decode(String.self, forKey: .origin)
            changeCount = (try? c.decode(Int.self, forKey: .changeCount)) ?? 0
            summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        }
    }

    private struct IndexFile: Codable {
        var format: Int           // 2
        var path: String          // canonical path this index belongs to
        var entries: [IndexEntry]
    }

    private let root: URL
    private let permissionBoundary: URL
    var now: () -> Date
    var historyLimit: () -> Int
    var writeIndexFile: (Data, URL) throws -> Void = { try AtomicWriter.write($0, to: $1) }
    var removeContentFile: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    /// Whether a path is a known config file — used to detect legacy
    /// dir-name ambiguity during migration. Defaults to on-disk existence.
    var isPathTracked: (String) -> Bool

    init(root: URL? = nil,
         permissionBoundary: URL? = nil,
         now: @escaping () -> Date = Date.init,
         historyLimit: @escaping () -> Int = { AppSettings.historyLimit },
         isPathTracked: ((String) -> Bool)? = nil) {
        self.root = root ?? AppPaths.applicationSupport
            .appendingPathComponent("AgentsConfig/History", isDirectory: true)
        self.permissionBoundary = permissionBoundary ?? AppPaths.applicationSupport
        self.now = now
        self.historyLimit = historyLimit
        self.isPathTracked = isPathTracked
            ?? { FileManager.default.fileExists(atPath: $0) }
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Canonical document identity: the tracked spelling with `.`/`..`
    /// collapsed. Symlinks are intentionally *not* resolved — identity must
    /// be stable across existence flips (delete → recreate).
    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Unique, collision-free per-document history directory name.
    static func historyDirName(for path: String) -> String {
        sha256(canonicalPath(path))
    }

    private func dir(for path: String) -> URL {
        root.appendingPathComponent(Self.historyDirName(for: path), isDirectory: true)
    }
    private func objectsDir(_ dir: URL) -> URL {
        dir.appendingPathComponent("objects", isDirectory: true)
    }
    private func indexURL(_ dir: URL) -> URL {
        dir.appendingPathComponent("index.json")
    }

    /// History dirs/files are ours: create 0700 and tighten the chain up to
    /// (but not including) "Application Support", which other apps share.
    private func ensurePrivateTree(_ dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        var u = dir.deletingLastPathComponent()
        let stopPath = permissionBoundary.path
        while u.path.hasPrefix(stopPath + "/") {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: u.path)
            u = u.deletingLastPathComponent()
        }
    }

    /// One-time audit for history written before private modes were enforced.
    /// Only touches paths under this store's root; deletes nothing.
    /// Returns the paths it could not secure.
    @discardableResult
    func secureExistingPermissions() -> [String] {
        let fm = FileManager.default
        var failed: [String] = []
        guard fm.fileExists(atPath: root.path),
              let enumerator = fm.enumerator(
                  at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return failed }
        var targets: [(url: URL, isDir: Bool)] = [(root, true)]
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            targets.append((url, isDir))
        }
        for t in targets {
            do {
                try fm.setAttributes(
                    [.posixPermissions: NSNumber(value: t.isDir ? 0o700 : 0o600)],
                    ofItemAtPath: t.url.path)
            } catch {
                failed.append(t.url.path)
            }
        }
        return failed
    }

    // MARK: - reads

    /// Newest first. Throws on a corrupt or foreign index — a corrupt index
    /// must never be treated as an empty history that may be overwritten.
    func loadHistory(for path: String) throws -> [FileVersion] {
        let dir = dir(for: path)
        try ensurePrivateTree(dir)
        let entries = try withIndexLock(dir) {
            try migrateIfNeeded(for: path)
            return try loadIndex(for: path)
        }
        let sorted = entries.enumerated().sorted { lhs, rhs in
            lhs.element.ts == rhs.element.ts
                ? lhs.offset > rhs.offset
                : lhs.element.ts > rhs.element.ts
        }
        return sorted.map { pair in
            let e = pair.element
            return FileVersion(id: e.id,
                               date: Date(timeIntervalSince1970: e.ts),
                               hash: e.hash, file: e.file,
                               origin: FileVersion.Origin(rawValue: e.origin) ?? .external,
                               changeCount: e.changeCount, summary: e.summary)
        }
    }

    func content(for path: String, version: FileVersion) -> String? {
        // path-escape protection: only content-addressed blob names are read
        guard isValidBlobName(version.file), version.file == version.hash
        else { return nil }
        let url = objectsDir(dir(for: path)).appendingPathComponent(version.file)
        guard let text = readRegularContent(url), Self.sha256(text) == version.hash else { return nil }
        return text
    }

    private func readRegularContent(_ url: URL) -> String? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Latest snapshot for restore-UI affordances.
    func latestContent(for path: String) -> (content: String, version: FileVersion)? {
        guard let v = try? loadHistory(for: path).first,
              let c = content(for: path, version: v) else { return nil }
        return (c, v)
    }

    // MARK: - record

    /// Publish the reduced index before removing unreferenced objects. The
    /// reviewed ID set must still match; newly recorded versions are never
    /// removed under an earlier purge confirmation. Legacy backups stay intact.
    func removeVersions(for path: String, ids: Set<String>, expectedIDs: Set<String>) throws {
        let directory = dir(for: path)
        try ensurePrivateTree(directory)
        try withIndexLock(directory) {
            try migrateIfNeeded(for: path)
            let entries = try loadIndex(for: path)
            guard Set(entries.map(\.id)) == expectedIDs, ids.isSubset(of: expectedIDs) else {
                throw HistoryError.changedDuringReview
            }
            let remaining = entries.filter { !ids.contains($0.id) }
            try saveIndex(remaining, for: path)
            try cleanupObjects(in: directory, retained: Set(remaining.map(\.file)))
        }
    }

    /// Retry physical cleanup against the current locked index. New references
    /// remain protected even if more versions were recorded after an error.
    func cleanupOrphans(for path: String) throws {
        let directory = dir(for: path)
        try ensurePrivateTree(directory)
        try withIndexLock(directory) {
            try migrateIfNeeded(for: path)
            let entries = try loadIndex(for: path)
            try cleanupObjects(in: directory, retained: Set(entries.map(\.file)))
        }
    }

    private func cleanupObjects(in directory: URL, retained: Set<String>) throws {
        let objects = objectsDir(directory)
        guard FileManager.default.fileExists(atPath: objects.path) else { return }
        var failure: Error?
        for name in try FileManager.default.contentsOfDirectory(atPath: objects.path)
            where isValidBlobName(name) && !retained.contains(name) {
            let url = objects.appendingPathComponent(name)
            do {
                let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
                guard type == .typeRegular || type == .typeSymbolicLink else { continue }
                try removeContentFile(url)
            } catch { failure = error }
        }
        if let failure { throw HistoryError.incompleteRemoval(failure.localizedDescription) }
    }

    /// Records a snapshot. Throws on any storage failure — a missing backup
    /// must be able to abort the caller's write (F2). Returns nil only when
    /// the content is identical to the newest snapshot.
    @discardableResult
    func record(path: String, content: String, origin: FileVersion.Origin,
                changes: [SemanticChange]) throws -> FileVersion? {
        let dir = dir(for: path)
        try ensurePrivateTree(dir)
        return try withIndexLock(dir) {
            try migrateIfNeeded(for: path)
            var entries = try loadIndex(for: path)
            let hash = Self.sha256(content)

            // write the content blob first — an index entry must never
            // reference content that doesn't exist on disk
            let objects = objectsDir(dir)
            try ensurePrivateTree(objects)
            let blob = objects.appendingPathComponent(hash)
            if !FileManager.default.fileExists(atPath: blob.path) {
                try AtomicWriter.write(content, to: blob)
            }
            guard readRegularContent(blob) == content else {
                throw HistoryError.corruptIndex(indexURL(dir).path)
            }
            if entries.last?.hash == hash { return nil }

            let ts = now().timeIntervalSince1970
            let entry = IndexEntry(ts: ts, hash: hash, file: hash,
                                   origin: origin.rawValue,
                                   changeCount: changes.count,
                                   summary: DiffEngine.storageSummary(changes))
            entries.append(entry)
            var dropped = Set<String>()
            let limit = max(1, historyLimit())
            while entries.count > limit {   // ring buffer
                dropped.insert(entries.removeFirst().file)
            }
            try saveIndex(entries, for: path)
            let retained = Set(entries.map(\.file))
            for file in dropped.subtracting(retained) where isValidBlobName(file) {
                try? removeContentFile(objects.appendingPathComponent(file))
            }
            return FileVersion(id: entry.id,
                               date: Date(timeIntervalSince1970: ts),
                               hash: hash, file: hash, origin: origin,
                               changeCount: changes.count, summary: entry.summary)
        }
    }

    /// Serialize index read-modify-write across processes via flock.
    private func withIndexLock<T>(_ dir: URL, _ body: () throws -> T) throws -> T {
        let lock = dir.appendingPathComponent(".index.lock")
        let fd = open(lock.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw HistoryError.cannotLock(lock.path) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw HistoryError.cannotLock(lock.path) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func loadIndex(for path: String) throws -> [IndexEntry] {
        let url = indexURL(dir(for: path))
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url),
              let idx = try? JSONDecoder().decode(IndexFile.self, from: data),
              idx.format == 2,
              idx.path == Self.canonicalPath(path)
        else { throw HistoryError.corruptIndex(url.path) }
        return idx.entries
    }

    private func saveIndex(_ entries: [IndexEntry], for path: String) throws {
        let idx = IndexFile(format: 2, path: Self.canonicalPath(path),
                            entries: entries)
        try writeIndexFile(try JSONEncoder().encode(idx), indexURL(dir(for: path)))
    }

    private func isValidBlobName(_ name: String) -> Bool {
        name.count == 64 && name.allSatisfy(\.isHexDigit)
    }

    private func isValidLegacyContentName(_ name: String) -> Bool {
        name.hasSuffix(".txt") && !name.contains("/") && !name.contains("..")
    }

    // MARK: - legacy migration (format 1 → 2)

    /// Migrates a legacy `__`-sanitized dir into the hashed layout if one
    /// exists and no format-2 dir is present yet.
    private func migrateIfNeeded(for path: String) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let newDir = dir(for: path)
        if fm.fileExists(atPath: indexURL(newDir).path) {
            _ = try loadIndex(for: path)
            return
        }

        let legacyName = path.replacingOccurrences(of: "/", with: "__")
        let legacyDir = root.appendingPathComponent(legacyName, isDirectory: true)
        guard fm.fileExists(atPath: legacyDir.path, isDirectory: &isDir),
              isDir.boolValue else { return }

        // Ambiguity: another existing/tracked spelling may share this dir.
        guard legacyName.components(separatedBy: "__").count <= 13 else {
            throw HistoryError.ambiguousLegacy(legacy: legacyName, alternate: "too many possible paths")
        }
        for alt in legacyAlternates(legacyName) {
            let altPath = Self.canonicalPath(alt)
            if altPath != Self.canonicalPath(path), isPathTracked(altPath) {
                throw HistoryError.ambiguousLegacy(legacy: legacyName,
                                                   alternate: altPath)
            }
        }

        guard let data = try? Data(contentsOf:
                                    legacyDir.appendingPathComponent("index.json")),
              let legacy = try? JSONDecoder().decode([IndexEntry].self, from: data)
        else {
            throw HistoryError.corruptIndex(
                legacyDir.appendingPathComponent("index.json").path)
        }

        try ensurePrivateTree(newDir)
        let objects = objectsDir(newDir)
        try ensurePrivateTree(objects)

        var entries: [IndexEntry] = []
        for e in legacy {
            guard isValidLegacyContentName(e.file),
                  let text = readRegularContent(legacyDir.appendingPathComponent(e.file)) else {
                throw HistoryError.corruptIndex(legacyDir.appendingPathComponent("index.json").path)
            }
            let hash = Self.sha256(text)
            let blob = objects.appendingPathComponent(hash)
            if !fm.fileExists(atPath: blob.path) {
                try AtomicWriter.write(text, to: blob)
            }
            guard readRegularContent(blob) == text else {
                throw HistoryError.corruptIndex(indexURL(newDir).path)
            }
            entries.append(IndexEntry(ts: e.ts, hash: hash, file: hash,
                                      origin: e.origin,
                                      changeCount: e.changeCount,
                                      summary: e.summary))
        }
        try saveIndex(entries, for: path)

        // verify the migrated index before touching the legacy tree
        _ = try loadIndex(for: path)
        try? fm.moveItem(
            at: legacyDir,
            to: root.appendingPathComponent(legacyName + ".migrated",
                                            isDirectory: true))
    }

    /// All path spellings that sanitize to the same legacy dir name: each
    /// "__" separator may be a literal "__" or a "/" join.
    private func legacyAlternates(_ legacyName: String) -> [String] {
        let parts = legacyName.components(separatedBy: "__")
        guard parts.count > 1, parts.count <= 13 else { return [] }
        var out: [String] = []
        for mask in 0..<(1 << (parts.count - 1)) {
            var s = parts[0]
            for i in 1..<parts.count {
                s += ((mask >> (i - 1)) & 1) == 1 ? "/" : "__"
                s += parts[i]
            }
            out.append(s)
        }
        return out
    }
}
