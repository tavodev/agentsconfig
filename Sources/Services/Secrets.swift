import Foundation

/// Display-only policy. Callers keep the original tree/buffer for editing.
/// Context includes every ancestor, so credentials.value and tokens[0] are
/// protected. Arbitrary secrets without a recognizable context are not detectable.
@MainActor enum Secrets {
    private static let keyToken =
        #"api[-_.]?key|access[-_.]?key|secret|token|password|passwd|"# +
        #"credential|private[-_.]?key|client[-_.]?secret|bearer|authorization|refresh[-_.]?token"#
    static let maskedValue = "••••••••"

    static func isSecretKey(_ key: String) -> Bool {
        key.range(of: #"(?i)(?:"# + keyToken + ")", options: .regularExpression) != nil
    }

    static func isSensitive(_ value: Any, path: String) -> Bool {
        if isSecretKey(path) { return true }
        let parts = path.lowercased().split(whereSeparator: { ".[]".contains($0) })
        // Arguments can contain positional credentials, including an empty
        // argument between a flag and its value. Hide the whole argument list.
        if parts.contains("args") || parts.contains("arguments") { return true }
        if let values = value as? [Any], parts.last == "command" { return !values.isEmpty }
        guard let text = value as? String else { return false }
        if isSecretKey(text) { return true }
        if let components = URLComponents(string: text), components.scheme != nil {
            if components.user != nil || components.password != nil { return true }
            if components.queryItems?.contains(where: { isSecretKey($0.name) }) == true { return true }
        }
        // Commands and source lines may embed a credential-bearing URL rather
        // than consist solely of that URL. Never expose it through a summary.
        if let expression = try? NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s<>\"']+"#) {
            let string = text as NSString
            for match in expression.matches(in: text, range: NSRange(location: 0, length: string.length)) {
                if let url = URLComponents(string: string.substring(with: match.range)),
                   url.user != nil || url.password != nil || url.queryItems?.contains(where: { isSecretKey($0.name) }) == true {
                    return true
                }
            }
        }
        return false
    }

    /// Always redacts, independent of the display preference. Safe for cached
    /// diffs and activity; toggling the preference cannot leave raw values there.
    static func redacted(_ value: Any, path: String = "") -> Any {
        if isSensitive(value, path: path) { return maskedValue }
        if let dict = value as? [String: Any] {
            return dict.mapValuesWithKeys { key, child in
                redacted(child, path: path.isEmpty ? key : "\(path).\(key)")
            }
        }
        if let array = value as? [Any] {
            return array.enumerated().map { redacted($0.element, path: "\(path)[\($0.offset)]") }
        }
        return value
    }

    static func displayText(_ text: String, path: String = "", masking: Bool = AppSettings.maskSecrets) -> String {
        masking && isSensitive(text, path: path) ? maskedValue : text
    }

    static func mcpEndpoint(_ spec: [String: Any], masking: Bool = AppSettings.maskSecrets) -> String {
        if let url = spec["url"] as? String ?? spec["httpUrl"] as? String ?? spec["serverUrl"] as? String {
            return displayText(url, path: "url", masking: masking)
        }
        let command = spec["command"] as? String ?? (spec["command"] as? [String])?.first ?? ""
        let args = spec["args"] as? [String] ?? Array((spec["command"] as? [String] ?? []).dropFirst())
        return [displayText(command, path: "command", masking: masking),
                args.isEmpty ? "" : masking ? maskedValue : args.joined(separator: " ")]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Read-only structured previews are normalized after parsing, which also
    /// removes comments. Invalid structured input is hidden as a whole rather
    /// than guessing boundaries with a regex (multiline/escaped values leak).
    static func maskText(_ text: String, format: ConfigFormat, masking: Bool = AppSettings.maskSecrets) -> String {
        guard masking, !text.isEmpty else { return text }
        switch format {
        case .json, .jsonc, .toml:
            guard let tree = Parsers.parse(text, format: format).tree else { return maskedValue }
            let safe = redacted(tree)
            if let string = safe as? String { return isSensitive(tree, path: "") ? maskedValue : string }
            return (format == .toml ? Parsers.serializeTOML(safe) : Parsers.serializeJSON(safe)) ?? maskedValue
        default:
            // A multiline secret may continue without repeating its key.
            if text.contains("\n"), isSensitive(text, path: ""),
               text.contains("\"\"\"") || text.contains("'''") { return maskedValue }
            return text.components(separatedBy: "\n").map { maskLine($0) }.joined(separator: "\n")
        }
    }

    static func maskLine(_ line: String) -> String {
        displayText(line, masking: true)
    }

    static func containsSecrets(_ text: String, format: ConfigFormat) -> Bool {
        func contains(_ value: Any, path: String) -> Bool {
            if isSensitive(value, path: path) { return true }
            if let dict = value as? [String: Any] {
                return dict.contains { contains($0.value, path: "\(path).\($0.key)") }
            }
            if let array = value as? [Any] {
                return array.contains { contains($0, path: path) }
            }
            return false
        }
        if let tree = Parsers.parse(text, format: format).tree
            ?? Parsers.parse(text, format: .jsonc).tree
            ?? Parsers.parse(text, format: .toml).tree {
            return contains(tree, path: "") || isSensitive(text, path: "")
        }
        let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first
        return isSensitive(text, path: "") || [.json, .jsonc, .toml].contains(format)
            || first == "{" || first == "["
    }
}

private extension Dictionary where Key == String, Value == Any {
    func mapValuesWithKeys(_ transform: (String, Any) -> Any) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in self { result[key] = transform(key, value) }
        return result
    }
}
