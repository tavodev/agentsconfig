import Foundation

/// Bounded, non-executing .gitmodules discovery. Includes are never followed.
/// Syntax reference: https://git-scm.com/docs/git-config#_syntax
/// Paths are checked both lexically and against their canonical parent.
enum SubmoduleDiscovery {
    enum Problem: String {
        case invalidManifest = "Skipped .gitmodules: unreadable, invalid, or larger than 1 MB."
        case linkedManifest = "Skipped .gitmodules: symbolic links are not supported."
        case invalidPath = "Skipped submodule: the path must stay inside its parent folder."
        case duplicate = "Skipped submodule: duplicate folder or cycle."
        case depthLimit = "Submodule discovery reached the depth limit."
        case countLimit = "Submodule discovery reached the entry limit."
    }
    struct Notice: Hashable {
        let manifest: String
        let problem: Problem
        @MainActor var message: String { L(problem.rawValue) + " (" + manifest + ")" }
    }
    struct Result {
        var paths: [String] = []
        var notices: [Notice] = []
        var directories: [String] = []
    }

    static func scan(root: String, maxDepth: Int = 4, maxCount: Int = 200) -> Result {
        var result = Result()
        let canonicalRoot = canonical(root)
        var seen: Set<String> = [canonicalRoot]
        var pending: [(relative: String, depth: Int)] = [("", 0)]
        var cursor = 0
        var examined = 0
        while cursor < pending.count {
            let (relative, depth) = pending[cursor]
            cursor += 1
            let directory = relative.isEmpty ? root : (root as NSString).appendingPathComponent(relative)
            let manifest = relative.isEmpty ? ".gitmodules" : relative + "/.gitmodules"
            result.directories.append(directory)
            let parsed = readPaths(at: directory)
            if let problem = parsed.problem { result.notices.append(.init(manifest: manifest, problem: problem)) }
            guard !parsed.paths.isEmpty else { continue }
            guard depth < max(0, maxDepth) else {
                result.notices.append(.init(manifest: manifest, problem: .depthLimit))
                continue
            }
            for path in parsed.paths {
                guard examined < max(0, maxCount) else {
                    result.notices.append(.init(manifest: manifest, problem: .countLimit))
                    return result
                }
                examined += 1
                guard let child = safeChild(path, parent: directory),
                      child.hasPrefix(canonicalRoot + "/") else {
                    result.notices.append(.init(manifest: manifest, problem: .invalidPath))
                    continue
                }
                guard seen.insert(child).inserted else {
                    result.notices.append(.init(manifest: manifest, problem: .duplicate))
                    continue
                }
                let fullRelative = relative.isEmpty ? path : relative + "/" + path
                result.paths.append(fullRelative)
                pending.append((fullRelative, depth + 1))
            }
        }
        return result
    }

    static func directPaths(at root: String) -> [String] {
        readPaths(at: root).paths.filter { safeChild($0, parent: root) != nil }
    }

