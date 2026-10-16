import Foundation

/// One parsed hooks file handed to `HookMap.build`: the owning agent family,
/// the file and its parsed tree. Only the `hooks` key is read.
struct HookMapSource {
    let agentID: String
    let agentName: String
    let path: String
    let tree: [String: Any]
}

/// A single hook command as declared on disk. `command` keeps the raw text
/// (views mask it); `declarationIndex` is the position inside its file.
struct HookMapEntry: Identifiable {
    var id: String { "\(agentID)|\(sourcePath)|\(event)|\(declarationIndex)" }
    let event: String
    let matcher: String?
    let command: String
    let agentID: String
    let agentName: String
    let sourcePath: String
    let layer: Layer
    let declarationIndex: Int
    let missingPaths: [String]

    enum Layer: String, CaseIterable, Comparable {
        case managed = "Managed", user = "User", project = "Project", local = "Local"
        static func < (a: Layer, b: Layer) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }
}

/// Event × matcher bucket of the map, entries in listing order.
struct HookMapGroup: Identifiable {
    var id: String { event + "\u{0}" + (matcher ?? "") }
    let event: String
    let matcher: String?
    let entries: [HookMapEntry]
}

/// "What runs on `PreToolUse` in this project?" — hooks from every layer and
/// agent, grouped by event and matcher. Pure: reads parsed trees, checks
/// referenced paths with `fileExists`, never executes anything.
///
/// Within an event the listing follows agent, layer (managed → user →
/// project → local) and declaration order. That is a reading order, not an
/// execution order: clients decide it (Claude Code runs matching hooks in
/// parallel), and hooks declared under different agents never combine.
@MainActor enum HookMap {
    /// Keys under `hooks` that are bookkeeping, not events (Codex trust state).
    static let nonEventKeys: Set<String> = ["state", "version", "disabled", "enabled"]

    static func build(_ sources: [HookMapSource], projectRoot: String?) -> [HookMapEntry] {
        var out: [HookMapEntry] = []
        for source in sources {
            guard let hooks = source.tree["hooks"] as? [String: Any] else { continue }
            let layer = layer(for: source.path, projectRoot: projectRoot)
            var index = 0
            for event in hooks.keys.sorted() where !nonEventKeys.contains(event) {
                for (matcher, command) in commands(in: hooks[event] as Any) {
                    out.append(.init(event: event, matcher: matcher, command: command,
                                     agentID: source.agentID, agentName: source.agentName,
                                     sourcePath: source.path, layer: layer, declarationIndex: index,
                                     missingPaths: Linter.referencedPaths(in: command)
                                        .filter { !FileManager.default.fileExists(atPath: $0) }))
                    index += 1
                }
            }
        }
        return out.sorted {
            ($0.event, $0.matcher ?? "", $0.agentName, $0.layer, $0.sourcePath, $0.declarationIndex)
                < ($1.event, $1.matcher ?? "", $1.agentName, $1.layer, $1.sourcePath, $1.declarationIndex)
        }
    }

    static func grouped(_ entries: [HookMapEntry]) -> [HookMapGroup] {
        var groups: [HookMapGroup] = []
        for entry in entries {
            if let last = groups.last, last.event == entry.event, last.matcher == entry.matcher {
                groups[groups.count - 1] = .init(event: last.event, matcher: last.matcher, entries: last.entries + [entry])
            } else {
                groups.append(.init(event: entry.event, matcher: entry.matcher, entries: [entry]))
            }
        }
        return groups
    }

    /// Claude/Codex/Gemini: `[{matcher, hooks: [{command}]}]`; Cursor and
    /// Windsurf: `[{command}]`. A `command` array (argv) is joined for display.
    private static func commands(in value: Any) -> [(String?, String)] {
        var out: [(String?, String)] = []
        func command(_ item: [String: Any]) -> String? {
            if let text = item["command"] as? String { return text }
            if let argv = item["command"] as? [Any] { return argv.compactMap { $0 as? String }.joined(separator: " ") }
            return nil
        }
        for case let item as [String: Any] in (value as? [Any]) ?? [value] {
            let matcher = (item["matcher"] as? String).flatMap { $0.isEmpty || $0 == "*" ? nil : $0 }
            if let nested = item["hooks"] as? [Any] {
                for case let hook as [String: Any] in nested { if let text = command(hook) { out.append((matcher, text)) } }
            } else if let text = command(item) {
                out.append((matcher, text))
            }
        }
        return out
    }

    static func layer(for path: String, projectRoot: String?) -> HookMapEntry.Layer {
        if path.hasPrefix(AppPaths.systemPath("/Library/") ) || path.hasPrefix(AppPaths.systemPath("/etc/")) { return .managed }
        if let projectRoot, !projectRoot.isEmpty, path.hasPrefix(projectRoot + "/") {
            return URL(fileURLWithPath: path).lastPathComponent.contains(".local.") ? .local : .project
        }
        return .user
    }
}
