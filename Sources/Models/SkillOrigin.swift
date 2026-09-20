import Foundation

/// Origin bucket for a skill row/package. The classification is derived only
/// from the resolved path, the file's read-only flag and the optional project
/// root, so the file list and the Configuration → Skills tab agree and the
/// rule is testable without a home, watchers or UI.
enum SkillOrigin: String, CaseIterable {
    case personal, project, plugins, system

    /// English source string; render through `L(...)` so it stays localized.
    var label: String {
        switch self {
        case .personal: return "Personal skills"
        case .project: return "Project skills"
        case .plugins: return "Plugin skills"
        case .system: return "System skills"
        }
    }

    var icon: String {
        switch self {
        case .personal: return "person.crop.circle"
        case .project: return "folder"
        case .plugins: return "puzzlepiece"
        case .system: return "lock.shield"
        }
    }
}

enum SkillGrouping {
    /// User-owned skill directories for the supported agents, matching the
    /// markers `KnowledgeInspector` already uses. Paths keep their trailing
    /// slash so a component boundary is required.
    static let personalMarkers = [
        "/.agents/skills/", "/.claude/skills/", "/.codex/skills/",
        "/.gemini/skills/", "/.opencode/skills/",
    ]

    static func isPlugin(path: String) -> Bool {
        path.contains("/plugins/") || path.contains("/extensions/")
    }

    /// Order matters: plugin folders live under agent roots too, and a
    /// project-local `.claude/skills` also contains the personal marker, so
    /// plugins win first and a registered project root wins over personal.
    /// Anything else that is read-only is system; otherwise it is treated as
    /// the user's own (personal).
    static func origin(path: String, readOnly: Bool, projectRoot: String? = nil) -> SkillOrigin {
        if isPlugin(path: path) { return .plugins }
        if let projectRoot, !projectRoot.isEmpty, path.hasPrefix(projectRoot + "/") {
            return .project
        }
        if personalMarkers.contains(where: { path.contains($0) }) { return .personal }
        if readOnly { return .system }
        return .personal
    }

    struct OwnerGroup<Item>: Identifiable {
        let owner: String
        let items: [Item]
        var id: String { owner }
    }

    struct Group<Item>: Identifiable {
        let origin: SkillOrigin
        let items: [Item]
        /// Non-empty owner buckets inside the origin, in first-seen order.
        /// A single-owner origin still reports one owner group: the user
        /// asked for belonging, not flattening.
        let owners: [OwnerGroup<Item>]
        var id: SkillOrigin { origin }

        /// Whether the UI nests a disclosure per owner. The model keeps a
        /// single-owner group for provenance, but rendering one collapsible
        /// owner inside its origin would only repeat a label, so views show
        /// the rows directly under the origin when `owners.count == 1`.
        var nestsOwners: Bool { owners.count > 1 }
    }

    /// Non-empty groups in display order (Personal, Project, Plugins, System).
    /// Inside each owner, items are sorted by skill folder name
    /// (`localizedStandardCompare`); `Group.items` gets the same order so
    /// flat and nested views agree.
    static func group<T>(_ items: [T], path: (T) -> String, readOnly: (T) -> Bool,
                         projectRoot: String?, home: String = AppPaths.home) -> [Group<T>] {
        var buckets: [SkillOrigin: [T]] = [:]
        var ownerOrder: [SkillOrigin: [String]] = [:]
        var ownerBuckets: [SkillOrigin: [String: [T]]] = [:]
        for item in items {
            let itemPath = path(item)
            let origin = origin(path: itemPath, readOnly: readOnly(item), projectRoot: projectRoot)
            let owner = owner(path: itemPath, origin: origin, projectRoot: projectRoot, home: home)
            buckets[origin, default: []].append(item)
            if ownerBuckets[origin, default: [:]][owner] == nil {
                ownerOrder[origin, default: []].append(owner)
            }
            ownerBuckets[origin, default: [:]][owner, default: []].append(item)
        }
        return SkillOrigin.allCases.compactMap { origin in
            guard let items = buckets[origin], !items.isEmpty else { return nil }
            let owners = (ownerOrder[origin] ?? []).map {
                OwnerGroup(owner: $0,
                           items: (ownerBuckets[origin]?[$0] ?? []).sorted {
                               comesFirst($0, $1, path: path)
                           })
            }
            return Group(origin: origin,
                         items: items.sorted { comesFirst($0, $1, path: path) },
                         owners: owners)
        }
    }

    /// Skill rows sort by the folder holding `SKILL.md`, Finder-style
    /// (`localizedStandardCompare`), with the full path as tiebreaker.
    private static func comesFirst<T>(_ lhs: T, _ rhs: T, path: (T) -> String) -> Bool {
        let a = skillFolderName(path(lhs)), b = skillFolderName(path(rhs))
        return a == b ? path(lhs) < path(rhs)
                      : a.localizedStandardCompare(b) == .orderedAscending
    }

    /// Sort/display key for a skill row: the folder holding `SKILL.md`.
    /// Works for `TrackedFile` and `SkillPackage` alike because both point
    /// `path` at the SKILL.md file.
    static func skillFolderName(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
    }

    // MARK: - Owner labels

