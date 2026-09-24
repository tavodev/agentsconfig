import Foundation
import SwiftUI

/// Declarative catalog: each agent = detection paths + a list of config sources.
/// Sources can be single files or directories enumerated with a glob.
enum AgentRegistry {

    private static let baseDefinitions: [AgentDefinition] = [

        AgentDefinition(
            id: "claude-code",
            name: "Claude Code",
            symbol: "sparkle",
            color: Color(red: 0.82, green: 0.51, blue: 0.35),
            detectionPaths: ["~/.claude", "~/.claude.json"],
            sources: [
                .init(path: "~/.claude/settings.json", role: .settings,
                      note: "Global user settings"),
                .init(path: "~/.claude/CLAUDE.md", role: .instructions,
                      note: "Global instructions (memory)"),
                .init(path: "~/.claude/mcp.json", role: .mcp, note: "Nonstandard MCP file — inspection only"),
                .init(path: "~/.claude/hooks", isDirectory: true, role: .hooks,
                      note: "Hook scripts"),
                .init(path: "~/.claude/skills", isDirectory: true, glob: "*/SKILL.md", role: .skills),
                .init(path: "~/.claude/agents", isDirectory: true, role: .agents),
                .init(path: "~/.claude/commands", isDirectory: true, role: .other,
                      note: "Custom commands"),
                .init(path: "~/.claude/statusline.sh", role: .other, note: "Status line"),
                .init(path: "~/.claude/plugins/config.json", role: .plugins),
                .init(path: "~/.claude/plugins/installed_plugins.json", role: .plugins),
                .init(path: "~/.claude.json", role: .state, volatile: true,
                      note: "Global state + MCP servers (very active, live view only)"),
            ],
            localSources: [
                .init(path: ".claude/settings.json", role: .settings,
                      note: "Project settings"),
                .init(path: ".claude/settings.local.json", role: .settings,
                      note: "Personal overrides — usually gitignored"),
                .init(path: ".mcp.json", role: .mcp, note: "Project MCP servers"),
                .init(path: "CLAUDE.md", role: .instructions, note: "Project instructions (memory)"),
                .init(path: ".claude/agents", isDirectory: true, role: .agents),
                .init(path: ".claude/skills", isDirectory: true, glob: "*/SKILL.md", role: .skills),
                .init(path: ".claude/commands", isDirectory: true, role: .other,
                      note: "Custom commands"),
            ],
            mcpDestinationPaths: ["~/.claude.json"],
            notes: "Precedence: managed > CLI > local > project > user; lists have specific merge rules. Global MCP servers live in ~/.claude.json → mcpServers."
        ),

        AgentDefinition(
            id: "codex",
            name: "Codex",
            symbol: "terminal",
            color: Color(red: 0.24, green: 0.52, blue: 0.94),
            detectionPaths: ["~/.codex"],
            sources: [
                .init(path: "~/.codex/config.toml", role: .settings,
                      note: "Main config (TOML): model, sandbox, MCP, plugins, projects"),
                .init(path: "~/.codex/AGENTS.md", role: .instructions,
                      note: "Global instructions"),
                .init(path: "~/.codex/hooks.json", role: .hooks),
                .init(path: "~/.codex/rules", isDirectory: true, glob: "*.rules", role: .permissions,
                      note: "Prefix rules (allow/deny)"),
                .init(path: "~/.codex/agents", isDirectory: true, role: .agents),
                .init(path: "~/.codex/skills", isDirectory: true, glob: "*/SKILL.md", role: .skills),
                .init(path: "~/.codex/prompts", isDirectory: true, role: .other),
                .init(path: "~/.codex/auth.json", role: .state, volatile: true, readOnly: true,
                      note: "Credentials — read-only"),
            ],
            localSources: [
                .init(path: ".codex/config.toml", role: .settings,
                      note: "Project override — loaded only if the project is trusted"),
                .init(path: ".codex/agents", isDirectory: true, glob: "*.toml", role: .agents),
                .init(path: ".agents/skills", isDirectory: true, glob: "*/SKILL.md", role: .skills,
                      note: "Discovered project skill — session loading not verified"),
                .init(path: ".codex/hooks", isDirectory: true, role: .hooks,
                      note: "Project hook script — inspected, never executed"),
                .init(path: ".codex", isDirectory: true, glob: "activity-*.jsonl", role: .state,
                      volatile: true, excludeFromHistory: true, readOnly: true,
                      note: "Project activity log — read-only, no history"),
                .init(path: "AGENTS.md", role: .instructions, note: "Project instructions"),
            ],
            mcpDestinationPaths: ["~/.codex/config.toml"],
            notes: "Profiles: ~/.codex/<name>.config.toml. Per-project overrides in .codex/config.toml."
        ),

        AgentDefinition(
            id: "antigravity",
            name: "Antigravity / Gemini",
            symbol: "globe",
            color: Color(red: 0.32, green: 0.55, blue: 0.95),
            detectionPaths: ["~/.gemini"],
            sources: [
                .init(path: "~/.gemini/settings.json", role: .settings,
                      note: "Gemini CLI user settings"),
                .init(path: "~/.gemini/GEMINI.md", role: .instructions),
                .init(path: "~/.gemini/config/mcp_config.json", role: .mcp,
                      note: "Additional MCP file — inspection only"),
                .init(path: "~/.gemini/config/config.json", role: .settings,
                      excludeFromHistory: true,
                      note: "Plugins + userSettings (excluded from history — may contain secrets)"),
                .init(path: "~/.gemini/antigravity/mcp_config.json", role: .mcp,
                      note: "IDE MCP file — separate from Gemini CLI"),
                .init(path: "~/Library/Application Support/Antigravity/User/settings.json",
                      role: .settings, note: "IDE settings (VS Code style)"),
                .init(path: "~/.gemini/config/skills", isDirectory: true, glob: "*/SKILL.md",
                      role: .skills),
                .init(path: "~/.gemini/trustedFolders.json", role: .permissions),
            ],
            localSources: [
                .init(path: ".gemini/settings.json", role: .settings, note: "Project settings"),
                .init(path: "GEMINI.md", role: .instructions, note: "Project instructions"),
            ],
            mcpDestinationPaths: ["~/.gemini/settings.json"],
            notes: "Automatic MCP edits target Gemini CLI settings.json. IDE and historical files are inspected separately."
        ),

        AgentDefinition(
            id: "opencode",
            name: "OpenCode",
            symbol: "chevron.left.forwardslash.chevron.right",
            color: Color(red: 0.56, green: 0.36, blue: 0.92),
            detectionPaths: ["~/.config/opencode"],
            sources: [
                .init(path: "~/.config/opencode/opencode.json", role: .settings,
                      note: "Providers, models and MCP"),
                .init(path: "~/.config/opencode/opencode.jsonc", role: .settings,
                      note: "OpenCode JSONC configuration"),
                .init(path: "~/.config/opencode/AGENTS.md", role: .instructions),
                .init(path: "~/.config/opencode/plugins", isDirectory: true, role: .plugins),
            ],
            localSources: [
                .init(path: "opencode.json", role: .settings, note: "Project config"),
                .init(path: "opencode.jsonc", role: .settings, note: "Project config (JSONC)"),
                .init(path: "AGENTS.md", role: .instructions, note: "Project instructions"),
                .init(path: ".opencode/agents", isDirectory: true, role: .agents),
            ],
            mcpDestinationPaths: ["~/.config/opencode/opencode.json", "~/.config/opencode/opencode.jsonc"],
            notes: "Declares $schema — validatable against https://opencode.ai/config.json."
        ),
    ]

