import Foundation

/// `manifest.json` of an exported setup folder (issue #24).
struct SetupManifest: Codable, Equatable {
    struct File: Codable, Equatable, Identifiable {
        var id: String { scope + "|" + (project ?? "") + "|" + path }
        let agent: String
        /// "global" (relative to `~`) or "project" (relative to the project root).
        let scope: String
        /// Folder name of the project for `scope == "project"`.
        let project: String?
        let path: String
        let format: String
        /// SHA-256 of the exported (redacted) content.
        let sha256: String
        let bytes: Int
        /// True when redaction changed the content.
        let redacted: Bool
    }
    var formatVersion = 1
    var createdAt: Date
    var redaction = "best-effort"
    var files: [File]
}

struct SetupExportOptions {
    var includeProjects = true
    /// Volatile state and files excluded from history (often credentials)
    /// stay out unless asked for; they are redacted all the same.
    var includeSensitive = false
}

/// One file of an import preview, mapped to where it would be written.
struct SetupImportItem: Identifiable {
    enum Status: String { case new = "New", identical = "Identical", differs = "Differs",
                          unmapped = "No matching destination", tampered = "Changed after export" }
    var id: String { file.id }
    let file: SetupManifest.File
    let target: String?
    let status: Status
}

/// Export redacts with `Secrets.maskText` (best-effort) into a folder:
/// `manifest.json` + `files/global/<path from ~>` + `files/projects/<name>/<path>`.
/// Import never writes by itself: `ConfigStore` stages each file for review,
/// and redacted values are restored from the local file or dropped.
@MainActor enum SetupBundle {
    struct Candidate {
        let file: TrackedFile
        let agent: String
        let scope: String
        let project: String?
        let relative: String
    }

    static func candidates(agents: [Agent], projectRoots: [String], options: SetupExportOptions) -> [Candidate] {
        var seen = Set<String>()
        var out: [Candidate] = []
        let home = AppPaths.home
        for agent in agents {
            let family = agent.id.components(separatedBy: "::")[0]
            for file in agent.files where file.exists && !file.readOnly && file.format.isTextEditable
                && file.size <= 2_000_000 && seen.insert(file.path).inserted {
                if (file.volatile || file.excludeFromHistory) && !options.includeSensitive { continue }
                if let root = agent.projectRoot {
                    guard options.includeProjects, file.path.hasPrefix(root + "/") else { continue }
                    out.append(.init(file: file, agent: family, scope: "project",
                                     project: URL(fileURLWithPath: root).lastPathComponent,
                                     relative: String(file.path.dropFirst(root.count + 1))))
                } else if file.path.hasPrefix(home + "/") {
                    out.append(.init(file: file, agent: family, scope: "global", project: nil,
                                     relative: String(file.path.dropFirst(home.count + 1))))
                }
            }
        }
        return out.sorted { ($0.scope, $0.project ?? "", $0.relative) < ($1.scope, $1.project ?? "", $1.relative) }
    }

