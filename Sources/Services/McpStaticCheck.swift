import Foundation

/// One static finding for an MCP server. `message` is an English `L` key;
/// `detail` fills its `%@` (a command, variable name or path — never a value).
struct McpCheckFinding: Hashable, Identifiable {
    enum Severity: Int, Comparable {
        case info, warning, error
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
        var icon: String {
            switch self {
            case .info: "info.circle"
            case .warning: "exclamationmark.triangle"
            case .error: "xmark.octagon"
            }
        }
    }
    var id: String { message + "\u{0}" + (detail ?? "") }
    let severity: Severity
    let message: String
    var detail: String? = nil
}

/// What the check may look at: executable search path and the *names* of
/// the variables defined in the environment. Values are never kept.
struct McpCheckEnvironment: Equatable {
    enum Origin: String { case app = "App environment", loginShell = "Login shell" }
    var searchPath: [String]
    var variables: Set<String>
    var origin: Origin

    /// A GUI app does not inherit the login shell's PATH: it gets launchd's
    /// short default. Common install locations are appended so `npx`, `uvx`
    /// or Homebrew tools are not reported missing just for that reason.
    static func app(environment: [String: String] = ProcessInfo.processInfo.environment,
                    home: String = AppPaths.home) -> McpCheckEnvironment {
        let base = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        let common = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.cargo/bin",
                      home + "/.bun/bin", home + "/.deno/bin", home + "/.volta/bin"]
        var seen = Set<String>()
        return .init(searchPath: (base + common).filter { seen.insert($0).inserted },
                     variables: Set(environment.keys), origin: .app)
    }

    /// Opt-in (`AppSettings.mcpLoginShellEnvironment`): runs the user's login
    /// shell once with `env -0` to read PATH and variable names. This runs the
    /// shell's startup files — never an MCP server. Returns nil on failure;
    /// the shell is terminated after `timeout`.
    nonisolated static func loginShell(timeout: TimeInterval = 5) -> McpCheckEnvironment? {
        let marker = "AGENTSCONFIG-ENV"
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Interactive too: many users extend PATH in ~/.zshrc. Startup output
        // is skipped by reading only after the marker.
        process.arguments = ["-l", "-i", "-c", "printf '\\0\(marker)\\0'; /usr/bin/env -0"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        nonisolated(unsafe) let running = process
        let watchdog = DispatchWorkItem { if running.isRunning { running.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        watchdog.cancel()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        var variables = Set<String>(), path = ""
        let records = data.split(separator: 0, omittingEmptySubsequences: false)
        guard let start = records.firstIndex(where: { Data($0) == Data(marker.utf8) }) else { return nil }
        for record in records[(start + 1)...] {
            guard let line = String(data: Data(record), encoding: .utf8), let equal = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<equal])
            variables.insert(name)
            if name == "PATH" { path = String(line[line.index(after: equal)...]) }
        }
        guard !path.isEmpty else { return nil }
        return .init(searchPath: path.split(separator: ":").map(String.init), variables: variables, origin: .loginShell)
    }
}

/// Static MCP checks (issue #21): resolvable command, referenced variables,
/// existing `cwd`/path arguments and well-formed remote URLs. Nothing is
/// launched, connected to or authenticated.
@MainActor enum McpStaticCheck {
    /// Variables the clients substitute themselves, never from the environment.
    static let clientVariables: Set<String> = ["CLAUDE_PROJECT_DIR", "CLAUDE_PLUGIN_ROOT", "workspaceFolder",
        "workspaceFolderBasename", "workspaceRoot", "userHome", "pathSeparator", "cwd", "extensionPath"]