    static var definitions: [AgentDefinition] { AgentCatalog.expanding(baseDefinitions) }

    /// Detect installed agents and resolve their file lists.
    static func detect() -> [Agent] {
        let fm = FileManager.default
        return definitions.compactMap { def in
            guard let hit = def.detectionPaths.first(where: {
                fm.fileExists(atPath: AppPaths.expand($0))
            }) else { return nil }
            return Agent(
                id: def.id, name: def.name, symbol: def.symbol, color: def.color,
                files: resolveFiles(def), detectionPath: hit, notes: def.notes
            )
        }
    }

    /// Turns `def.localSources` into absolute, project-rooted `ConfigSource`s
    /// and folds them into `def.sources`, under a synthetic per-project id.
    /// Once a source's path is absolute, `ConfigSource.expandedPath` (which
    /// only expands a leading "~") is a no-op on it — so the result flows
    /// through `resolveFiles`/watchers/etc. exactly like a global definition.
    private static func localizedDefinition(_ def: AgentDefinition, projectRoot: String) -> AgentDefinition {
        var localized = def
        localized.id = "\(def.id)::\(projectRoot)"
        var discoveryNotes = ["Project files found on disk; effective settings and session loading are not verified."]
        localized.sources = def.localSources.compactMap { src -> ConfigSource? in
            var s = src
            s.path = (projectRoot as NSString).appendingPathComponent(src.path)
            if src.isDirectory {
                guard let root = AppPaths.canonicalPath(projectRoot),
                      let target = AppPaths.canonicalPath(s.path),
                      target.hasPrefix(root + "/") else {
                    discoveryNotes.append((src.role == .skills ? "Skipped skill folder outside project: " : "Skipped folder outside project: ") + src.path)
                    return nil
                }
                if target != (root as NSString).appendingPathComponent(src.path) {
                    s.note = "Shared skills → " + String(target.dropFirst(root.count + 1))
                }
                // Shared skills must use one document/buffer/history identity.
                s.path = target
            }
            return s
        }
        localized.mcpDestinationPaths = []
        localized.notes = discoveryNotes.joined(separator: "\n")
        return localized
    }

