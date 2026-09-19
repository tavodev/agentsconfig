import Foundation

struct KnowledgeResource: Identifiable {
    var id: String { path }
    let path: String
    let name: String
    var state: String
}
struct SkillPackage: Identifiable {
    var id: String { path }
    let path: String
    var name: String
    var description: String
    var metadata: [String: String]
    var consumers: [String]
    var state: String
    var issues: [String]
    var resources: [KnowledgeResource]
    var bytes: Int
    var body: String
    var rank: Int
}
struct InstructionSource: Identifiable {
    var id: String { path + "|" + state }
    let path: String
    var state: String
    var reason: String
    var bytes: Int
    var includedBytes: Int
    var text: String
    var importedBy: String?
}
struct KnowledgeAnalysis {
    var instructions: [InstructionSource] = []
    var skills: [SkillPackage] = []
    var notices: [String] = []
}
