import Foundation

/// Shared bounded traversal. Never executes discovered content or crosses a
/// directory symlink. Callers may explicitly select a root that is itself linked.
enum DiscoveryTree {
    struct Result {
        var files: [String] = []
        var directories: [String] = []
        var truncated = false
        var skippedLinks = 0
    }
    static func matches(_ name: String, _ pattern: String) -> Bool {
        let expression = "^" + NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".") + "$"
        return name.range(of: expression, options: .regularExpression) != nil
    }
    static func scan(root: String, maxDepth: Int = 8, maxDirectories: Int = 1_000,
                     skipNames: Set<String> = [".git"], skipPaths: Set<String> = []) -> Result {
        var result = Result()
        var pending = [(root, 0)]
        while let (directory, depth) = pending.popLast() {
            guard result.directories.count < maxDirectories else { result.truncated = true; break }
            result.directories.append(directory)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            if names.count > 10_000 { result.truncated = true }
            for name in names.sorted().prefix(10_000) where !skipNames.contains(name) {
                let path = (directory as NSString).appendingPathComponent(name)
                guard !skipPaths.contains(path), let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let type = attrs[.type] as? FileAttributeType else { continue }
                if type == .typeDirectory {
                    if depth < maxDepth && pending.count + result.directories.count < maxDirectories { pending.append((path, depth + 1)) }
                    else { result.truncated = true }
                } else if type == .typeRegular {
                    if result.files.count < 10_000 { result.files.append(path) } else { result.truncated = true }
                }
                else if type == .typeSymbolicLink { result.skippedLinks += 1 }
            }
        }
        result.files.sort(); result.directories.sort()
        return result
    }
    static func projectFolders(root: String) -> Result {
        let submodules = Set(SubmoduleDiscovery.scan(root: root).paths.map { (root as NSString).appendingPathComponent($0) })
        return scan(root: root, skipNames: [".git", ".claude", ".codex", ".gemini", ".opencode", ".agents", ".agent",
            ".cursor", ".copilot", ".github", "node_modules", ".build", "build", "dist", "vendor", ".venv", ".next"], skipPaths: submodules)
    }
}