    /// Resolve one agent's `localSources` against a project root into
    /// concrete tracked files.
    static func resolveLocalFiles(_ def: AgentDefinition, projectRoot: String) -> [TrackedFile] {
        resolveFiles(localizedDefinition(def, projectRoot: projectRoot))
    }

    /// Detect which agents have local (project-root-relative) config inside
    /// `projectRoot` **or any of its git submodules** (parsed from
    /// `.gitmodules`, recursively, bounded like `skillTree`). Mirrors
    /// `detect()`'s "only list what's actually there" behavior, but using
    /// "at least one resolved local file exists" instead of a fixed
    /// detection path. Returns, per detected agent, the synthetic
    /// `AgentDefinition` (already-absolute sources) `ConfigStore` needs to
    /// register alongside the resolved `Agent`.
    /// `folders` reuses `DiscoveryTree.projectFolders` results already
    /// computed by the caller, keyed by scan root.
    static func detectLocal(projectRoot: String, submodules: SubmoduleDiscovery.Result? = nil,
                            folders: [String: DiscoveryTree.Result] = [:]) -> [(def: AgentDefinition, agent: Agent)] {
        var scanRoots: [(submodulePath: String?, absRoot: String, label: String)] =
            [(nil, projectRoot, URL(fileURLWithPath: projectRoot).lastPathComponent)]
        for rel in (submodules ?? SubmoduleDiscovery.scan(root: projectRoot)).paths {
            scanRoots.append((rel, (projectRoot as NSString).appendingPathComponent(rel), rel))
        }
        var out: [(AgentDefinition, Agent)] = []
        for (submodulePath, absRoot, label) in scanRoots {
            let nested = folders[absRoot] ?? DiscoveryTree.projectFolders(root: absRoot, collectFiles: false)
            for def in definitions where !def.localSources.isEmpty {
                var expanded = def
                let firstComponents = def.localSources.map { $0.path.split(separator: "/").first.map(String.init) ?? $0.path }
                for folder in nested.directories where folder != absRoot {
                    let names = nested.childNames[folder]
                    for (index, source) in def.localSources.enumerated() {
                        // The scan already listed this folder: skip the stat
                        // unless the source's first component is present.
                        if let names, !names.contains(firstComponents[index]) { continue }
                        guard FileManager.default.fileExists(atPath: DiscoveryTree.join(folder, source.path)) else { continue }
                        let rel = String(decoding: folder.utf8.dropFirst(absRoot.utf8.count + 1), as: UTF8.self)
                        var nestedSource = source
                        nestedSource.path = rel + "/" + source.path
                        nestedSource.note = "Nested project source — session loading not verified"
                        expanded.localSources.append(nestedSource)
                    }
                }
                var localizedDef = localizedDefinition(expanded, projectRoot: absRoot)
                if nested.truncated { localizedDef.notes = (localizedDef.notes ?? "") + "\nProject discovery reached its folder limit." }
                let files = resolveFiles(localizedDef).filter { $0.exists || $0.note != "Nested project source — session loading not verified" }
                guard files.contains(where: { $0.exists }) else { continue }
                let agent = Agent(
                    id: localizedDef.id, name: "\(def.name) (\(label))", symbol: def.symbol,
                    color: def.color, files: files, detectionPath: absRoot,
                    notes: localizedDef.notes, projectRoot: projectRoot, submodulePath: submodulePath
                )
                out.append((localizedDef, agent))
            }
        }
        return out
    }

