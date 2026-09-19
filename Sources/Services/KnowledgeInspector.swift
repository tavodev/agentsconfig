import Foundation

@MainActor enum KnowledgeInspector {
    static func build(context: AnalysisContext, agents: [Agent], configuration: ConfigurationAnalysis,
                      read: (String) -> String?) -> KnowledgeAnalysis {
        var output = KnowledgeAnalysis()
        let root = context.projectRoot
        let cwd = context.workingDirectory.isEmpty ? root : context.workingDirectory
        guard let directories = root.isEmpty ? [] : ConfigurationResolver.ancestors(root: root, directory: cwd) else {
            output.notices.append("The working directory must be inside the selected project."); return output
        }
        let familyAgents = agents.filter {
            $0.id.components(separatedBy: "::").first == context.agentID && ($0.projectRoot == nil || $0.projectRoot == root)
        }
        var seen = Set<String>()
        for file in familyAgents.flatMap(\.files) where file.exists && file.role == .skills {
            guard seen.insert(file.path).inserted, seen.count <= 1_000, let text = read(file.path) else { continue }
            let folder = (file.path as NSString).deletingLastPathComponent
            let local = !root.isEmpty && file.path.hasPrefix(root + "/")
            let markers = ["/.agents/skills/", "/.claude/skills/", "/.gemini/skills/", "/.opencode/skills/"]
            if local, let marker = markers.first(where: { file.path.contains($0) }), let range = file.path.range(of: marker) {
                let declaring = String(file.path[..<range.lowerBound])
                if cwd != declaring && !cwd.hasPrefix(declaring + "/") { continue }
            }
            let parsed = Frontmatter.parse(text)
            let header = parsed.header
            let name = header?.name ?? URL(fileURLWithPath: folder).lastPathComponent
            var issues: [String] = []
            if let issue = parsed.issue { issues.append(issue) }
            if header == nil { issues.append("A skill requires YAML frontmatter with name and description.") }
            if name.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) == nil || name.count > 64 {
                issues.append("Skill name must use lowercase letters, digits and single hyphens, up to 64 characters.")
            }
            if header?.name != nil, name != URL(fileURLWithPath: folder).lastPathComponent { issues.append("Skill name differs from its folder name.") }
            if header?.description?.isEmpty != false || (header?.description?.count ?? 0) > 1_024 { issues.append("Skill description is missing or exceeds 1,024 characters.") }
            if parsed.body.components(separatedBy: "\n").count > 500 { issues.append("Consider moving long instructions into referenced resources.") }
            let tree = DiscoveryTree.scan(root: folder)
            if tree.truncated { issues.append("Package inspection reached its traversal limit.") }
            if tree.skippedLinks > 0 { issues.append("Package contains links that were not traversed.") }
            var resources = tree.files.filter { $0 != file.path }.prefix(500).map {
                KnowledgeResource(path: $0, name: String($0.dropFirst(folder.count + 1)), state: "Available")
            }
            for ref in references(in: parsed.body, importsOnly: false).prefix(500) {
                let path = (folder as NSString).appendingPathComponent(ref)
                guard !resources.contains(where: { $0.path == path }) else { continue }
                let safe = safeReference(ref, base: folder, boundary: folder)
                resources.append(.init(path: safe ?? path, name: ref, state: safe == nil ? "Outside scope" :
                    FileManager.default.fileExists(atPath: safe!) ? "Available" : "Missing"))
            }
            let consumers = Array(Set(agents.filter { $0.files.contains { $0.path == file.path } }
                .map { $0.name.components(separatedBy: " (").first ?? $0.name })).sorted()
            let plugin = file.path.contains("/plugins/") || file.path.contains("/extensions/")
            let system = file.readOnly && !plugin
            var metadata: [String: String] = [:]
            if let header {
                metadata["License"] = header.license
                metadata["Compatibility"] = header.compatibility
                metadata["Allowed tools"] = header.allowedTools?.values.joined(separator: ", ")
                metadata["User invocable"] = header.userInvocable.map { String($0) }
                metadata["Automatic invocation disabled"] = header.disableModelInvocation.map { String($0) }
            }
            metadata = metadata.mapValues { Secrets.displayText($0, masking: true) }
            let rank = context.agentID == "claude-code" ? (system ? 40 : plugin ? 10 : local ? 20 : 30) : (system ? 5 : plugin ? 10 : local ? 30 : 20)
            output.skills.append(.init(path: file.path, name: Secrets.displayText(name, masking: true),
                description: Secrets.displayText(header?.description ?? "", masking: true), metadata: metadata, consumers: consumers,
                state: plugin ? "Activation not verified" : header?.disableModelInvocation == true ? "Manual invocation" : "Discovered",
                issues: issues, resources: resources, bytes: text.utf8.count,
                body: Secrets.maskText(String(parsed.body.prefix(20_000)), format: .markdown, masking: true),
                rank: rank + (file.path.contains("/.agents/skills/") && context.agentID == "gemini-cli" ? 1 : 0)))
        }
        let groups = Dictionary(grouping: output.skills.indices, by: { output.skills[$0].name })
        for indices in groups.values where indices.count > 1 {
            let highest = indices.map { output.skills[$0].rank }.max()!
            let winners = indices.filter { output.skills[$0].rank == highest }
            for index in indices {
                if context.agentID == "codex" {
                    output.skills[index].issues.append("Duplicate name: Codex can expose both skills; definitions are not merged.")
                } else if ["claude-code", "gemini-cli"].contains(context.agentID), winners.count == 1 {
                    output.skills[index].state = index == winners[0] ? "Preferred by scope" : "Shadowed by scope"
                } else { output.skills[index].issues.append("Duplicate name: precedence is not established for this client and scope.") }
            }
        }
        if seen.count > 1_000 { output.notices.append("Skill inspection limited to 1,000 packages.") }
        output.skills.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let configuredLimit = configuration.settings.first { $0.key == ["project_doc_max_bytes"] }.flatMap { Int($0.value) }
        let byteLimit = context.agentID == "codex" ? min(2_000_000, max(0, configuredLimit ?? 32_768)) : 2_000_000
        func configuredStrings(_ key: [String]) -> [String] {
            guard let value = configuration.settings.first(where: { $0.key == key })?.value else { return [] }
            if let data = value.data(using: .utf8), let strings = try? JSONSerialization.jsonObject(with: data) as? [String] { return strings }
            return [value]
        }
        let exclusions = context.agentID == "claude-code" ? configuredStrings(["claudeMdExcludes"]) : []
        var consumed = 0
        var instructionSeen = Set<String>()
        func add(_ path: String, state: String = "Candidate", reason: String = "", boundary: String, importedBy: String? = nil, depth: Int = 0) {
            guard output.instructions.count < 100 else { return }
            guard let canonicalTarget = AppPaths.canonicalPath(path), let canonicalBoundary = AppPaths.canonicalPath(boundary),
                  canonicalTarget.hasPrefix(canonicalBoundary + "/") else {
                output.instructions.append(.init(path: path, state: "Outside scope", reason: "Instruction path leaves its allowed root.", bytes: 0, includedBytes: 0, text: "", importedBy: importedBy)); return
            }
            if exclusions.contains(where: { KnowledgeGlob.matches(path, pattern: $0) == true || KnowledgeGlob.matches(canonicalTarget, pattern: $0) == true }) {
                output.instructions.append(.init(path: path, state: "Excluded", reason: "Matched claudeMdExcludes.", bytes: 0, includedBytes: 0, text: "", importedBy: importedBy)); return
            }
            guard let text = read(path) else {
                if importedBy != nil { output.instructions.append(.init(path: path, state: "Missing", reason: "Referenced instruction was not read.", bytes: 0, includedBytes: 0, text: "", importedBy: importedBy)) }
                return
            }
            let canonical = AppPaths.canonicalPath(path) ?? path
            guard instructionSeen.insert(canonical).inserted else {
                output.instructions.append(.init(path: path, state: "Already included", reason: "Repeated reference or import cycle.", bytes: 0, includedBytes: 0, text: "", importedBy: importedBy)); return
            }
            let parsed = Frontmatter.parse(text)
            var status = state
            var explanation = reason
            if let issue = parsed.issue { status = "Unresolved"; explanation = issue }
            let patterns = parsed.header?.paths?.values ?? parsed.header?.globs?.values ?? parsed.header?.applyTo?.values.flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } ?? []
            if !patterns.isEmpty {
                if context.targetFile.isEmpty { status = "Conditional"; explanation = "Path-scoped instructions need a target file." }
                else {
                    let matches = patterns.map { KnowledgeGlob.matches(context.targetFile, pattern: $0) }
                    status = matches.contains(true) ? "Candidate" : matches.contains(nil) ? "Conditional" : "Not applicable"
                    explanation = "Path patterns: " + patterns.joined(separator: ", ")
                }
            }
            if parsed.header?.alwaysApply == false && patterns.isEmpty { status = "Conditional"; explanation = "Manual or model-selected rule." }
            let bytes = text.utf8.count
            let eligible = !["Not applicable", "Replaced", "Unresolved", "Outside scope"].contains(status)
            let included = eligible ? min(bytes, max(0, byteLimit - consumed)) : 0
            if eligible && included < bytes { status = "Truncated"; explanation = "Instruction byte budget reached." }
            consumed += included
            output.instructions.append(.init(path: path, state: status, reason: explanation, bytes: bytes, includedBytes: included,
                text: Secrets.maskText(String(text.prefix(20_000)), format: .markdown, masking: true), importedBy: importedBy))
            guard included > 0, depth < 5, ["claude-code", "gemini-cli", "copilot-cli", "antigravity"].contains(context.agentID) else { return }
            for ref in references(in: parsed.body, importsOnly: true).prefix(100) {
                guard output.instructions.count < 100 else { break }
                guard let target = safeReference(ref, base: (path as NSString).deletingLastPathComponent, boundary: boundary) else {
                    output.instructions.append(.init(path: ref, state: "Outside scope", reason: "External import is shown but was not read.",
                        bytes: 0, includedBytes: 0, text: "", importedBy: path)); continue
                }
                add(target, boundary: boundary, importedBy: path, depth: depth + 1)
            }
        }
        let user = AgentCatalog.root(for: context.agentID)
        if context.agentID == "codex" {
            for directory in [user] + directories {
                var names = ["AGENTS.override.md", "AGENTS.md"]
                if let array = configuration.settings.first(where: { $0.key == ["project_doc_fallback_filenames"] })?.value,
                   let data = array.data(using: .utf8), let fallback = try? JSONSerialization.jsonObject(with: data) as? [String] {
                    names += fallback.filter { !$0.contains("/") && !$0.contains("\\") && $0 != ".." }
                }
                let present = names.filter { read(directory + "/" + $0)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
                for (index, name) in present.enumerated() {
                    add(directory + "/" + name, state: index == 0 ? "Candidate" : "Replaced",
                        reason: index == 0 ? "First nonempty instruction file in this directory." : "An override or earlier filename takes precedence.",
                        boundary: directory == user ? user : root)
                }
            }
        } else {
            let name = context.agentID == "claude-code" ? "CLAUDE.md" : ["gemini-cli", "antigravity"].contains(context.agentID) ? "GEMINI.md" : "AGENTS.md"
            let geminiNames = configuredStrings(["context", "fileName"])
            let names = context.agentID == "gemini-cli" && !geminiNames.isEmpty ? geminiNames.filter { !$0.contains("/") && !$0.contains("\\") && $0 != ".." } : [name]
            if context.agentID == "antigravity" {
                add(AppPaths.expand("~/.gemini/GEMINI.md"), boundary: AppPaths.expand("~/.gemini"))
            } else if context.agentID == "copilot-cli" {
                add(user + "/copilot-instructions.md", boundary: user)
                output.notices.append("Copilot CLI combines instruction sources without a general precedence order.")
            } else { for name in names { add(user + "/" + name, boundary: user) } }
            for directory in directories {
                for name in names { add(directory + "/" + name, boundary: root) }
                if context.agentID == "claude-code" { add(directory + "/.claude/CLAUDE.md", boundary: root); add(directory + "/CLAUDE.local.md", boundary: root) }
                if context.agentID == "copilot-cli" {
                    for relative in [".github/copilot-instructions.md", "CLAUDE.md", ".claude/CLAUDE.md", "GEMINI.md"] { add(directory + "/" + relative, boundary: root) }
                }
            }
            for file in familyAgents.flatMap(\.files) where file.role == .instructions && file.exists {
                if file.path.contains("/rules/") || file.path.contains("/instructions/") {
                    let local = !root.isEmpty && file.path.hasPrefix(root + "/")
                    add(file.path, state: "Conditional", reason: "Activation depends on the client's rule discovery.",
                        boundary: local ? root : (file.path as NSString).deletingLastPathComponent)
                }
            }
        }
        if context.agentID == "opencode", !root.isEmpty {
            for pattern in configuredStrings(["instructions"]) {
                if pattern.contains("*") || pattern.contains("?") {
                    for path in DiscoveryTree.projectFolders(root: root).files where KnowledgeGlob.matches(String(path.dropFirst(root.count + 1)), pattern: pattern) == true {
                        add(path, reason: "Configured instruction pattern.", boundary: root)
                    }
                } else if let path = safeReference(pattern, base: root, boundary: root) {
                    add(path, reason: "Configured instruction file.", boundary: root)
                } else { output.notices.append("An external instruction reference was not read.") }
            }
        }
        if output.instructions.count >= 100 { output.notices.append("Instruction inspection limited to 100 entries.") }
        output.notices.append("Instruction order and candidate status do not confirm what a model actually loaded. Previews are capped at 20,000 characters.")
        return output
    }
    static func safeReference(_ reference: String, base: String, boundary: String) -> String? {
        guard !reference.contains("://"), !reference.hasPrefix("~"), !reference.hasPrefix("/"),
              let root = AppPaths.canonicalPath(boundary),
              let target = AppPaths.canonicalPath((base as NSString).appendingPathComponent(reference)), target.hasPrefix(root + "/") else { return nil }
        return target
    }
    static func references(in text: String, importsOnly: Bool) -> [String] {
        var text = text
        if importsOnly {
            var fenced = false
            text = text.components(separatedBy: "\n").compactMap { line in
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") || line.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") { fenced.toggle(); return nil }
                return fenced ? nil : line
            }.joined(separator: "\n")
        }
        let pattern = importsOnly ? #"(?m)(?:^|\s)@([^\s`<>()]+)"# :
            #"(?:\]\(([^)\s]+)\)|\b((?:scripts|references|assets|examples)/[^\s`<>()]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
                let value = ns.substring(with: match.range(at: index))
                if value.contains("://") || value.hasPrefix("#") { return nil }
                guard let reference = value.components(separatedBy: "#").first, seen.insert(reference).inserted else { return nil }
                return reference
            }
            return nil
        }
    }
}

