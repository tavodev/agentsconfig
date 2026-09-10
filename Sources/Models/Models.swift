import Foundation
import SwiftUI

// MARK: - Format & roles

enum ConfigFormat: String, CaseIterable {
    case json, jsonc, toml, markdown, shell, dsl, plist, text, binary

    var badge: String { rawValue.uppercased() }

    var badgeColor: Color {
        switch self {
        case .json, .jsonc: return .blue
        case .toml: return .orange
        case .markdown: return .purple
        case .shell: return .green
        case .dsl: return .pink
        case .plist: return .gray
        case .binary: return .brown
        case .text: return .secondary
        }
    }

    var isStructured: Bool { self == .json || self == .jsonc || self == .toml }
    var isTextEditable: Bool { self != .binary }
}

enum TrackedRole: String {
    case settings, instructions, mcp, hooks, permissions, skills, agents, plugins, state, other

    var label: String {
        switch self {
        case .settings: return "Ajustes"
        case .instructions: return "Instrucciones"
        case .mcp: return "MCP"
        case .hooks: return "Hooks"
        case .permissions: return "Permisos"
        case .skills: return "Skills"
        case .agents: return "Subagentes"
        case .plugins: return "Plugins"
        case .state: return "Estado"
        case .other: return "Otro"
        }
    }

    var icon: String {
        switch self {
        case .settings: return "gearshape"
        case .instructions: return "doc.text"
        case .mcp: return "network"
        case .hooks: return "hook"
        case .permissions: return "lock.shield"
        case .skills: return "sparkles"
        case .agents: return "person.2"
        case .plugins: return "puzzlepiece"
        case .state: return "memorychip"
        case .other: return "doc"
        }
    }
}

// MARK: - Declarative source description

struct ConfigSource: Hashable {
    var path: String
    var isDirectory = false
    var glob: String? = nil          // e.g. "*.json" / "*/SKILL.md" inside a directory
    var format: ConfigFormat? = nil  // override; nil = infer from extension
    var role: TrackedRole = .other
    var volatile = false             // state files: watched live, but no history/badge noise
    var readOnly = false
    var note: String? = nil

    var expandedPath: String { (path as NSString).expandingTildeInPath }
}

// MARK: - Agent catalog entry

struct AgentDefinition {
    var id: String
    var name: String
    var symbol: String
    var color: Color
    var detectionPaths: [String]
    var sources: [ConfigSource]
    var notes: String? = nil
}

// MARK: - Resolved runtime models

struct TrackedFile: Identifiable, Hashable {
    var id: String { path }
    var path: String
    var format: ConfigFormat
    var role: TrackedRole
    var volatile: Bool
    var readOnly: Bool
    var note: String?
    var exists: Bool
    var size: Int64
    var mtime: Date?
    var issues: [FileIssue] = []
    var managedBlocks: [ManagedBlock] = []

    var displayName: String { URL(fileURLWithPath: path).lastPathComponent }
    var shortPath: String { path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
}

struct Agent: Identifiable {
    var id: String
    var name: String
    var symbol: String
    var color: Color
    var files: [TrackedFile]
    var detectionPath: String
    var notes: String?

    var issueCount: Int { files.reduce(0) { $0 + $1.issues.count } }
    var editableCount: Int { files.filter { $0.format.isTextEditable }.count }
}

struct ManagedBlock: Hashable {
    var owner: String        // e.g. "Orca", "GitKraken"
    var detail: String
}

struct FileIssue: Hashable {
    enum Severity { case warning, error, info }
    var severity: Severity
    var message: String
}

struct SemanticChange: Identifiable, Hashable {
    enum Kind: String { case added = "Añadido", removed = "Eliminado", modified = "Modificado" }
    var id = UUID()
    var keyPath: String
    var kind: Kind
    var oldValue: String?
    var newValue: String?
}

struct FileVersion: Identifiable, Hashable {
    var id: String { file }
    var date: Date
    var hash: String
    var file: String            // content file name inside the history dir
    var origin: Origin
    var changeCount: Int
    var summary: String

    enum Origin: String, Codable { case baseline, external, app, revert }
}

struct ExternalChange: Identifiable {
    var id = UUID()
    var date = Date()
    var changes: [SemanticChange]
    var previousContent: String?     // kept in memory for revert
}

/// One entry in the cross-agent activity feed.
struct ActivityEvent: Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var path: String
    var agentID: String?
    var agentName: String
    var origin: FileVersion.Origin
    var summary: String
    var changeCount: Int
    var changes: [SemanticChange] = []   // populated for in-session events
}

// MARK: - Live document

struct ConfigDocument {
    var text: String
    var tree: Any?
    var parseError: String?
    var loadedAt: Date
    var hash: String
}
