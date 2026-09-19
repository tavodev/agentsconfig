import Foundation
import SwiftUI

/// Additional source contracts, verified against official documentation on
/// 2026-09-13. Inventory is separate from configuration/session resolution.
enum AgentCatalog {
    static let defaultRoots = ["claude-code": "~/.claude", "codex": "~/.codex", "gemini-cli": "~/.gemini",
                               "antigravity": "~/.gemini/config", "opencode": "~/.config/opencode",
                               "cursor": "~/.cursor", "copilot-cli": "~/.copilot"]
    static func root(for id: String) -> String {
        let overrides = AppSettings.defaults.dictionary(forKey: "agentConfigRoots") as? [String: String] ?? [:]
        return AppPaths.expand(overrides[id] ?? defaultRoots[id] ?? "~")
    }
    static func expanding(_ base: [AgentDefinition]) -> [AgentDefinition] {
        var definitions = base
        func file(_ path: String, _ role: TrackedRole, readOnly: Bool = false) -> ConfigSource {
            .init(path: path, role: role, readOnly: readOnly)
        }
        func tree(_ path: String, _ glob: String, _ role: TrackedRole, readOnly: Bool = false) -> ConfigSource {
            .init(path: path, isDirectory: true, glob: glob, role: role, readOnly: readOnly, recursive: true)
        }
        definitions[0].sources += [tree("~/.claude/rules", "*.md", .instructions),
            tree("~/.claude/plugins/cache", "SKILL.md", .skills, readOnly: true)]
        definitions[0].localSources += [file(".claude/CLAUDE.md", .instructions), file("CLAUDE.local.md", .instructions),
            tree(".claude/rules", "*.md", .instructions), tree(".claude/hooks", "*", .hooks)]
        definitions[1].sources += [file("~/.codex/AGENTS.override.md", .instructions),
            .init(path: "~/.codex", isDirectory: true, glob: "*.config.toml", role: .settings, note: "Named profile — selected by the client"),
            .init(path: "~/.agents/skills", isDirectory: true, glob: "*/SKILL.md", role: .skills),
            tree("~/.codex/plugins/cache", "SKILL.md", .skills, readOnly: true)]
        definitions[1].localSources += [file("AGENTS.override.md", .instructions), file(".codex/hooks.json", .hooks),
            tree(".codex/rules", "*.rules", .permissions)]
        let oldGemini = definitions.remove(at: 2)
        var gemini = oldGemini
        gemini.id = "gemini-cli"; gemini.name = "Gemini CLI"; gemini.symbol = "sparkles"
        gemini.detectionPaths = ["~/.gemini/settings.json", "~/.gemini/skills", "~/.gemini/extensions"]
        gemini.sources = [file("~/.gemini/settings.json", .settings), file("~/.gemini/GEMINI.md", .instructions),
            file("~/.gemini/trustedFolders.json", .permissions),
            .init(path: "~/.gemini/skills", isDirectory: true, glob: "*/SKILL.md", role: .skills),
            .init(path: "~/.agents/skills", isDirectory: true, glob: "*/SKILL.md", role: .skills),
            tree("~/.gemini/policies", "*.toml", .permissions), tree("~/.gemini/commands", "*.toml", .other),
            tree("~/.gemini/extensions", "gemini-extension.json", .plugins, readOnly: true),
            tree("~/.gemini/extensions", "SKILL.md", .skills, readOnly: true),
            tree("~/.gemini/agents", "*.md", .agents)]
        gemini.localSources += [tree(".gemini/policies", "*.toml", .permissions), tree(".gemini/commands", "*.toml", .other),
            tree(".gemini/agents", "*.md", .agents),
            .init(path: ".gemini/skills", isDirectory: true, glob: "*/SKILL.md", role: .skills),
            .init(path: ".agents/skills", isDirectory: true, glob: "*/SKILL.md", role: .skills)]
        gemini.notes = "Gemini CLI configuration found on disk. Extension and policy activation is not verified."
        var antigravity = oldGemini
        antigravity.name = "Antigravity"
        antigravity.detectionPaths = ["~/.gemini/config", "~/.gemini/antigravity", "~/Library/Application Support/Antigravity"]
        antigravity.sources = oldGemini.sources.filter { !["~/.gemini/settings.json", "~/.gemini/trustedFolders.json"].contains($0.path) }
        antigravity.sources += [tree("~/.gemini/config/workflows", "*.md", .other)]
        antigravity.localSources = [file("GEMINI.md", .instructions), tree(".agents/rules", "*.md", .instructions),
            tree(".agent/rules", "*.md", .instructions), tree(".agents/workflows", "*.md", .other),
            tree(".agent/workflows", "*.md", .other),
            .init(path: ".agents/skills", isDirectory: true, glob: "*/SKILL.md", role: .skills)]
        antigravity.mcpDestinationPaths = []
        antigravity.notes = "Antigravity sources are separate from Gemini CLI. Legacy files are inspected without assuming they are loaded."
        definitions.insert(contentsOf: [gemini, antigravity], at: 2)
        let open = definitions.firstIndex { $0.id == "opencode" }!
        for (directory, glob, role) in [("agents", "*.md", TrackedRole.agents), ("commands", "*.md", .other),
                                       ("skills", "SKILL.md", .skills), ("plugins", "*", .plugins), ("tools", "*", .other)] {
            definitions[open].sources.append(tree("~/.config/opencode/" + directory, glob, role))
            definitions[open].localSources.append(tree(".opencode/" + directory, glob, role))
        }
        definitions[open].sources += [file("~/.config/opencode/tui.json", .settings),
            .init(path: "~/.agents/skills", isDirectory: true, glob: "*/SKILL.md", role: .skills),
            .init(path: "~/.claude/skills", isDirectory: true, glob: "*/SKILL.md", role: .skills)]
        definitions[open].localSources += [.init(path: ".agents/skills", isDirectory: true, glob: "*/SKILL.md", role: .skills),
            .init(path: ".claude/skills", isDirectory: true, glob: "*/SKILL.md", role: .skills), file("tui.json", .settings)]
        definitions.append(AgentDefinition(id: "cursor", name: "Cursor", symbol: "cursorarrow", color: .gray,
            detectionPaths: ["~/.cursor"], sources: [file("~/.cursor/mcp.json", .mcp, readOnly: true),
                file("~/.cursor/cli-config.json", .settings, readOnly: true),
                tree("~/.cursor/skills", "SKILL.md", .skills, readOnly: true),
                tree("~/.cursor/agents", "*.md", .agents, readOnly: true), file("~/.cursor/hooks.json", .hooks, readOnly: true)],
            localSources: [file(".cursor/mcp.json", .mcp, readOnly: true), tree(".cursor/rules", "*.mdc", .instructions, readOnly: true),
                tree(".cursor/skills", "SKILL.md", .skills, readOnly: true), tree(".cursor/agents", "*.md", .agents, readOnly: true),
                file(".cursor/hooks.json", .hooks, readOnly: true), file("AGENTS.md", .instructions, readOnly: true)],
            notes: "Read-only inventory. Dashboard/team rules, runtime interpolation and session activation are not observed."))
        definitions.append(AgentDefinition(id: "copilot-cli", name: "Copilot CLI", symbol: "chevron.left.forwardslash.chevron.right", color: .indigo,
            detectionPaths: ["~/.copilot"], sources: [.init(path: "~/.copilot/settings.json", format: .jsonc, role: .settings, readOnly: true),
                .init(path: "~/.copilot/config.json", role: .state, volatile: true, excludeFromHistory: true, readOnly: true),
                .init(path: "~/.copilot/providers.json", role: .settings, excludeFromHistory: true, readOnly: true),
                file("~/.copilot/mcp-config.json", .mcp, readOnly: true), file("~/.copilot/permissions-config.json", .permissions, readOnly: true),
                file("~/.copilot/copilot-instructions.md", .instructions, readOnly: true), tree("~/.copilot/instructions", "*.instructions.md", .instructions, readOnly: true),
                tree("~/.copilot/skills", "SKILL.md", .skills, readOnly: true), tree("~/.copilot/agents", "*.agent.md", .agents, readOnly: true),
                tree("~/.copilot/installed-plugins", "SKILL.md", .skills, readOnly: true), tree("~/.copilot/installed-plugins", "mcp.json", .mcp, readOnly: true)],
            localSources: [file(".github/copilot-instructions.md", .instructions, readOnly: true),
                tree(".github/instructions", "*.instructions.md", .instructions, readOnly: true), tree(".github/agents", "*.agent.md", .agents, readOnly: true),
                tree(".github/skills", "SKILL.md", .skills, readOnly: true), file(".mcp.json", .mcp, readOnly: true),
                file(".github/mcp.json", .mcp, readOnly: true), file("AGENTS.md", .instructions, readOnly: true),
                file("CLAUDE.md", .instructions, readOnly: true), file("GEMINI.md", .instructions, readOnly: true)],
            notes: "Copilot CLI read-only inventory. IDE/cloud Copilot policies and runtime permission decisions are not inferred."))
        let managed: [String: [ConfigSource]] = [
            "claude-code": [file("/Library/Application Support/ClaudeCode/managed-settings.json", .settings, readOnly: true),
                file("/Library/Application Support/ClaudeCode/managed-mcp.json", .mcp, readOnly: true),
                file("/Library/Application Support/ClaudeCode/CLAUDE.md", .instructions, readOnly: true),
                tree("/Library/Application Support/ClaudeCode/managed-settings.d", "*.json", .settings, readOnly: true)],
            "codex": [file("/etc/codex/config.toml", .settings, readOnly: true), file("/etc/codex/requirements.toml", .permissions, readOnly: true),
                tree("/etc/codex/skills", "SKILL.md", .skills, readOnly: true)],
            "gemini-cli": [file("/Library/Application Support/GeminiCli/system-defaults.json", .settings, readOnly: true),
                file("/Library/Application Support/GeminiCli/settings.json", .settings, readOnly: true),
                tree("/Library/Application Support/GeminiCli/policies", "*.toml", .permissions, readOnly: true)],
            "opencode": [file("/Library/Application Support/opencode/opencode.json", .settings, readOnly: true),
                file("/Library/Application Support/opencode/opencode.jsonc", .settings, readOnly: true)]
        ]
        for index in definitions.indices {
            let id = definitions[index].id
            if let original = defaultRoots[id] {
                let custom = root(for: id)
                func replace(_ path: String) -> String {
                    path == original ? custom : path.hasPrefix(original + "/") ? custom + path.dropFirst(original.count) : path
                }
                definitions[index].sources = definitions[index].sources.map { source in var source = source; source.path = replace(source.path); return source }
                definitions[index].detectionPaths = definitions[index].detectionPaths.map(replace)
                definitions[index].mcpDestinationPaths = definitions[index].mcpDestinationPaths.map(replace)
            }
            for var source in managed[id] ?? [] {
                source.path = AppPaths.systemPath(source.path)
                source.note = "Managed system source — read-only; remote/MDM policies are not observed"
                definitions[index].sources.append(source)
            }
        }
        return definitions
    }
}