    /// Submodule paths declared directly in `root/.gitmodules` (relative to
    /// `root`), in declaration order. Doesn't require the submodule to be
    /// initialized/checked out — an uninitialized one simply resolves no
    /// local files later and is skipped by `detectLocal`.
    static func directSubmodulePaths(at root: String) -> [String] {
        SubmoduleDiscovery.directPaths(at: root)
    }

    /// Safe, bounded submodule paths; the store also publishes scan notices.
    static func submodulePaths(root: String, maxDepth: Int = 4, maxCount: Int = 200) -> [String] {
        SubmoduleDiscovery.scan(root: root, maxDepth: maxDepth, maxCount: maxCount).paths
    }

    /// Expand a definition's sources into concrete tracked files.
    static func resolveFiles(_ def: AgentDefinition) -> [TrackedFile] {
        let fm = FileManager.default
        var files: [TrackedFile] = []
        for src in def.sources {
            let path = src.expandedPath
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: path, isDirectory: &isDir)

            if src.isDirectory {
                guard exists, isDir.boolValue else { continue }
                for child in enumerateDirectory(path: path, glob: src.glob, recursive: src.recursive) {
                    files.append(makeTracked(path: child, src: src, exists: true))
                }
            } else {
                files.append(makeTracked(path: path, src: src, exists: exists))
            }
        }
        var unique: [String: TrackedFile] = [:]
        for file in files {
            if var previous = unique[file.path] {
                previous.readOnly = previous.readOnly || file.readOnly
                previous.excludeFromHistory = previous.excludeFromHistory || file.excludeFromHistory
                unique[file.path] = previous
            } else { unique[file.path] = file }
        }
        return unique.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func makeTracked(path: String, src: ConfigSource, exists: Bool) -> TrackedFile {
        let path = src.role == .skills ? (AppPaths.canonicalPath(path) ?? path) : path
        var size: Int64 = 0
        var mtime: Date? = nil
        var realExists = exists
        // lstat: attributesOfItem's no-follow metadata without reading xattrs.
        var info = stat()
        if lstat(path, &info) == 0 {
            size = Int64(info.st_size)
            mtime = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                         + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            realExists = true
        }
        return TrackedFile(
            path: path,
            format: src.format ?? inferFormat(path: path),
            role: src.role,
            volatile: src.volatile,
            excludeFromHistory: src.excludeFromHistory,
            readOnly: src.readOnly,
            note: src.note,
            exists: realExists,
            size: size,
            mtime: mtime
        )
    }