    /// Writes a new folder `directory` (must not exist). Files are 0600.
    @discardableResult
    static func export(_ candidates: [Candidate], to directory: URL, read: (String) -> String?,
                       now: Date = Date()) throws -> SetupManifest {
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: directory.path])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var files: [SetupManifest.File] = []
        for candidate in candidates {
            guard let text = read(candidate.file.path) else { continue }
            let safe = Secrets.maskText(text, format: candidate.file.format, masking: true)
            try AtomicWriter.createNew(safe, atPath: bundlePath(directory, scope: candidate.scope,
                                                                project: candidate.project, path: candidate.relative).path)
            files.append(.init(agent: candidate.agent, scope: candidate.scope, project: candidate.project,
                               path: candidate.relative, format: candidate.file.format.rawValue,
                               sha256: SnapshotStore.sha256(safe), bytes: safe.utf8.count,
                               redacted: safe.contains(Secrets.maskedValue)))
        }
        let manifest = SetupManifest(createdAt: now, files: files)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try AtomicWriter.createNew(String(decoding: try encoder.encode(manifest), as: UTF8.self),
                                   atPath: directory.appendingPathComponent("manifest.json").path)
        return manifest
    }

    static func bundlePath(_ directory: URL, scope: String, project: String?, path: String) -> URL {
        let base = directory.appendingPathComponent("files", isDirectory: true)
        return scope == "project"
            ? base.appendingPathComponent("projects").appendingPathComponent(project ?? "_").appendingPathComponent(path)
            : base.appendingPathComponent("global").appendingPathComponent(path)
    }

    static func readManifest(_ directory: URL) throws -> SetupManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SetupManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    }

    /// Paths from the manifest are untrusted: absolute or `..` components
    /// never map to a destination.
    static func importItems(_ manifest: SetupManifest, directory: URL, projectRoots: [String],
                            read: (String) -> String?) -> [SetupImportItem] {
        manifest.files.map { file in
            let components = file.path.split(separator: "/")
            let safe = !file.path.hasPrefix("/") && !components.contains("..") && !components.isEmpty
                && (file.project.map { !$0.contains("/") && $0 != ".." } ?? true)
            var target: String?
            if safe {
                if file.scope == "global" { target = AppPaths.home + "/" + file.path }
                else if let project = file.project {
                    let roots = projectRoots.filter { URL(fileURLWithPath: $0).lastPathComponent == project }
                    if roots.count == 1 { target = roots[0] + "/" + file.path }
                }
            }
            let source = bundlePath(directory, scope: file.scope, project: file.project, path: file.path)
            guard let target, let imported = try? String(contentsOf: source, encoding: .utf8) else {
                return .init(file: file, target: nil, status: .unmapped)
            }
            if SnapshotStore.sha256(imported) != file.sha256 { return .init(file: file, target: target, status: .tampered) }
            guard let local = read(target) else { return .init(file: file, target: target, status: .new) }
            let format = ConfigFormat(rawValue: file.format) ?? .text
            let merged = restoringRedactions(imported, local: local, format: format).text
            return .init(file: file, target: target, status: sameContent(merged, local, format: format) ? .identical : .differs)
        }
    }

    /// Structured files compare by value: export normalizes their formatting.
    static func sameContent(_ a: String, _ b: String, format: ConfigFormat) -> Bool {
        guard format.isStructured, let left = Parsers.parse(a, format: format).tree,
              let right = Parsers.parse(b, format: format).tree else { return a == b }
        let encode = { (value: Any) in try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
        return encode(left) == encode(right)
    }

    /// Redacted values never replace real ones: a masked value takes the
    /// local value at the same key path (or the same line for text files),
    /// and is dropped with a warning when the local file has none.
    static func restoringRedactions(_ imported: String, local: String?, format: ConfigFormat) -> (text: String, dropped: [String]) {
        guard imported.contains(Secrets.maskedValue) else { return (imported, []) }
        var dropped: [String] = []
        if format.isStructured {
            guard let tree = Parsers.parse(imported, format: format).tree else { return (local ?? "", ["(whole file)"]) }
            let localTree = local.flatMap { Parsers.parse($0, format: format).tree }
            func merge(_ value: Any, _ current: Any?, _ path: String) -> Any? {
                if let text = value as? String, text == Secrets.maskedValue {
                    if let current { return current }
                    dropped.append(path.isEmpty ? "(whole file)" : path); return nil
                }
                if let dict = value as? [String: Any] {
                    let currentDict = current as? [String: Any]
                    var out: [String: Any] = [:]
                    for (key, child) in dict {
                        if let merged = merge(child, currentDict?[key], path.isEmpty ? key : path + "." + key) { out[key] = merged }
                    }
                    return out
                }
                if let array = value as? [Any] {
                    let currentArray = current as? [Any]
                    return array.enumerated().compactMap { index, child in
                        merge(child, currentArray.flatMap { index < $0.count ? $0[index] : nil }, path + "[\(index)]")
                    }
                }
                return value
            }
            guard let merged = merge(tree, localTree, "") else { return (local ?? "", dropped) }
            let text = (format == .toml ? Parsers.serializeTOML(merged) : Parsers.serializeJSON(merged)) ?? (local ?? "")
            return (text, dropped)
        }
        let localLines = local?.components(separatedBy: "\n") ?? []
        var lines: [String] = []
        for (index, line) in imported.components(separatedBy: "\n").enumerated() {
            guard line == Secrets.maskedValue else { lines.append(line); continue }
            if index < localLines.count, Secrets.isSensitive(localLines[index], path: "") { lines.append(localLines[index]) }
            else { dropped.append("line \(index + 1)") }
        }
        return (lines.joined(separator: "\n"), dropped)
    }
}
