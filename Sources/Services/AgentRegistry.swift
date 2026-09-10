import Foundation
import SwiftUI

/// Declarative catalog: each agent = detection paths + a list of config sources.
/// Sources can be single files or directories enumerated with a glob.
enum AgentRegistry {

    static let definitions: [AgentDefinition] = [

        AgentDefinition(
            id: "claude-code",
            name: "Claude Code",
            symbol: "sparkle",
            color: Color(red: 0.82, green: 0.51, blue: 0.35),
            detectionPaths: ["~/.claude", "~/.claude.json"],
            sources: [
                .init(path: "~/.claude/settings.json", role: .settings,
                      note: "Ajustes globales de usuario"),
                .init(path: "~/.claude/CLAUDE.md", role: .instructions,
                      note: "Instrucciones globales (memoria)"),
                .init(path: "~/.claude/mcp.json", role: .mcp),
                .init(path: "~/.claude/hooks", isDirectory: true, role: .hooks,
                      note: "Scripts de hooks"),
                .init(path: "~/.claude/skills", isDirectory: true, glob: "*/SKILL.md", role: .skills),
                .init(path: "~/.claude/agents", isDirectory: true, role: .agents),
                .init(path: "~/.claude/commands", isDirectory: true, role: .other,
                      note: "Comandos personalizados"),
                .init(path: "~/.claude/statusline.sh", role: .other, note: "Status line"),
                .init(path: "~/.claude/plugins/config.json", role: .plugins),
                .init(path: "~/.claude/plugins/installed_plugins.json", role: .plugins),
                .init(path: "~/.claude.json", role: .state, volatile: true,
                      note: "Estado global + MCP servers (muy activo, solo vista en vivo)"),
            ],
            notes: "Precedencia: managed > local > proyecto > usuario. Los MCP globales viven en ~/.claude.json → mcpServers."
        ),

        AgentDefinition(
            id: "codex",
            name: "Codex",
            symbol: "terminal",
            color: Color(red: 0.24, green: 0.52, blue: 0.94),
            detectionPaths: ["~/.codex"],
            sources: [
                .init(path: "~/.codex/config.toml", role: .settings,
                      note: "Config principal (TOML): modelo, sandbox, MCP, plugins, proyectos"),
                .init(path: "~/.codex/AGENTS.md", role: .instructions,
                      note: "Instrucciones globales"),
                .init(path: "~/.codex/hooks.json", role: .hooks),
                .init(path: "~/.codex/rules", isDirectory: true, glob: "*.rules", role: .permissions,
                      note: "Reglas de prefijos (allow/deny)"),
                .init(path: "~/.codex/agents", isDirectory: true, role: .agents),
                .init(path: "~/.codex/skills", isDirectory: true, glob: "*/SKILL.md", role: .skills),
                .init(path: "~/.codex/prompts", isDirectory: true, role: .other),
                .init(path: "~/.codex/auth.json", role: .state, volatile: true, readOnly: true,
                      note: "Credenciales — solo lectura"),
            ],
            notes: "Perfiles: ~/.codex/<nombre>.config.toml. Overrides por proyecto en .codex/config.toml."
        ),

        AgentDefinition(
            id: "antigravity",
            name: "Antigravity / Gemini",
            symbol: "globe",
            color: Color(red: 0.32, green: 0.55, blue: 0.95),
            detectionPaths: ["~/.gemini"],
            sources: [
                .init(path: "~/.gemini/settings.json", role: .settings,
                      note: "Gemini CLI / compartido"),
                .init(path: "~/.gemini/GEMINI.md", role: .instructions),
                .init(path: "~/.gemini/config/mcp_config.json", role: .mcp,
                      note: "MCP compartido (post-migración 2.0)"),
                .init(path: "~/.gemini/config/config.json", role: .settings,
                      note: "Plugins + userSettings"),
                .init(path: "~/.gemini/antigravity/mcp_config.json", role: .mcp,
                      note: "Legacy (pre-migración): puede estar ignorado"),
                .init(path: "~/Library/Application Support/Antigravity/User/settings.json",
                      role: .settings, note: "Ajustes del IDE (estilo VS Code)"),
                .init(path: "~/.gemini/config/skills", isDirectory: true, glob: "*/SKILL.md",
                      role: .skills),
                .init(path: "~/.gemini/trustedFolders.json", role: .permissions),
            ],
            notes: "Antigravity app, IDE y CLI comparten ~/.gemini/config tras la migración (marca: .migrated)."
        ),

        AgentDefinition(
            id: "opencode",
            name: "OpenCode",
            symbol: "chevron.left.forwardslash.chevron.right",
            color: Color(red: 0.56, green: 0.36, blue: 0.92),
            detectionPaths: ["~/.config/opencode"],
            sources: [
                .init(path: "~/.config/opencode/opencode.json", role: .settings,
                      note: "Providers, modelos y MCP"),
                .init(path: "~/.config/opencode/AGENTS.md", role: .instructions),
                .init(path: "~/.config/opencode/plugins", isDirectory: true, role: .plugins),
            ],
            notes: "Declara $schema — validable contra https://opencode.ai/config.json."
        ),
    ]

    /// Detect installed agents and resolve their file lists.
    static func detect() -> [Agent] {
        let fm = FileManager.default
        return definitions.compactMap { def in
            guard let hit = def.detectionPaths.first(where: {
                fm.fileExists(atPath: ($0 as NSString).expandingTildeInPath)
            }) else { return nil }
            return Agent(
                id: def.id, name: def.name, symbol: def.symbol, color: def.color,
                files: resolveFiles(def), detectionPath: hit, notes: def.notes
            )
        }
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
                for child in enumerateDirectory(path: path, glob: src.glob) {
                    files.append(makeTracked(path: child, src: src, exists: true))
                }
            } else {
                files.append(makeTracked(path: path, src: src, exists: exists))
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func makeTracked(path: String, src: ConfigSource, exists: Bool) -> TrackedFile {
        var size: Int64 = 0
        var mtime: Date? = nil
        var realExists = exists
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            mtime = attrs[.modificationDate] as? Date
            realExists = true
        }
        return TrackedFile(
            path: path,
            format: src.format ?? inferFormat(path: path),
            role: src.role,
            volatile: src.volatile,
            readOnly: src.readOnly,
            note: src.note,
            exists: realExists,
            size: size,
            mtime: mtime
        )
    }

    /// Enumerate a directory; glob patterns like "*.json" or "*/SKILL.md".
    private static func enumerateDirectory(path: String, glob: String?) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        var out: [String] = []
        let pattern = glob ?? "*"

        func match(_ name: String, _ pat: String) -> Bool {
            if pat == "*" { return true }
            if pat.hasPrefix("*."), let ext = pat.split(separator: ".").last {
                return name.hasSuffix(".\(ext)")
            }
            return name == pat
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

    static func inferFormat(path: String) -> ConfigFormat {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        switch (name as NSString).pathExtension {
        case "json": return .json
        case "toml": return .toml
        case "md", "markdown": return .markdown
        case "sh", "bash", "zsh": return .shell
        case "rules": return .dsl
        case "plist": return .plist
        case "pb": return .binary
        case "jsonl": return .jsonc
        default:
            return .text
        }
    }
}