    private static func canonical(_ path: String) -> String {
        // realpath canonicalizes /var aliases and fails closed on symlink loops.
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func safeChild(_ path: String, parent: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~/"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".git" }) else { return nil }
        let full = (parent as NSString).appendingPathComponent(path)
        let target = canonical(full)
        guard target.hasPrefix(canonical(parent) + "/") else { return nil }
        // Existing links that cannot be resolved (including cycles) are rejected.
        if (try? FileManager.default.attributesOfItem(atPath: full)[.type] as? FileAttributeType) == .typeSymbolicLink {
            guard let resolved = realpath(full, nil) else { return nil }
            free(resolved)
        }
        return target
    }

    private static func readPaths(at root: String) -> (paths: [String], problem: Problem?) {
        let path = (root as NSString).appendingPathComponent(".gitmodules")
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path) else {
            return ([], fm.fileExists(atPath: path) ? .invalidManifest : nil)
        }
        guard attrs[.type] as? FileAttributeType != .typeSymbolicLink else { return ([], .linkedManifest) }
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 1_000_000 else { return ([], .invalidManifest) }
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 1_000_001) ?? Data()
            guard data.count <= 1_000_000, let text = String(data: data, encoding: .utf8),
                  let paths = parse(text) else { return ([], .invalidManifest) }
            return (paths, nil)
        } catch { return ([], .invalidManifest) }
    }

    /// Parses only path declarations, with Git quoting/comments/continuations.
    /// Invalid syntax rejects the manifest as a unit; include sections are inert.
    static func parse(_ text: String) -> [String]? {
        guard !text.contains("\0") else { return nil }
        var paths: [String] = []
        var pathIndices: [String: Int] = [:]
        var section: String?
        var logical = ""
        var quoted = false
        var escaped = false
        var comment = false
        let content = (text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
            .replacingOccurrences(of: "\r\n", with: "\n")
        func consume(_ raw: String) -> Bool {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return true }
            if line.hasPrefix("[") {
                var quote = false
                var escape = false
                var end: String.Index?
                for index in line.indices.dropFirst() {
                    let c = line[index]
                    if escape { escape = false }
                    else if c == "\\" && quote { escape = true }
                    else if c == "\"" { quote.toggle() }
                    else if c == "]" && !quote { end = index; break }
                }
                guard let end else { return false }
                let header = String(line[line.index(after: line.startIndex)..<end])
                guard let identity = parseSection(header) else { return false }
                section = identity
                line = String(line[line.index(after: end)...]).trimmingCharacters(in: .whitespaces)
                if line.isEmpty { return true }
            }
            guard section != nil else { return false }
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = pair[0].trimmingCharacters(in: .whitespaces)
            guard name.range(of: "^[A-Za-z][A-Za-z0-9-]*$", options: .regularExpression) != nil else { return false }
            guard pair.count == 2 else { return name.lowercased() != "path" || section?.hasPrefix("submodule:") != true }
            guard let value = parseValue(String(pair[1])) else { return false }
            if let section, section.hasPrefix("submodule:"), name.lowercased() == "path" {
                if let index = pathIndices[section] { paths[index] = value }
                else { pathIndices[section] = paths.count; paths.append(value) }
            }
            return true
        }
        for c in content + "\n" {
            if c == "\n" {
                if escaped && !comment {
                    guard !logical.trimmingCharacters(in: .whitespaces).hasPrefix("[") else { return nil }
                    escaped = false; logical.removeLast(); continue
                }
                guard !quoted, consume(logical) else { return nil }
                logical = ""; escaped = false; comment = false
            } else if !comment {
                if escaped { logical.append(c); escaped = false }
                else if c == "\\" { logical.append(c); escaped = true }
                else if c == "\"" { logical.append(c); quoted.toggle() }
                else if (c == "#" || c == ";") && !quoted { comment = true }
                else { logical.append(c) }
            }
        }
        return logical.isEmpty && !quoted ? paths : nil
    }

    private static func parseSection(_ raw: String) -> String? {
        let header = raw.trimmingCharacters(in: .whitespaces)
        if let quote = header.firstIndex(of: "\"") {
            let prefix = header[..<quote]
            guard prefix.last?.isWhitespace == true else { return nil }
            let name = prefix.trimmingCharacters(in: .whitespaces)
            let suffix = String(header[quote...])
            guard name.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil,
                  suffix.hasSuffix("\""), suffix.count >= 2 else { return nil }
            // Subsection escapes allow any escaped character; its name is opaque.
            var escaped = false
            var subsection = ""
            for c in suffix.dropFirst().dropLast() {
                if escaped { subsection.append(c); escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { return nil }
                else { subsection.append(c) }
            }
            guard !escaped else { return nil }
            return name.lowercased() == "submodule" ? "submodule:" + subsection : "other"
        }
        guard header.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else { return nil }
        return header.lowercased().hasPrefix("submodule.") && header.count > 10
            ? "submodule:" + header.dropFirst(10).lowercased() : "other"
    }

    private static func parseValue(_ raw: String) -> String? {
        var result = ""
        var whitespace = ""
        var quoted = false
        var escaped = false
        for c in raw {
            if escaped {
                let escapes: [Character: Character] = ["n": "\n", "t": "\t", "b": "\u{8}", "\\": "\\", "\"": "\""]
                guard let value = escapes[c] else { return nil }
                result += whitespace; whitespace = ""; result.append(value); escaped = false
            } else if c == "\\" { escaped = true }
            else if c == "\"" { result += whitespace; whitespace = ""; quoted.toggle() }
            else if !quoted && (c == " " || c == "\t") {
                if !result.isEmpty { whitespace.append(c) }
            } else { result += whitespace; whitespace = ""; result.append(c) }
        }
        return quoted || escaped ? nil : result
    }
}