    /// Enumerate a directory; glob patterns like "*.json" or "*/SKILL.md".
    private static func enumerateDirectory(path: String, glob: String?, recursive: Bool = false) -> [String] {
        if recursive { return DiscoveryTree.scan(root: path).files.filter { DiscoveryTree.matches(URL(fileURLWithPath: $0).lastPathComponent, glob ?? "*") } }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        var out: [String] = []
        let pattern = glob ?? "*"

        func match(_ name: String, _ pat: String) -> Bool {
            if pat == "*" { return true }
            if let star = pat.firstIndex(of: "*"), !pat[pat.index(after: star)...].contains("*") {
                let prefix = String(pat[..<star])
                let suffix = String(pat[pat.index(after: star)...])
                return name.count >= prefix.count + suffix.count
                    && name.hasPrefix(prefix) && name.hasSuffix(suffix)
            }
            if pat.hasPrefix("*."), let ext = pat.split(separator: ".").last {
                return name.hasSuffix(".\(ext)")
            }
            return name == pat
        }

        if pattern == "*/SKILL.md" {
            return skillTree(at: path).files
        }
        if pattern.contains("/") {
            // one level deep, e.g. "*/SKILL.md"
            let parts = pattern.split(separator: "/", maxSplits: 1).map(String.init)
            for entry in entries {
                let sub = (path as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: sub, isDirectory: &isDir), isDir.boolValue else { continue }
                if let children = try? fm.contentsOfDirectory(atPath: sub) {
                    for c in children where match(c, parts[1]) {
                        out.append((sub as NSString).appendingPathComponent(c))
                    }
                }
            }
        } else {
            for entry in entries where match(entry, pattern) {
                let full = (path as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: full, isDirectory: &isDir)
                if !isDir.boolValue { out.append(full) }
            }
        }
        return out
    }

    /// Bounded recursive skill discovery. Directory symlinks and .git are
    /// not traversed; at most 8 levels / 1,000 directories are monitored.
    static func skillTree(at root: String) -> (files: [String], directories: [String]) {
        let make = {
            var files: [String] = []
            var directories: [String] = []
            var pending = [(root, 0)]
            while let (directory, depth) = pending.popLast(), directories.count < 1_000 {
                directories.append(directory)
                guard var listed = DiscoveryTree.entries(of: directory) else { continue }
                listed.sort { DiscoveryTree.byteOrder($0.name, $1.name) }
                for (name, type) in listed.prefix(10_000) where name != ".git" {
                    let path = DiscoveryTree.join(directory, name)
                    if type == .directory, depth < 8 { pending.append((path, depth + 1)) }
                    else if type == .regular, name == "SKILL.md" { files.append(path) }
                }
            }
            return (files, directories)
        }
        return DiscoveryTree.cache?.skillTree(root, make) ?? make()
    }

    static func watchDirectories(for source: ConfigSource) -> [String] {
        guard source.isDirectory else { return [] }
        if source.recursive { return DiscoveryTree.scan(root: source.expandedPath).directories }  // shares resolveFiles' scan
        return source.role == .skills ? skillTree(at: source.expandedPath).directories : [source.expandedPath]
    }

    static func inferFormat(path: String) -> ConfigFormat {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        switch (name as NSString).pathExtension {
        case "json": return .json
        case "jsonc": return .jsonc
        case "toml": return .toml
        case "md", "markdown", "mdc": return .markdown
        case "sh", "bash", "zsh": return .shell
        case "rules": return .dsl
        case "plist": return .plist
        case "pb": return .binary
        case "jsonl": return .text
        default:
            return .text
        }
    }
}
