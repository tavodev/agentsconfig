import Foundation

struct AuditDiagnostic: Identifiable {
    let id: String
    let severity: String
    let code: String
    let source: String
    let message: String
}
struct PortableReport: Codable {
    struct Item: Codable { let code: String; let severity: String; let source: String; let message: String }
    struct Source: Codable { let id: String; let scope: String; let state: String }
    struct Setting: Codable { let key: String; let state: String; let value: String?; let origins: [String] }
    let schemaVersion: Int
    let generatedAt: Date
    let agent: String
    let clientVersion: String
    let project: String
    let sessionVerified: Bool
    let sources: [Source]
    let settings: [Setting]
    let diagnostics: [Item]
}
@MainActor enum DiagnosticReportBuilder {
    static func diagnostics(configuration: ConfigurationAnalysis, knowledge: KnowledgeAnalysis,
                            files: [TrackedFile], mcp: [McpComparedSource]) -> [AuditDiagnostic] {
        var items: [AuditDiagnostic] = []
        func append(_ code: String, _ severity: String, _ path: String, _ message: String) {
            items.append(.init(id: code + "|" + path + "|" + String(items.count), severity: severity,
                               code: code, source: path, message: Secrets.displayText(message, masking: true)))
        }
        for source in configuration.sources where source.state == "Unresolved" {
            append("source-unresolved", "warning", source.path, source.reason)
        }
        for setting in configuration.settings where ["Restricted", "Unresolved", "Conditional"].contains(setting.state) {
            append("setting-" + setting.state.lowercased(), "warning", setting.origins.last?.source ?? "", setting.name + ": " + setting.state)
        }
        var seen = Set<String>()
        for file in files where seen.insert(file.path).inserted {
            for issue in file.issues {
                append("file-lint", issue.severity == .error ? "error" : issue.severity == .warning ? "warning" : "info", file.path, issue.message)
            }
        }
        for skill in knowledge.skills {
            for issue in skill.issues { append("skill-metadata", "warning", skill.path, issue) }
            for resource in skill.resources where resource.state != "Available" {
                append("skill-resource", "warning", skill.path, resource.name + ": " + resource.state)
            }
        }
        for instruction in knowledge.instructions where ["Missing", "Outside scope", "Truncated", "Unresolved"].contains(instruction.state) {
            append("instruction-" + instruction.state.lowercased().replacingOccurrences(of: " ", with: "-"), "warning", instruction.path, instruction.reason)
        }
        for item in mcp where ["Ambiguous", "Disabled", "Activation not verified"].contains(item.state) {
            append("mcp-" + item.state.lowercased().replacingOccurrences(of: " ", with: "-"), item.state == "Ambiguous" ? "warning" : "info", item.entry.sourcePath, item.reason)
        }
        return Array(items.prefix(1_000))
    }

    static func make(configuration: ConfigurationAnalysis, diagnostics: [AuditDiagnostic],
                     anonymizePaths: Bool = true, includeValues: Bool = false) -> PortableReport {
        let paths = Set(configuration.sources.map(\.path) + diagnostics.map(\.source) +
                        configuration.settings.flatMap { $0.origins.map(\.source) }).sorted()
        let aliases = Dictionary(uniqueKeysWithValues: paths.enumerated().map { ($0.element, "source-" + String($0.offset + 1)) })
        func source(_ path: String) -> String { anonymizePaths ? aliases[path] ?? "unobserved" : Secrets.displayText(path, masking: true) }
        let version = configuration.context.version
        let safeVersion = version.range(of: "^[0-9]+(?:\\.[0-9]+){1,3}$", options: .regularExpression) != nil ? version : "not observed"
        return PortableReport(schemaVersion: 1, generatedAt: configuration.observedAt, agent: configuration.context.agentID,
            clientVersion: safeVersion, project: anonymizePaths ? (configuration.context.projectRoot.isEmpty ? "global" : "selected-project") : configuration.context.projectRoot,
            sessionVerified: false, sources: configuration.sources.map { .init(id: source($0.path), scope: $0.label, state: $0.state) },
            settings: configuration.settings.map { setting in
                let key = setting.key.map { component in
                    anonymizePaths && (component.contains("/") || component.contains("\\")) ? "path-key" : Secrets.displayText(component, masking: true)
                }.joined(separator: ".")
                return .init(key: key, state: setting.state, value: includeValues && !anonymizePaths ? Secrets.displayText(setting.value, path: setting.name, masking: true) : nil,
                             origins: setting.origins.map { source($0.source) })
            }, diagnostics: diagnostics.map {
                // Default export omits free-form messages: these can contain
                // uncatalogued absolute paths, names or arbitrary fixture text.
                .init(code: $0.code, severity: $0.severity, source: source($0.source),
                      message: anonymizePaths ? "Inspect this diagnostic locally for full details." : Secrets.displayText($0.message, masking: true))
            })
    }
    static func serialize(_ report: PortableReport, markdown: Bool = false) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(report), as: UTF8.self)
        return markdown ? "# AgentsConfig diagnostic report\n\nThis is an on-disk estimate; session state is not verified.\n\n```json\n" + json + "\n```\n" : json + "\n"
    }
}
