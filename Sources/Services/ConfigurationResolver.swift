import Foundation

/// On-disk inference, never a claim about a running session.
@MainActor enum ConfigurationResolver {
    static let referenceDate = "2026-09-13"
    static func ancestors(root: String, directory: String) -> [String]? {
        guard let root = AppPaths.canonicalPath(root), let directory = AppPaths.canonicalPath(directory),
              directory == root || directory.hasPrefix(root + "/") else { return nil }
        var result = [directory]
        while result.last != root {
            let parent = (result.last! as NSString).deletingLastPathComponent
            guard parent != result.last, parent.count >= root.count else { return nil }
            result.append(parent)
        }
        return result.reversed()
    }
    static func version(_ value: String, atLeast minimum: String) -> Bool {
        value.isEmpty || value.compare(minimum, options: .numeric) != .orderedAscending
    }
    static func render(_ value: Any, key: [String]) -> String {
        let safe = Secrets.redacted(value, path: key.joined(separator: "."))
        if let text = safe as? String { return text }
        guard let data = try? JSONSerialization.data(withJSONObject: safe, options: [.fragmentsAllowed, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return Secrets.maskedValue }
        return String(text.prefix(4_000))
    }
    static func analyze(_ context: AnalysisContext, read: (String) -> ConfigDocument?) -> ConfigurationAnalysis {
        var result = ConfigurationAnalysis(context: context)
        result.notices = ["Estimate from files. CLI flags, terminal environment, remote policy and session activation are not observed."]
        if context.version.isEmpty { result.notices.append("Client version not observed; using the documented contract dated " + referenceDate + ".") }
        else { result.notices.append("Client version supplied for this analysis: " + context.version) }
        let root = context.projectRoot
        let cwd = context.workingDirectory.isEmpty ? root : context.workingDirectory
        guard let directories = root.isEmpty ? [] : ancestors(root: root, directory: cwd) else {
            result.notices.append("The working directory must be inside the selected project."); return result
        }
        func add(_ path: String, _ label: String, state: String = "Applied", reason: String = "") {
            let doc = read(path)
            var observation = SourceObservation(path: path, label: label, state: state, reason: reason, tree: nil)
            if let doc {
                if let tree = doc.tree as? [String: Any], doc.parseError == nil { observation.tree = tree }
                else { observation.state = "Unresolved"; observation.reason = "Source is invalid or unavailable for structured inspection." }
            } else {
                observation.state = FileManager.default.fileExists(atPath: path) ? "Unresolved" : "Missing"
                observation.reason = observation.state == "Missing" ? "File does not exist." : "Source was not read; configuration may be incomplete."
            }
            result.sources.append(observation)
        }
        let user = AgentCatalog.root(for: context.agentID)
        var trust = context.trust
        if context.agentID == "codex", trust == .unknown,
           let tree = read(user + "/config.toml")?.tree as? [String: Any],
           let projects = tree["projects"] as? [String: Any] {
            let matching = projects.keys.filter { cwd == $0 || cwd.hasPrefix($0 + "/") }.sorted { $0.count > $1.count }
            if let key = matching.first, let record = projects[key] as? [String: Any], let value = record["trust_level"] as? String {
                trust = value == "trusted" ? .trusted : value == "untrusted" ? .untrusted : .unknown
            }
        }
        switch context.agentID {
        case "codex":
            add(AppPaths.systemPath("/etc/codex/config.toml"), "System defaults")
            add(user + "/config.toml", "User")
            if !context.profile.isEmpty {
                if context.profile.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) == nil {
                    result.notices.append("Invalid profile name.")
                } else if version(context.version, atLeast: "0.134.0") {
                    add(user + "/" + context.profile + ".config.toml", "Profile")
                } else {
                    let profiles = (read(user + "/config.toml")?.tree as? [String: Any])?["profiles"] as? [String: Any]
                    let tree = profiles?[context.profile] as? [String: Any]
                    result.sources.append(.init(path: user + "/config.toml", label: "Legacy profile: " + context.profile,
                        state: tree == nil ? "Missing" : "Applied", reason: "Legacy inline profile", tree: tree))
                }
            }
            for directory in directories {
                add(directory + "/.codex/config.toml", "Project",
                    state: trust == .untrusted ? "Excluded" : trust == .unknown ? "Conditional" : "Applied",
                    reason: trust == .trusted ? "" : "Project layers require trust; trust is " + trust.rawValue.lowercased() + ".")
            }
            add(AppPaths.systemPath("/etc/codex/requirements.toml"), "Constraints", state: "Restriction")
        case "claude-code":
            add(user + "/settings.json", "User")
            if !root.isEmpty {
                add(root + "/.claude/settings.json", "Project")
                add(root + "/.claude/settings.local.json", "Local")
            }
            let managed = AppPaths.systemPath("/Library/Application Support/ClaudeCode")
            let dropins = DiscoveryTree.scan(root: managed + "/managed-settings.d", maxDepth: 0).files.filter { $0.hasSuffix(".json") }
            add(managed + "/managed-settings.json", "Managed", state: dropins.isEmpty ? "Applied" : "Conditional",
                reason: dropins.isEmpty ? "" : "Multiple managed files: composition requires client confirmation.")
            for file in dropins { add(file, "Managed", state: "Unresolved", reason: "Managed drop-in precedence not inferred.") }
        case "gemini-cli":
            let system = AppPaths.systemPath("/Library/Application Support/GeminiCli")
            add(system + "/system-defaults.json", "System defaults")
            add(user + "/settings.json", "User")
            if !root.isEmpty { add(root + "/.gemini/settings.json", "Project") }
            add(system + "/settings.json", "Managed")
        case "opencode":
            for ext in ["json", "jsonc"] { add(user + "/opencode." + ext, "User") }
            if let directory = directories.reversed().first(where: { read($0 + "/opencode.json") != nil || read($0 + "/opencode.jsonc") != nil }) {
                for ext in ["json", "jsonc"] { add(directory + "/opencode." + ext, "Project") }
            }
            for ext in ["json", "jsonc"] { add(AppPaths.systemPath("/Library/Application Support/opencode/opencode." + ext), "Managed") }
            for label in ["User", "Project", "Managed"] {
                let indices = result.sources.indices.filter { result.sources[$0].label == label && result.sources[$0].tree != nil }
                if indices.count > 1 { for index in indices {
                    result.sources[index].state = "Unresolved"
                    result.sources[index].reason = "Both JSON and JSONC exist; confirm the active source in the client."
                } }
            }
            result.notices.append("Remote organization defaults and inline/environment configuration are not observed.")
        case "antigravity":
            add(user + "/config.json", "User", state: "Conditional", reason: "Antigravity version and migration state require client confirmation.")
            result.notices.append("Rules and skills are inspected separately; IDE and CLI settings are not merged speculatively.")
        default:
            result.notices.append("This client has an inventory adapter; settings resolution is not claimed.")
        }
        if result.sources.contains(where: { $0.label == "Constraints" && $0.tree?.keys.contains(where: { !["allowed_approval_policies", "allowed_sandbox_modes", "allowed_permission_profiles"].contains($0) }) == true }) {
            result.notices.append("Additional managed constraints are present. Only approval, sandbox and permission-profile allowlists are evaluated here; inspect Sources for the other restrictions.")
        }
        result.settings = SettingMerger.resolve(result.sources, agentID: context.agentID, version: context.version, trust: trust)
        if result.settings.count >= 500 { result.notices.append("Output limited to 500 settings.") }
        return result
    }
}
