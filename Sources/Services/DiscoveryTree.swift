import Foundation

/// Shared bounded traversal. Never executes discovered content or crosses a
/// directory symlink. Callers may explicitly select a root that is itself linked.
enum DiscoveryTree {
    struct Result {
        var files: [String] = []
        var directories: [String] = []
        var truncated = false
        var skippedLinks = 0
        /// Every entry name (skipped ones included) of each listed directory,
        /// so callers can test for a child without another `stat`.
        var childNames: [String: Set<String>] = [:]
    }

    /// Memoizes scans for the duration of one `withCache` pass: a refresh
    /// resolves files, watch directories and project folders from the same
    /// trees, and each used to walk them again.
    final class Cache: @unchecked Sendable {
        struct Key: Hashable {
            var root: String, maxDepth: Int, maxDirectories: Int
            var skipNames: Set<String>, skipPaths: Set<String>
            var collectFiles: Bool
        }
        private let lock = NSLock()
        private var scans: [Key: Result] = [:]
        private var skillTrees: [String: (files: [String], directories: [String])] = [:]

        func scan(_ key: Key, _ make: () -> Result) -> Result {
            lock.lock(); let hit = scans[key]; lock.unlock()
            if let hit { return hit }
            let value = make()
            lock.lock(); scans[key] = value; lock.unlock()
            return value
        }
        func skillTree(_ root: String, _ make: () -> (files: [String], directories: [String])) -> (files: [String], directories: [String]) {
            lock.lock(); let hit = skillTrees[root]; lock.unlock()
            if let hit { return hit }
            let value = make()
            lock.lock(); skillTrees[root] = value; lock.unlock()
            return value
        }
    }
    @TaskLocal static var cache: Cache?

    static func withCache<T>(_ body: () throws -> T) rethrows -> T {
        if cache != nil { return try body() }
        return try $cache.withValue(Cache()) { try body() }
    }

    enum EntryType { case directory, regular, symlink, other }

