import Foundation

/// File identity shared by diagnostics and documentation. Matches complete
/// relative path components, independently of user/project location.
enum ConfigFileContext {
    enum SettingsKind { case claude, codex, gemini, opencode }

    static func matches(_ path: String, suffix: String) -> Bool {
        path == suffix || path.hasSuffix("/" + suffix)
    }

    static func settingsKind(for path: String) -> SettingsKind? {
        if matches(path, suffix: ".claude/settings.json") || matches(path, suffix: ".claude/settings.local.json") { return .claude }
        if matches(path, suffix: ".codex/config.toml") { return .codex }
        if matches(path, suffix: ".gemini/settings.json") { return .gemini }
        if matches(path, suffix: "opencode.json") || matches(path, suffix: "opencode.jsonc") { return .opencode }
        for (id, filename, kind) in [("claude-code", "settings.json", SettingsKind.claude),
                                     ("codex", "config.toml", .codex), ("gemini-cli", "settings.json", .gemini),
                                     ("opencode", "opencode.json", .opencode), ("opencode", "opencode.jsonc", .opencode)] {
            if path == (AgentCatalog.root(for: id) as NSString).appendingPathComponent(filename) { return kind }
        }
        return nil
    }

    static func isUserFile(_ path: String, relativePath: String) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.path ==
            URL(fileURLWithPath: AppPaths.home).appendingPathComponent(relativePath).standardizedFileURL.path
    }
}
