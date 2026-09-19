import Foundation

struct AnalysisContext: Equatable {
    var agentID = "codex"
    var projectRoot = ""
    var workingDirectory = ""
    var profile = ""
    var version = ""
    var targetFile = ""
    var trust: Trust = .unknown
    enum Trust: String, CaseIterable { case unknown = "Unknown", trusted = "Trusted", untrusted = "Untrusted" }
}
struct SourceObservation: Identifiable {
    var id: String { path + "|" + label }
    let path: String
    let label: String
    var state: String
    var reason: String
    var tree: [String: Any]?
}
struct ValueOrigin: Identifiable, Codable {
    var id: String { source + "|" + state + "|" + value }
    let source: String
    var state: String
    let value: String
    var reason: String
}
struct ResolvedSetting: Identifiable, Codable {
    let key: [String]
    var id: String { key.map { $0.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }.joined(separator: "/") }
    var name: String { key.joined(separator: ".") }
    var value: String
    var state: String
    var origins: [ValueOrigin]
}
struct ConfigurationAnalysis {
    var settings: [ResolvedSetting] = []
    var sources: [SourceObservation] = []
    var notices: [String] = []
    var observedAt = Date()
    var context: AnalysisContext
}
