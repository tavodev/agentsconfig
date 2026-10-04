import Foundation

/// Supported schema contract and sources: docs/MCP-SCHEMAS.md.
@MainActor enum McpAdapter {
    enum Dialect: String, CaseIterable {
        case claude, codex, gemini, opencode
        var container: String {
            switch self {
            case .claude, .gemini: "mcpServers"
            case .codex: "mcp_servers"
            case .opencode: "mcp"
            }
        }
    }
    enum Transport: String, CaseIterable { case stdio, http, sse }
    struct Conversion {
        let spec: [String: Any]
        var warnings: [String] = []
    }
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func dialect(agentID: String, path: String) -> Dialect? {
        switch agentID {
        case "claude-code": .claude
        case "codex": .codex
        case "opencode": .opencode
        case "gemini-cli": .gemini
        default: nil
        }
    }

    static func makeSpec(dialect: Dialect, transport: Transport, command: String,
                         args: [String], url: String) throws -> [String: Any] {
        if transport == .stdio {
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure(message: L("A local MCP server requires a command."))
            }
            if dialect == .opencode { return ["type": "local", "command": [command] + args] }
            var spec: [String: Any] = ["command": command, "args": args]
            if dialect == .claude { spec["type"] = "stdio" }
            return spec
        }
        guard let components = URLComponents(string: url),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false else {
            throw Failure(message: L("A remote MCP server requires an HTTP or HTTPS URL."))
        }
        if transport == .sse && (dialect == .codex || dialect == .opencode) {
            throw Failure(message: L("This destination cannot preserve an explicit SSE transport."))
        }
        switch dialect {
        case .claude: return ["type": transport.rawValue, "url": url]
        case .codex: return ["url": url]
        case .gemini: return [transport == .http ? "httpUrl" : "url": url]
        case .opencode: return ["type": "remote", "url": url]
        }
    }

    /// Only fields whose semantics are established are translated. Unsupported
    /// options block a cross-dialect copy; same-dialect options remain intact.
    static func convert(_ raw: [String: Any], from source: Dialect, to target: Dialect) throws -> Conversion {
        let transport: Transport
        let command: String
        let args: [String]
        let url: String
        let type = raw["type"] as? String
        if raw["type"] != nil && type == nil {
            throw Failure(message: L("Unsupported MCP transport."))
        }
        if (source == .codex || source == .gemini), type != nil {
            throw Failure(message: L("This source schema does not use a type field."))
        }
        if (source == .claude || source == .gemini), raw["enabled"] != nil {
            throw Failure(message: L("This source schema does not define per-server enabled state here."))
        }
        if source != .gemini && raw["httpUrl"] != nil {
            throw Failure(message: L("MCP transport and fields disagree."))
        }
        if source == .opencode {
            guard type == "local" || type == "remote" else { throw Failure(message: L("Invalid OpenCode MCP type.")) }
        }
        if source == .gemini && raw["httpUrl"] != nil { transport = .http }
        else if raw["url"] != nil { transport = source == .gemini || type == "sse" ? .sse : .http }
        else { transport = .stdio }
        if source == .opencode && ((type == "local") != (transport == .stdio)) {
            throw Failure(message: L("MCP transport and fields disagree."))
        }
        if source == .claude, let type, !["stdio", "http", "sse"].contains(type) {
            throw Failure(message: L("Unsupported MCP transport."))
        }
        if source == .claude, let type, (type == "stdio") != (transport == .stdio) {
            throw Failure(message: L("MCP transport and fields disagree."))
        }
        if transport == .stdio {
            guard raw["url"] == nil, raw["httpUrl"] == nil else { throw Failure(message: L("MCP transport and fields disagree.")) }
            if source == .opencode {
                guard let list = raw["command"] as? [String], let first = list.first, raw["args"] == nil else {
                    throw Failure(message: L("OpenCode command must be a nonempty string array."))
                }
                command = first; args = Array(list.dropFirst())
            } else {
                guard let value = raw["command"] as? String,
                      raw["args"] == nil || raw["args"] is [String] else {
                    throw Failure(message: L("MCP command and arguments have invalid types."))
                }
                command = value; args = raw["args"] as? [String] ?? []
            }
            url = ""
        } else {
            guard raw["command"] == nil, raw["args"] == nil,
                  !(raw["url"] != nil && raw["httpUrl"] != nil),
                  let value = raw[source == .gemini && transport == .http ? "httpUrl" : "url"] as? String else {
                throw Failure(message: L("MCP transport and fields disagree."))
            }
            command = ""; args = []; url = value
        }
        var result = try makeSpec(dialect: target, transport: transport, command: command, args: args, url: url)
        let envKey = source == .opencode ? "environment" : "env"
        let headerKey = source == .codex ? "http_headers" : "headers"
        for key in [envKey, headerKey] where raw[key] != nil {
            guard raw[key] is [String: String] else { throw Failure(message: L("MCP env and headers must map names to strings.")) }
        }
        if source == target { return Conversion(spec: raw) }

        var transferable: Set<String> = ["type", "command", "args", "url", "httpUrl", "enabled"]
        if transport == .stdio { transferable.insert(envKey) }
        else { transferable.insert(headerKey) }
        // cwd is deliberately blocked across clients: relative base directories
        // differ, even when the spelling of the option happens to match.
        let unsupported = Set(raw.keys).subtracting(transferable).sorted()
        guard unsupported.isEmpty else {
            throw Failure(message: L("Cannot transfer these MCP options safely: %@", unsupported.joined(separator: ", ")))
        }
        func hasExpansion(_ value: Any) -> Bool {
            if let string = value as? String { return string.contains("$") || string.contains("{env:") || string.contains("{file:") }
            if let array = value as? [Any] { return array.contains(where: hasExpansion) }
            if let dict = value as? [String: Any] { return dict.values.contains(where: hasExpansion) }
            return false
        }
        guard !hasExpansion(raw) else { throw Failure(message: L("Environment or file expansion needs manual conversion between clients.")) }
        if let enabled = raw["enabled"] {
            guard let number = enabled as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw Failure(message: L("MCP enabled must be a boolean."))
            }
            if target == .codex || target == .opencode { result["enabled"] = number.boolValue }
            else if !number.boolValue { throw Failure(message: L("The destination cannot preserve a disabled server in this object.")) }
        }
        if let env = raw[envKey] { result[target == .opencode ? "environment" : "env"] = env }
        if let headers = raw[headerKey] { result[target == .codex ? "http_headers" : "headers"] = headers }
        var warnings = [L("Only this server definition is copied. Client-wide policies, approvals and login sessions are not transferred.")]
        if transport == .http && source == .opencode {
            warnings.append(L("OpenCode remote transport may negotiate differently; the destination will use Streamable HTTP."))
        }
        return Conversion(spec: result, warnings: warnings)
    }
}