    /// Directory listing with types from `readdir`'s `d_type`, falling back
    /// to `lstat` only when the filesystem does not report one. Never follows
    /// symlinks. Returns nil when the directory cannot be opened.
    static func entries(of directory: String) -> [(name: String, type: EntryType)]? {
        guard let dir = opendir(directory) else { return nil }
        defer { closedir(dir) }
        var out: [(name: String, type: EntryType)] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var type: EntryType
            switch Int32(entry.pointee.d_type) {
            case DT_DIR: type = .directory
            case DT_REG: type = .regular
            case DT_LNK: type = .symlink
            case DT_UNKNOWN:
                var info = stat()
                let path = join(directory, name)
                guard lstat(path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR: type = .directory
                case S_IFREG: type = .regular
                case S_IFLNK: type = .symlink
                default: type = .other
                }
            default: type = .other
            }
            out.append((name, type))
        }
        return out
    }

    /// `directory/name` as a native Swift string. `NSString` path helpers
    /// return bridged `NSPathStore2` objects, which every later sort or
    /// UTF-8 access had to copy first.
    @inline(__always) static func join(_ directory: String, _ name: String) -> String {
        directory.utf8.last == UInt8(ascii: "/") ? directory + name : directory + "/" + name
    }

    /// Parent of an absolute path by its last `/` (native, no bridging);
    /// nil at the root.
    static func parent(_ path: String) -> String? {
        guard let slash = path.utf8.lastIndex(of: UInt8(ascii: "/")) else { return nil }
        if slash == path.utf8.startIndex { return path.utf8.count > 1 ? "/" : nil }
        return String(path[..<slash])
    }

    /// Byte-wise UTF-8 order. Stable and total, and much cheaper than
    /// `String <` (canonical-equivalence aware), which dominated sorting
    /// thousands of long paths per scan.
    static func byteOrder(_ a: String, _ b: String) -> Bool {
        var a = a, b = b   // native strings are already contiguous: no copy
        return a.withUTF8 { pa in
            b.withUTF8 { pb in
                let shared = min(pa.count, pb.count)
                let c = shared == 0 ? 0 : memcmp(pa.baseAddress!, pb.baseAddress!, shared)
                return c != 0 ? c < 0 : pa.count < pb.count
            }
        }
    }

    private static let patternLock = NSLock()
    nonisolated(unsafe) private static var compiledPatterns: [String: NSRegularExpression] = [:]

    /// Shell-style `*`/`?` match. `*` and `*.ext` skip regex entirely; other
    /// patterns compile once and are reused (this runs per discovered file).
    static func matches(_ name: String, _ pattern: String) -> Bool {
        if pattern == "*" { return true }
        if pattern.hasPrefix("*"), !pattern.dropFirst().contains(where: { $0 == "*" || $0 == "?" }) {
            return name.hasSuffix(pattern.dropFirst())
        }
        patternLock.lock()
        let regex: NSRegularExpression? = compiledPatterns[pattern] ?? {
            let expression = "^" + NSRegularExpression.escapedPattern(for: pattern)
                .replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".") + "$"
            let compiled = try? NSRegularExpression(pattern: expression)
            compiledPatterns[pattern] = compiled
            return compiled
        }()
        patternLock.unlock()
        guard let regex else { return false }
        return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// `collectFiles: false` leaves `files` empty: callers that only need the
    /// folder structure skip gathering and sorting up to 10,000 paths.
    static func scan(root: String, maxDepth: Int = 8, maxDirectories: Int = 1_000,
                     skipNames: Set<String> = [".git"], skipPaths: Set<String> = [],
                     collectFiles: Bool = true) -> Result {
        let make = { walk(root: root, maxDepth: maxDepth, maxDirectories: maxDirectories,
                          skipNames: skipNames, skipPaths: skipPaths, collectFiles: collectFiles) }
        guard let cache else { return make() }
        return cache.scan(.init(root: root, maxDepth: maxDepth, maxDirectories: maxDirectories,
                                skipNames: skipNames, skipPaths: skipPaths, collectFiles: collectFiles), make)
    }

    private static func walk(root: String, maxDepth: Int, maxDirectories: Int,
                             skipNames: Set<String>, skipPaths: Set<String>, collectFiles: Bool) -> Result {
        var result = Result()
        var pending = [(root, 0)]
        while let (directory, depth) = pending.popLast() {
            guard result.directories.count < maxDirectories else { result.truncated = true; break }
            result.directories.append(directory)
            guard var listed = entries(of: directory) else { continue }
            result.childNames[directory] = Set(listed.map(\.name))
            if listed.count > 10_000 { result.truncated = true }
            listed.sort { byteOrder($0.name, $1.name) }
            for (name, type) in listed.prefix(10_000) where !skipNames.contains(name) {
                let path = join(directory, name)
                guard !skipPaths.contains(path) else { continue }
                switch type {
                case .directory:
                    if depth < maxDepth && pending.count + result.directories.count < maxDirectories { pending.append((path, depth + 1)) }
                    else { result.truncated = true }
                case .regular:
                    guard collectFiles else { break }
                    if result.files.count < 10_000 { result.files.append(path) } else { result.truncated = true }
                case .symlink: result.skippedLinks += 1
                case .other: break
                }
            }
        }
        result.files.sort(by: byteOrder); result.directories.sort(by: byteOrder)
        return result
    }

    /// Folders never descended into during project discovery (agent config
    /// dirs are resolved as sources instead; the rest are generated trees).
    static let projectSkipNames: Set<String> = [".git", ".claude", ".codex", ".gemini", ".opencode", ".agents", ".agent",
        ".cursor", ".copilot", ".github", "node_modules", ".build", "build", "dist", "vendor", ".venv", ".next"]

    static func projectFolders(root: String, collectFiles: Bool = true) -> Result {
        let submodules = Set(SubmoduleDiscovery.scan(root: root).paths.map { (root as NSString).appendingPathComponent($0) })
        return scan(root: root, skipNames: projectSkipNames, skipPaths: submodules, collectFiles: collectFiles)
    }
}
