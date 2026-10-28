import Foundation
import CryptoKit

/// Root-wide encryption protocol. Every SnapshotStore operation takes this lock before any per-index lock.
struct HistoryEncryption {
    struct RootAbsent: Error {}
    static let markerName = ".encryption.json"
    static let header = Data("AgentsConfigHistoryAESGCM1\0".utf8)
    struct Status: Equatable, Sendable {
        let enabled: Bool
        let needsResume: Bool
        let keyID: String?
    }
    enum Failure: LocalizedError {
        case invalidMetadata, missingKey, keychainUnavailable, authenticationFailed, unexpectedPlaintext, migrationRequired, unsafePath, cannotLock
        var errorDescription: String? {
            switch self {
            case .invalidMetadata: "History encryption metadata is missing or invalid. No history was overwritten."
            case .missingKey: "The history encryption key is unavailable. Restore access to the original key; no new key was generated."
            case .keychainUnavailable: "The history encryption keychain is unavailable or access is denied."
            case .authenticationFailed: "Encrypted history could not be authenticated. No plaintext fallback was used."
            case .unexpectedPlaintext: "Unencrypted data was found in encrypted history. Writes are blocked until the problem is resolved."
            case .migrationRequired: "History encryption migration is incomplete. Retry it before writing history."
            case .unsafePath: "The history encryption operation encountered an unsafe path."
            case .cannotLock: "The history folder could not be locked for encryption."
            }
        }
    }
    private struct Marker: Codable {
        var format = 1
        var keyID: String
        var phase: String
        var authentication = ""
        var status: Status { .init(enabled: phase == "encrypted" || phase == "encrypting", needsResume: phase == "encrypting" || phase == "decrypting", keyID: keyID) }
        var authenticationInput: Data { Data("AgentsConfigHistoryMode1|\(format)|\(keyID)|\(phase)".utf8) }
    }
    let root: URL
    let keyProvider: any HistoryKeyProvider
    var writeMigrationFile: (Data, URL) throws -> Void = { try AtomicWriter.write($0, to: $1) }
    var onRepresentationScan: () -> Void = {}
    private struct ValidatedRepresentation {
        let fingerprint: String
        let encrypted: Bool
    }
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var validatedRoots: [String: ValidatedRepresentation] = [:]
    private var markerURL: URL { root.appendingPathComponent(Self.markerName) }
    static func type(_ url: URL) -> mode_t? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mode & S_IFMT : nil
    }
    func withRootLock<T>(create: Bool, _ body: () throws -> T) throws -> T {
        if Self.type(root) == nil {
            guard errno == ENOENT else { throw Failure.unsafePath }
            if !create { throw RootAbsent() }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard Self.type(root) == S_IFDIR else { throw SnapshotStore.HistoryError.unsafeHistoryRoot(root.path) }
        // Outside History: purge keeps its old plaintext contract and never unlinks the root lock.
        let lock = root.deletingLastPathComponent().appendingPathComponent("." + root.lastPathComponent + ".history.lock")
        let fd = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.cannotLock }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw Failure.cannotLock }
        defer { flock(fd, LOCK_UN) }
        var held = stat(), current = stat()
        guard fstat(fd, &held) == 0, held.st_mode & S_IFMT == S_IFREG,
              lstat(lock.path, &current) == 0, held.st_dev == current.st_dev, held.st_ino == current.st_ino,
              Self.type(root) == S_IFDIR else { throw Failure.cannotLock }
        return try body()
    }
    private func marker(verify: Bool = true) throws -> Marker? {
        guard let type = Self.type(markerURL) else {
            if errno == ENOENT { return nil }
            throw Failure.invalidMetadata
        }
        guard type == S_IFREG, let value = try? JSONDecoder().decode(Marker.self, from: rawRead(markerURL)),
              value.format == 1, UUID(uuidString: value.keyID) != nil,
              ["plain", "encrypted", "encrypting", "decrypting"].contains(value.phase) else { throw Failure.invalidMetadata }
        if verify {
            guard let code = Data(base64Encoded: value.authentication),
                  HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: value.authenticationInput, using: try modeAuthenticationKey(value)) else { throw Failure.invalidMetadata }
        }
        return value
    }
    private func save(_ marker: Marker) throws {
        var signed = marker
        signed.authentication = Data(HMAC<SHA256>.authenticationCode(for: marker.authenticationInput, using: try modeAuthenticationKey(marker))).base64EncodedString()
        try AtomicWriter.write(JSONEncoder().encode(signed), to: markerURL)
    }
    private func key(_ marker: Marker) throws -> SymmetricKey {
        guard let data = try keyProvider.loadKey(id: marker.keyID), data.count == 32 else { throw Failure.missingKey }
        return SymmetricKey(data: data)
    }
    private func modeAuthenticationKey(_ marker: Marker) throws -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: try key(marker), salt: Data("AgentsConfigHistoryEncryption1".utf8),
                              info: Data("AgentsConfigHistoryModeAuth1".utf8), outputByteCount: 32)
    }
    func status() throws -> Status {
        do {
            return try withRootLock(create: false) {
                guard let marker = try marker() else { return .init(enabled: false, needsResume: try !atomicTemps().isEmpty, keyID: nil) }
                if marker.phase != "plain" { _ = try key(marker) }
                let value = marker.status
                let interrupted = try !atomicTemps().isEmpty
                return .init(enabled: value.enabled, needsResume: value.needsResume || interrupted, keyID: value.keyID)
            }
        } catch is RootAbsent { return .init(enabled: false, needsResume: false, keyID: nil) }
    }
    func requireWritable() throws {
        guard let marker = try marker() else { try rejectOrphanedCiphertext(); return }
        guard !marker.status.needsResume else { throw Failure.migrationRequired }
        if marker.phase == "encrypted" {
            _ = try key(marker)
            try validateRepresentation(encrypted: true)
        } else { try rejectOrphanedCiphertext() }
    }
    private func rejectOrphanedCiphertext() throws {
        try validateRepresentation(encrypted: false)
    }
    private func validateRepresentation(encrypted: Bool) throws {
        guard Self.type(root) == S_IFDIR else { return }
        let before = try fingerprint()
        if Self.cacheLock.withLock({ Self.validatedRoots[root.path].map { $0.fingerprint == before && $0.encrypted == encrypted } ?? false }) { return }
        onRepresentationScan()
        for url in try regularFiles() {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.unsafePath }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            let envelope = try handle.read(upToCount: Self.header.count) == Self.header
            if encrypted && !envelope { throw Failure.unexpectedPlaintext }
            if !encrypted && envelope { throw Failure.invalidMetadata }
        }
        guard try fingerprint() == before else { throw Failure.unsafePath }
        rememberRepresentation(encrypted: encrypted, fingerprint: before)
    }
    private func fingerprint() throws -> String {
        func stamp(_ url: URL) throws -> String {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                if errno == ENOENT { return "absent" }
                throw Failure.unsafePath
            }
            return "\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        }
        return try stamp(root) + "|" + stamp(markerURL)
    }
    private func rememberRepresentation(encrypted: Bool, fingerprint: String) {
        Self.cacheLock.withLock {
            if Self.validatedRoots.count > 256 { Self.validatedRoots.removeAll() }
            Self.validatedRoots[root.path] = .init(fingerprint: fingerprint, encrypted: encrypted)
        }
    }
    /// Called after a successful operation while still holding the root lock. Only our encoded writes changed the tree.
    func didWrite() {
        do {
            let mode = try marker()
            guard mode?.status.needsResume != true else { return }
            rememberRepresentation(encrypted: mode?.status.enabled ?? false, fingerprint: try fingerprint())
        } catch {
            // A permission/key failure is never a reason to infer plaintext mode.
        }
    }
    func requireReadable() throws {
        if let marker = try marker(), marker.phase != "plain" { _ = try key(marker) }
    }
    private func associatedData(_ url: URL) throws -> Data {
        guard url.path.hasPrefix(root.path + "/") else { throw Failure.unsafePath }
        var components = String(url.path.dropFirst(root.path.count + 1)).components(separatedBy: "/")
        // The non-destructive legacy migration only renames this directory; bind both names to the same identity.
        while components.count > 1, components[0].hasSuffix(".migrated") { components[0] = String(components[0].dropLast(".migrated".count)) }
        return Self.header + Data(components.joined(separator: "/").utf8)
    }
    func rawRead(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unsafePath }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.unsafePath }
        return try handle.readToEnd() ?? Data()
    }
    func read(_ url: URL) throws -> Data {
        let data = try rawRead(url)
        let marker = try marker()
        if data.starts(with: Self.header) {
            guard let marker, marker.phase != "plain" else { throw Failure.invalidMetadata }
            do { return try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(Self.header.count)), using: key(marker), authenticating: associatedData(url)) }
            catch let error as Failure { throw error }
            catch { throw Failure.authenticationFailed }
        }
        if let marker, marker.phase == "encrypted" { throw Failure.unexpectedPlaintext }
        return data
    }
    func encoded(_ data: Data, for url: URL) throws -> Data {
        try requireWritable()
        guard let marker = try marker(), marker.phase == "encrypted" else { return data }
        return try Self.header + AES.GCM.seal(data, using: key(marker), authenticating: associatedData(url)).combined!
    }
    func setEnabled(_ enabled: Bool) throws {
        try withRootLock(create: true) {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            var current = try marker()
            try cleanupAtomicTemps()
            if current == nil {
                if !enabled { return }
                // Lost metadata must never generate a replacement key beside existing encrypted content.
                try rejectOrphanedCiphertext()
                let id = UUID().uuidString
                let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                try keyProvider.storeKey(data, id: id)
                current = Marker(keyID: id, phase: "plain")
            }
            var target = current!
            if target.status.needsResume {
                guard target.status.enabled == enabled else { throw Failure.migrationRequired }
            } else {
                if target.status.enabled == enabled { try requireWritable(); return }
                _ = try key(target) // Never regenerate a key referenced by existing metadata.
                target.phase = enabled ? "encrypting" : "decrypting"
                try save(target) // Publish transition before replacing the first content file.
            }
            let symmetric = try key(target)
            for url in try regularFiles(secureDirectories: true) {
                let existing = try rawRead(url)
                let encrypted = existing.starts(with: Self.header)
                if enabled {
                    if encrypted {
                        _ = try read(url) // Authenticate already migrated files before declaring success.
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    } else {
                        let sealed = try AES.GCM.seal(existing, using: symmetric, authenticating: associatedData(url))
                        try writeMigrationFile(Self.header + sealed.combined!, url)
                    }
                } else if encrypted {
                    let plaintext = try read(url)
                    try writeMigrationFile(plaintext, url)
                } else {
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
            }
            target.phase = enabled ? "encrypted" : "plain"
            try save(target)
            didWrite()
        }
    }
    func resume() throws {
        let value = try status()
        if value.needsResume { try setEnabled(value.enabled) }
    }
    /// AtomicWriter temps are never index/blob/legacy version names. An interrupted write may leave a partial
    /// envelope authenticated for the destination name, so recovery discards only this exact reserved form.
    private func atomicTemps() throws -> [URL] {
        var found: [URL] = []
        func reserved(_ name: String) -> Bool {
            guard name.hasPrefix("."), let range = name.range(of: ".acfg-tmp-", options: .backwards),
                  name.distance(from: name.startIndex, to: range.lowerBound) > 1 else { return false }
            let suffix = String(name[range.upperBound...])
            return suffix.count == 36 && UUID(uuidString: suffix) != nil
        }
        func visit(_ dir: URL) throws {
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
                let url = dir.appendingPathComponent(name)
                switch Self.type(url) {
                case S_IFDIR: try visit(url)
                case S_IFREG, S_IFLNK: if reserved(name) { found.append(url) }
                default: continue
                }
            }
        }
        try visit(root)
        return found
    }
    private func cleanupAtomicTemps() throws {
        let files = try atomicTemps()
        if !files.isEmpty { Self.cacheLock.withLock { _ = Self.validatedRoots.removeValue(forKey: root.path) } }
        for url in files {
            // unlink removes a reserved symlink itself, never its target.
            guard unlink(url.path) == 0 else { throw Failure.unsafePath }
        }
    }
    /// Symlinks are not traversed. Per-index locks and protocol metadata contain no user history.
    private func regularFiles(secureDirectories: Bool = false) throws -> [URL] {
        var result: [URL] = []
        func visit(_ directory: URL) throws {
            if secureDirectories { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() {
                if directory == root && name == Self.markerName { continue }
                let url = directory.appendingPathComponent(name)
                if name == ".index.lock" {
                    // Lock bytes have no data role and cannot be encrypted; refuse nonempty lock files instead of claiming them protected.
                    guard Self.type(url) == S_IFREG, try rawRead(url).isEmpty else { throw Failure.unsafePath }
                    continue
                }
                switch Self.type(url) {
                case S_IFDIR: try visit(url)
                case S_IFREG: result.append(url)
                case S_IFLNK: continue
                default: throw Failure.unsafePath
                }
            }
        }
        try visit(root)
        return result
    }
    /// Purging needs no decryption key; preserve key identity and finish the pending target mode with no remaining content.
    func didPurge() throws {
        // Purging content is useful even with damaged metadata: keep it intact and let status/normal writes report the error.
        guard var value = try? marker(verify: false), value.status.needsResume else { return }
        // Losing a key never prevents deletion; keep the transitional marker if it cannot be authenticated and re-signed.
        guard (try? key(value)) != nil else { return }
        guard (try? marker()) != nil else { return }
        value.phase = value.status.enabled ? "encrypted" : "plain"
        try save(value)
    }
}
