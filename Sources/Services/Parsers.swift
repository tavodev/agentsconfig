import Foundation
import TOMLKit

/// Parses file text into a Foundation tree ([String: Any] / [Any] / scalars)
/// that DiffEngine and the structured views can walk.
@MainActor enum Parsers {
    nonisolated static let maximumFileBytes = 2_000_000
    nonisolated static let maximumBackgroundBytes = 16_000_000

    enum InputError: Error, LocalizedError {
        case tooLarge, backgroundTooLarge, unreadable
        var errorDescription: String? {
            switch self {
            case .tooLarge: "File exceeds the 2 MB inspection limit. Use an external editor."
            case .backgroundTooLarge: "File exceeds the 16 MB background limit. Use an external editor."
            case .unreadable: "Could not read the current file"
            }
        }
    }

    /// Bound actual reads too, including a file that grows after stat.
    nonisolated static func readText(at path: String, limit: Int = maximumFileBytes) throws -> String {
        let limitError: InputError = limit > maximumFileBytes ? .backgroundTooLarge : .tooLarge
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        // fstat on the open descriptor: the size of what is actually read
        // (a symlink's target, not the link), without an xattr lookup.
        var info = stat()
        if fstat(handle.fileDescriptor, &info) == 0, Int(info.st_size) > limit { throw limitError }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw limitError }
        guard let text = String(data: data, encoding: .utf8) else { throw InputError.unreadable }
        return text
    }

    static func parse(_ text: String, format: ConfigFormat) -> (tree: Any?, error: String?) {
        guard text.utf8.count <= maximumFileBytes else { return (nil, L(InputError.tooLarge.localizedDescription)) }
        let result = parseInBackground(text, format: format)
        return (result.tree, localizedError(result.error))
    }

    static func localizedError(_ error: String?) -> String? {
        guard let error else { return nil }
        for prefix in ["Invalid JSON: ", "Invalid TOML: "] where error.hasPrefix(prefix) {
            return L(prefix + "%@", String(error.dropFirst(prefix.count)))
        }
        return L(error)
    }

    /// Pure parser entry used inside the background worker. No preferences,
    /// localization singleton or mutable Foundation tree crosses actor boundaries.
    nonisolated static func parseInBackground(_ text: String, format: ConfigFormat) -> (tree: Any?, error: String?) {
        guard text.utf8.count <= maximumBackgroundBytes else { return (nil, "File exceeds the 16 MB limit.") }
        switch format {
        case .json:
            return parseJSON(text)
        case .jsonc:
            return parseJSON(stripJSONTrailingCommas(stripJSONComments(text)))
        case .toml:
            return parseTOML(text)
        case .markdown, .shell, .dsl, .plist, .text, .binary:
            return (nil, nil)
        }
    }

    private nonisolated static func parseJSON(_ text: String) -> (Any?, String?) {
        guard let data = text.data(using: .utf8) else { return (nil, "No se pudo leer como UTF-8") }
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return (obj, nil)
        } catch {
            return (nil, friendlyJSONError(error, in: text))
        }
    }

    private nonisolated static func parseTOML(_ text: String) -> (Any?, String?) {
        do {
            let table = try TOMLTable(string: text)
            let json = table.convert(to: .json)
            guard let data = json.data(using: .utf8) else { return (nil, "TOML→JSON empty") }
            let obj = try JSONSerialization.jsonObject(with: data)
            return (obj, nil)
        } catch {
            return (nil, String(format: "Invalid TOML: %@", error.localizedDescription))
        }
    }

    /// Extract the byte offset from JSONSerialization errors for friendlier messages.
    private nonisolated static func friendlyJSONError(_ error: Error, in text: String) -> String {
        let msg = error.localizedDescription
        // "The data couldn't be read... around line X" isn't provided; derive via debugDescription char index.
        let dbg = (error as NSError).debugDescription
        if let range = dbg.range(of: "around character (\\d+)", options: .regularExpression),
           let digits = dbg[range].range(of: "\\d+", options: .regularExpression),
           let idx = Int(String(dbg[digits])) {
            let prefix = String(decoding: text.utf8.prefix(idx), as: UTF8.self)
            let line = prefix.split(separator: "\n", omittingEmptySubsequences: false).count
            return String(format: "Invalid JSON — error near line %d: %@", line, msg)
        }
        return String(format: "Invalid JSON: %@", msg)
    }

    /// Remove // and /* */ comments without touching string literals.
    nonisolated static func stripJSONComments(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        var i = text.startIndex
        var inString = false
        var inLine = false
        var inBlock = false
        var prev: Character = "\0"

        while i < text.endIndex {
            let c = text[i]
            let next = text.index(after: i) < text.endIndex ? text[text.index(after: i)] : "\0"

            if inLine {
                if c == "\n" { inLine = false; out.append(c) }
            } else if inBlock {
                if c == "*" && next == "/" { inBlock = false; i = text.index(after: i) }
            } else if inString {
                out.append(c)
                if c == "\\" && next != "\0" {
                    i = text.index(after: i)
                    out.append(text[i])
                } else if c == "\"" {
                    inString = false
                }
            } else {
                if c == "\"" { inString = true; out.append(c) }
                else if c == "/" && next == "/" { inLine = true }
                else if c == "/" && next == "*" { inBlock = true; i = text.index(after: i) }
                else { out.append(c) }
            }
            prev = c
            i = text.index(after: i)
        }
        _ = prev
        return out
    }

    /// Serialize a tree back to pretty JSON (used by structured editors).
    private nonisolated static func stripJSONTrailingCommas(_ text: String) -> String {
        var result = ""
        var quoted = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if quoted {
                result.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" {
                quoted = true; result.append(character)
            } else if character == "," {
                var next = text.index(after: index)
                while next < text.endIndex, text[next].isWhitespace { next = text.index(after: next) }
                if next == text.endIndex || (text[next] != "}" && text[next] != "]") { result.append(character) }
            } else { result.append(character) }
            index = text.index(after: index)
        }
        return result
    }

    static func serializeJSON(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else { return nil }
        var s = String(data: data, encoding: .utf8) ?? ""
        if !s.hasSuffix("\n") { s += "\n" }
        return s
    }

    /// Serialize a Foundation tree back to TOML text via TOMLKit.
    /// Note: normalizes formatting and drops comments — Codex rewrites this
    /// file itself, so that's acceptable.
    static func serializeTOML(_ obj: Any) -> String? {
        guard let dict = obj as? [String: Any] else { return nil }
        let table = TOMLTable()
        for (k, v) in dict { table[k] = toTOMLValue(v) }
        var s = table.convert(to: .toml)
        if !s.hasSuffix("\n") { s += "\n" }
        return s
    }

    /// Edits only the selected MCP table in TOML's native typed tree. Dates,
    /// large integers and unrelated tables never round-trip through JSON.
    static func updatingTOMLMcp(_ text: String, container: String, name: String,
                                spec: [String: Any]) throws -> String {
        let table = try TOMLTable(string: text)
        if let value = table[container], value.table == nil {
            throw McpAdapter.Failure(message: L("The MCP container must be an object."))
        }
        let servers = table[container]?.table ?? TOMLTable()
        servers[name] = try checkedTOMLValue(spec)
        table[container] = servers
        return table.convert(to: .toml) + "\n"
    }

    private static func checkedTOMLValue(_ value: Any) throws -> TOMLValueConvertible {
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            if !["f", "d"].contains(String(cString: n.objCType)), let integer = Int(n.stringValue) { return integer }
            if n.doubleValue.isFinite { return n.doubleValue }
        } else if let string = value as? String { return string }
        else if let dict = value as? [String: Any] {
            let table = TOMLTable()
            for (key, child) in dict { table[key] = try checkedTOMLValue(child) }
            return table
        } else if let array = value as? [Any] {
            let result = TOMLArray()
            for child in array { result.append(try checkedTOMLValue(child)) }
            return result
        }
        throw McpAdapter.Failure(message: L("This MCP value cannot be represented safely in TOML."))
    }

    static func toTOMLValue(_ v: Any) -> TOMLValueConvertible? {
        switch v {
        case is NSNull:
            return nil
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            if n.doubleValue == n.doubleValue.rounded() && abs(n.doubleValue) < 9e15 {
                return n.intValue
            }
            return n.doubleValue
        case let s as String:
            return s
        case let d as [String: Any]:
            let t = TOMLTable()
            for (k, val) in d { t[k] = toTOMLValue(val) }
            return t
        case let a as [Any]:
            let arr = TOMLArray()
            for e in a { if let tv = toTOMLValue(e) { arr.append(tv) } }
            return arr
        default:
            return String(describing: v)
        }
    }
}