    static func check(_ entry: McpServerEntry, environment: McpCheckEnvironment) -> [McpCheckFinding] {
        var findings: [McpCheckFinding] = []
        let raw = entry.raw
        var strings: [String] = entry.args
        if let command = entry.command { strings.append(command) }
        if let url = entry.url { strings.append(url) }
        for key in ["env", "environment", "headers", "http_headers"] {
            if let map = raw[key] as? [String: Any] { strings += map.values.compactMap { $0 as? String } }
        }
        findings += variableFindings(in: strings, environment: environment)
        for key in ["env", "environment"] {
            for (name, value) in (raw[key] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) where (value as? String)?.isEmpty == true {
                findings.append(.init(severity: .warning, message: "Environment variable «%@» is empty.", detail: name))
            }
        }
        // Codex forwards variables by name and reads bearer tokens from one.
        for name in (raw["env_vars"] as? [Any] ?? []).compactMap({ $0 as? String }) + [raw["bearer_token_env_var"] as? String].compactMap({ $0 })
            where !environment.variables.contains(name) {
            findings.append(.init(severity: .warning, message: "Variable «%@» is not set in the inspected environment.", detail: name))
        }

        let cwd = (raw["cwd"] as? String).map(AppPaths.expand)
        if let cwd, !cwd.contains("${") {
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory) || !isDirectory.boolValue {
                findings.append(.init(severity: .error, message: "Working directory «%@» does not exist.", detail: cwd))
            }
        }
        if entry.isRemote {
            findings += urlFindings(entry.url)
        } else {
            findings += commandFindings(entry.command, cwd: cwd, environment: environment)
            for argument in entry.args {
                guard let path = pathArgument(argument), !FileManager.default.fileExists(atPath: path) else { continue }
                findings.append(.init(severity: .warning, message: "Argument path «%@» does not exist.", detail: path))
            }
        }
        var seen = Set<String>()
        return findings.filter { seen.insert($0.id).inserted }.sorted { ($1.severity, $0.id) < ($0.severity, $1.id) }
    }

    /// `${VAR}`, `${env:VAR}` and `${VAR:-default}`; a default or a
    /// client-provided name never counts as missing. `${file:…}` must exist.
    private static func variableFindings(in strings: [String], environment: McpCheckEnvironment) -> [McpCheckFinding] {
        guard let regex = try? NSRegularExpression(pattern: #"\$\{(env:|file:)?([^}:]+)(:-[^}]*)?\}"#) else { return [] }
        var out: [McpCheckFinding] = []
        for text in strings {
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let prefix = match.range(at: 1).location == NSNotFound ? "" : ns.substring(with: match.range(at: 1))
                let name = ns.substring(with: match.range(at: 2))
                if prefix == "file:" {
                    let path = AppPaths.expand(name)
                    if !FileManager.default.fileExists(atPath: path) {
                        out.append(.init(severity: .warning, message: "Referenced file «%@» does not exist.", detail: path))
                    }
                    continue
                }
                guard match.range(at: 3).location == NSNotFound, !clientVariables.contains(name),
                      !environment.variables.contains(name) else { continue }
                out.append(.init(severity: .warning, message: "Variable «%@» is not set in the inspected environment.", detail: name))
            }
        }
        return out
    }

    private static func commandFindings(_ command: String?, cwd: String?, environment: McpCheckEnvironment) -> [McpCheckFinding] {
        guard let command = command?.trimmingCharacters(in: .whitespaces), !command.isEmpty else {
            return [.init(severity: .error, message: "No command is declared.")]
        }
        if command.contains("${") || command.contains("$") {
            return [.init(severity: .info, message: "Command «%@» is interpolated by the client; not resolved.", detail: command)]
        }
        if command.contains("/") {
            var path = AppPaths.expand(command)
            if !path.hasPrefix("/") {
                guard let cwd else {
                    return [.init(severity: .info, message: "Relative command «%@» depends on the client's working directory.", detail: command)]
                }
                path = (cwd as NSString).appendingPathComponent(path)
            }
            if !FileManager.default.fileExists(atPath: path) {
                return [.init(severity: .error, message: "Command «%@» does not exist.", detail: path)]
            }
            return FileManager.default.isExecutableFile(atPath: path) ? []
                : [.init(severity: .error, message: "Command «%@» is not executable.", detail: path)]
        }
        let found = environment.searchPath.contains {
            FileManager.default.isExecutableFile(atPath: ($0 as NSString).appendingPathComponent(command))
        }
        return found ? [] : [.init(severity: .error, message: "Command «%@» was not found in the inspected PATH.", detail: command)]
    }

    private static func urlFindings(_ text: String?) -> [McpCheckFinding] {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return [.init(severity: .error, message: "No server URL is declared.")]
        }
        if text.contains("${") { return [] }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https", "ws", "wss"].contains(scheme), url.host?.isEmpty == false else {
            return [.init(severity: .error, message: "Server URL «%@» is malformed.", detail: text)]
        }
        return []
    }

    /// An argument naming an absolute or `~` path, optionally after `--flag=`.
    private static func pathArgument(_ argument: String) -> String? {
        var value = argument
        if value.hasPrefix("-"), let equal = value.firstIndex(of: "=") { value = String(value[value.index(after: equal)...]) }
        guard !value.contains("${"), !value.contains("://"), value.hasPrefix("/") || value.hasPrefix("~/") else { return nil }
        return AppPaths.expand(value)
    }
}
