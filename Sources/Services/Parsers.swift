import Foundation
import TOMLKit

/// Parses file text into a Foundation tree ([String: Any] / [Any] / scalars)
/// that DiffEngine and the structured views can walk.
enum Parsers {

    static func parse(_ text: String, format: ConfigFormat) -> (tree: Any?, error: String?) {
        switch format {
        case .json:
            return parseJSON(text)
        case .jsonc:
            return parseJSON(stripJSONComments(text))
        case .toml:
            return parseTOML(text)
        case .markdown, .shell, .dsl, .plist, .text, .binary:
            return (nil, nil)
        }
    }

    private static func parseJSON(_ text: String) -> (Any?, String?) {
        guard let data = text.data(using: .utf8) else { return (nil, "No se pudo leer como UTF-8") }
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return (obj, nil)
        } catch {
            return (nil, friendlyJSONError(error, in: text))
        }
    }

    private static func parseTOML(_ text: String) -> (Any?, String?) {
        do {
            let table = try TOMLTable(string: text)
            let json = table.convert(to: .json)
            guard let data = json.data(using: .utf8) else { return (nil, "TOML→JSON vacío") }
            let obj = try JSONSerialization.jsonObject(with: data)
            return (obj, nil)
        } catch {
            return (nil, "TOML inválido: \(error.localizedDescription)")
        }
    }

    /// Extract the byte offset from JSONSerialization errors for friendlier messages.
    private static func friendlyJSONError(_ error: Error, in text: String) -> String {
        let msg = error.localizedDescription
        // "The data couldn't be read... around line X" isn't provided; derive via debugDescription char index.
        let dbg = (error as NSError).debugDescription
        if let range = dbg.range(of: "around character (\\d+)", options: .regularExpression),
           let digits = dbg[range].range(of: "\\d+", options: .regularExpression),
           let idx = Int(String(dbg[digits])) {
            let prefix = String(decoding: text.utf8.prefix(idx), as: UTF8.self)
            let line = prefix.split(separator: "\n", omittingEmptySubsequences: false).count
            return "JSON inválido — error cerca de la línea \(line): \(msg)"
        }
        return "JSON inválido: \(msg)"
    }

    /// Remove // and /* */ comments without touching string literals.
    static func stripJSONComments(_ text: String) -> String {
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
