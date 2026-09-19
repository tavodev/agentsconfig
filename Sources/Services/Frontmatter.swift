import Foundation
import Yams

struct FlexibleStrings: Decodable {
    var values: [String]
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) { values = [string] }
        else { values = try container.decode([String].self) }
    }
}
struct KnowledgeHeader: Decodable {
    var name: String?
    var description: String?
    var license: String?
    var compatibility: String?
    var allowedTools: FlexibleStrings?
    var paths: FlexibleStrings?
    var globs: FlexibleStrings?
    var applyTo: FlexibleStrings?
    var alwaysApply: Bool?
    var disableModelInvocation: Bool?
    var userInvocable: Bool?
    enum CodingKeys: String, CodingKey {
        case name, description, license, compatibility, paths, globs, applyTo, alwaysApply
        case allowedTools = "allowed-tools", disableModelInvocation = "disable-model-invocation", userInvocable = "user-invocable"
    }
}
enum Frontmatter {
    struct Parsed { var header: KnowledgeHeader?; var body: String; var issue: String? }
    static func parse(_ text: String) -> Parsed {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---" else { return .init(body: text) }
        guard let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else {
            return .init(body: text, issue: "Frontmatter closing delimiter is missing.")
        }
        let yaml = lines[1..<end].joined(separator: "\n")
        guard yaml.utf8.count <= 65_536 else { return .init(body: text, issue: "Frontmatter exceeds 64 KiB.") }
        do {
            let header = try YAMLDecoder().decode(KnowledgeHeader.self, from: yaml)
            return .init(header: header, body: lines.dropFirst(end + 1).joined(separator: "\n"))
        } catch { return .init(body: text, issue: "Invalid YAML frontmatter or unsupported metadata type.") }
    }
}

/// Common path globs; unsupported patterns stay conditional instead of claiming
/// a match or exclusion. Inputs are bounded before compiling a regular expression.
enum KnowledgeGlob {
    static func matches(_ path: String, pattern: String) -> Bool? {
        guard pattern.count <= 1_024, !pattern.contains("["), !pattern.contains("{"), !pattern.hasPrefix("!") else { return nil }
        var regex = "^"
        let chars = Array(pattern)
        var i = 0
        while i < chars.count {
            if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                if i < chars.count, chars[i] == "/" { regex += "(?:.*/)?"; i += 1 }
                else { regex += ".*" }
            } else if chars[i] == "*" { regex += "[^/]*"; i += 1 }
            else if chars[i] == "?" { regex += "[^/]"; i += 1 }
            else { regex += NSRegularExpression.escapedPattern(for: String(chars[i])); i += 1 }
        }
        return path.range(of: regex + "$", options: .regularExpression) != nil
    }
}

