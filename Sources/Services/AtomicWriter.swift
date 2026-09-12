import Foundation

/// Atomic file writes with strict permissions and a defined symlink policy.
///
/// - Writes go *through* symlinks to the real target: a symlinked config is
///   edited in place and the link is preserved — never silently replaced by
///   a plain file. New files under a symlinked directory land in the real
///   directory.
/// - The temp file is created `O_CREAT|O_EXCL` with mode 0600 inside the
///   target directory (same filesystem → the final rename is atomic) and is
///   removed on any failure. Only temp files created by the operation are
///   removed.
/// - Error messages carry the failing path/errno only — never file content.
enum AtomicWriter {

    struct WriteFailure: Error, LocalizedError {
        let operation: String
        let path: String
        let errnoCode: Int32
        var errorDescription: String? {
            "\(operation) \(URL(fileURLWithPath: path).lastPathComponent): "
                + String(cString: strerror(errnoCode))
        }
    }

    /// Resolves `url` to the real location on disk: existing paths go through
    /// realpath (following a final-component symlink); for new files the
    /// parent directory is resolved instead.
    static func resolvedURL(_ url: URL) throws -> URL {
        if let real = realURL(of: url) { return real }
        let resolutionError = errno
        // realpath also fails for dangling links and cycles. Only a genuinely
        // absent final component may be created; lstat must not follow links.
        var info = stat()
        if lstat(url.path, &info) == 0 {
            throw WriteFailure(operation: "resolve target", path: url.path,
                               errnoCode: resolutionError)
        }
        let lookupError = errno
        guard lookupError == ENOENT else {
            throw WriteFailure(operation: "inspect target", path: url.path,
                               errnoCode: lookupError)
        }
        guard let realDir = realURL(of: url.deletingLastPathComponent()) else {
            throw WriteFailure(operation: "resolve parent", path: url.path,
                               errnoCode: errno)
        }
        return realDir.appendingPathComponent(url.lastPathComponent)
    }

    private static func realURL(of url: URL) -> URL? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buf) != nil else { return nil }
        return URL(fileURLWithPath: String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    /// Atomically creates or replaces `url` with `data`, applying
    /// `permissions` to the new file before it is moved into place.
    static func write(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        let target = try resolvedURL(url)
        let tmp = target.deletingLastPathComponent().appendingPathComponent(
            ".\(target.lastPathComponent).acfg-tmp-\(UUID().uuidString)")
        do {
            try createAndWrite(data, to: tmp)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: permissions)],
                ofItemAtPath: tmp.path)
            guard rename(tmp.path, target.path) == 0 else {
                throw WriteFailure(operation: "rename",
                                   path: target.path, errnoCode: errno)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    static func write(_ text: String, to url: URL,
                      permissions: Int = 0o600) throws {
        try write(Data(text.utf8), to: url, permissions: permissions)
    }

    /// Atomic text write that preserves the destination's POSIX permissions;
    /// files that don't exist yet get a private 0600 default.
    static func writePreservingPermissions(_ text: String, toPath path: String) throws {
        let target = try resolvedURL(URL(fileURLWithPath: path))
        var perms = 0o600
        if let attrs = try? FileManager.default.attributesOfItem(atPath: target.path),
           let p = attrs[.posixPermissions] as? NSNumber {
            perms = p.intValue
        }
        try write(Data(text.utf8), to: target, permissions: perms)
    }

    private static func createAndWrite(_ data: Data, to tmp: URL) throws {
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw WriteFailure(operation: "create temp",
                               path: tmp.path, errnoCode: errno)
        }
        // closeOnDealloc covers early throws from write(contentsOf:)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
    }
}