    /// Who a skill belongs to inside its origin. Pure path logic so the file
    /// list and the Skills tab agree; never the skill folder itself (the
    /// parent of SKILL.md is already the row's display name).
    static func owner(path: String, origin: SkillOrigin,
                      projectRoot: String? = nil,
                      home: String = AppPaths.home) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return fallbackOwner(origin) }
        let skillFolder = parts.count - 2
        switch origin {
        case .plugins:
            return pluginOwner(parts: parts, skillFolder: skillFolder, home: home)
        case .project:
            return projectOwner(path: path, projectRoot: projectRoot)
        case .personal:
            let root = skillsRoot(parts: parts, skillFolder: skillFolder)
            return root == "/" ? fallbackOwner(origin) : shortPath(root, home: home)
        case .system:
            guard skillFolder > 0 else { return fallbackOwner(origin) }
            return shortPath("/" + parts[..<skillFolder].joined(separator: "/"), home: home)
        }
    }

    /// `plugins/cache/<rest>` chains are marketplace / plugin / version /
    /// `skills` or `skills-*` wrapper folders; the owner is the plugin id.
    /// Anywhere else under `plugins/`/`extensions/` the owner is the first
    /// package folder after the marker that isn't the cache.
    private static func pluginOwner(parts: [String], skillFolder: Int, home: String) -> String {
        var marker = -1
        for i in 0..<skillFolder where parts[i] == "plugins" || parts[i] == "extensions" {
            marker = i
        }
        guard marker >= 0 else { return fallbackOwner(.plugins) }
        let first = marker + 1
        if parts[marker] == "plugins", first < skillFolder, parts[first] == "cache" {
            let ids = parts[(first + 1)..<skillFolder].filter {
                !isVersionDir($0) && !isWrapperDir($0)
            }
            if ids.count >= 2 {
                let (marketplace, plugin) = (ids[0], ids[1])
                return marketplace == plugin || marketplace == "cache"
                    ? plugin : "\(marketplace) / \(plugin)"
            }
            return ids.first ?? "cache"
        }
        if let package = parts[first..<skillFolder].first(where: { $0 != "cache" }) {
            return package
        }
        return shortPath("/" + parts[...marker].joined(separator: "/"), home: home)
    }

    /// Project skills belong to the project-relative skills folder,
    /// including any submodule prefix (`sub/.agents/skills`).
    private static func projectOwner(path: String, projectRoot: String?) -> String {
        guard let projectRoot, !projectRoot.isEmpty else { return fallbackOwner(.project) }
        let projectName = (projectRoot as NSString).lastPathComponent
        let prefix = projectRoot + "/"
        let relParts = (path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : "")
            .split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard relParts.count >= 2 else { return projectName.isEmpty ? fallbackOwner(.project) : projectName }
        let relSkillFolder = relParts.count - 2
        if let j = relParts[..<relSkillFolder].firstIndex(of: "skills") {
            return relParts[...j].joined(separator: "/")
        }
        let parent = relParts[..<relSkillFolder].joined(separator: "/")
        return parent.isEmpty ? (projectName.isEmpty ? fallbackOwner(.project) : projectName) : parent
    }

    /// Personal skills belong to the skills root (`~/.claude/skills`, …).
    /// Falls back to the folder holding the skill when no `skills` segment
    /// exists (personal-fallback paths like `~/.cursor/skills` still match).
    private static func skillsRoot(parts: [String], skillFolder: Int) -> String {
        if let j = parts[..<skillFolder].firstIndex(of: "skills") {
            return "/" + parts[...j].joined(separator: "/")
        }
        return "/" + parts[..<skillFolder].joined(separator: "/")
    }

    /// `0.5.0`-style folder names: digits separated by dots.
    private static func isVersionDir(_ name: String) -> Bool {
        name.components(separatedBy: ".").allSatisfy {
            !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" }
        }
    }

    /// Cache folders that only wrap skill folders, never identity.
    private static func isWrapperDir(_ name: String) -> Bool {
        name == "skills" || name == "workflow-skills" || name.hasPrefix("skills-")
    }

    private static func shortPath(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private static func fallbackOwner(_ origin: SkillOrigin) -> String {
        switch origin {
        case .personal: return "Personal"
        case .project: return "Project"
        case .plugins: return "Plugins"
        case .system: return "System"
        }
    }

    /// Accessibility-id-safe form of an owner label: letters, digits, `.`,
    /// `_`, `-` are kept; any other run collapses to a single `-`.
    static func sanitizedOwnerID(_ owner: String) -> String {
        var out = ""
        var dashed = false
        for c in owner {
            if c.isLetter || c.isNumber || c == "." || c == "_" || c == "-" {
                out.append(c)
                dashed = false
            } else if !dashed {
                out.append("-")
                dashed = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "owner" : trimmed
    }
}

/// Per-origin disclosure state with the agreed defaults: Personal, Project
/// and System start expanded; Plugins stay open only while there are fewer
/// than six packages. Once the user toggles a group their choice sticks.
struct SkillGroupExpansion {
    private var overrides: [SkillOrigin: Bool] = [:]
    private var ownerOverrides: [SkillOrigin: [String: Bool]] = [:]

    func isExpanded(_ origin: SkillOrigin, count: Int) -> Bool {
        overrides[origin] ?? (origin == .plugins ? count < 6 : true)
    }

    mutating func set(_ origin: SkillOrigin, _ value: Bool) {
        overrides[origin] = value
    }

    /// Owner groups default to expanded below six skills and collapse at
    /// six or more, independently of the origin's own disclosure state.
    /// Once the user toggles an owner their choice sticks.
    func isExpanded(_ origin: SkillOrigin, owner: String, count: Int) -> Bool {
        ownerOverrides[origin]?[owner] ?? (count < 6)
    }

    mutating func set(_ origin: SkillOrigin, owner: String, _ value: Bool) {
        ownerOverrides[origin, default: [:]][owner] = value
    }
}
