import SwiftUI

/// Why a key in the open file may not be the value the agent ends up with:
/// another layer (managed, project, local…) replaces, restricts or excludes
/// it. Built from the same on-disk precedence analysis as the Configuration
/// view, so it is an estimate, never an observation of a running session.
struct LayerNote: Equatable {
    /// Precedence state of this file's value (Shadowed, Excluded, …).
    let state: String
    let reason: String
    /// Value and file that win instead, when another layer supplies one.
    let effectiveValue: String?
    let effectiveSource: String?
    /// Project the analysis assumed when the open file is a user file.
    let project: String?
}

private struct LayerNotesKey: EnvironmentKey {
    static let defaultValue: [String: LayerNote] = [:]
}

extension EnvironmentValues {
    /// Layer notes for the open file, keyed by dotted key path.
    var layerNotes: [String: LayerNote] {
        get { self[LayerNotesKey.self] }
        set { self[LayerNotesKey.self] = newValue }
    }
}

extension ConfigStore {
    /// Agent and project to analyze for a settings file: a project file is
    /// analyzed within its own project; a user file within the project last
    /// chosen in the sidebar (or globally when there is none).
    func layerContext(for path: String) -> AnalysisContext? {
        // The resolver models ~/.claude and ~/.codex only, not Orca homes.
        guard OrcaIntegration.home(containing: path) == nil,
              let kind = ConfigFileContext.settingsKind(for: path),
              let scope = DocsCatalog.settingsScope(filePath: path) else { return nil }
        var context = AnalysisContext()
        let url = URL(fileURLWithPath: path)
        switch kind {
        case .claude: context.agentID = "claude-code"
        case .codex: context.agentID = "codex"
        case .gemini: context.agentID = "gemini-cli"
        case .opencode: context.agentID = "opencode"
        }
        if scope == .user {
            context.projectRoot = preferredAnalysisProject
        } else {
            // `<project>/.claude/settings.json` → `<project>`; OpenCode keeps
            // its file directly in the project folder.
            let folder = url.deletingLastPathComponent()
            context.projectRoot = (kind == .opencode ? folder : folder.deletingLastPathComponent()).path
        }
        context.workingDirectory = context.projectRoot
        return context
    }

    func layerNotes(for path: String) -> [String: LayerNote] {
        guard let context = layerContext(for: path) else { return [:] }
        let analysis = configurationAnalysis(context)
        let target = AppPaths.canonicalPath(path) ?? path
        let project = DocsCatalog.settingsScope(filePath: path) == .user && !context.projectRoot.isEmpty
            ? projectLabel(context.projectRoot) : nil
        var notes: [String: LayerNote] = [:]
        for setting in analysis.settings {
            let own = setting.origins.last { (AppPaths.canonicalPath($0.source) ?? $0.source) == target }
            guard let own, ["Shadowed", "Excluded", "Restricted", "Conditional", "Unresolved"].contains(own.state) else { continue }
            let winner = setting.origins.last {
                ["Applied", "Conditional", "Merged"].contains($0.state)
                    && (AppPaths.canonicalPath($0.source) ?? $0.source) != target
            }
            let reason = own.reason.isEmpty
                ? (own.state == "Shadowed" ? "A higher-precedence layer sets this key." : "")
                : own.reason
            notes[setting.name] = LayerNote(state: own.state, reason: reason,
                                            effectiveValue: winner == nil ? nil : setting.value,
                                            effectiveSource: winner?.source, project: project)
        }
        return notes
    }
}
