import Foundation
import Testing

extension AgentsConfigTestSuite {
@Suite("Diagnostic export and new clients", .serialized) @MainActor
struct DiagnosticExportTests {
    @Test func defaultReportOmitsValuesPathsAndArbitraryMessages() throws {
        let context = AnalysisContext(projectRoot: "/private/customer/project", version: "not-a-version")
        var analysis = ConfigurationAnalysis(context: context)
        analysis.sources = [.init(path: "/private/customer/config.json", label: "User", state: "Applied", reason: "", tree: nil)]
        analysis.settings = [.init(key: ["output_directory"], value: "/private/customer/output", state: "Estimated",
            origins: [.init(source: "/private/customer/config.json", state: "Applied", value: "FAKE-PRIVATE", reason: "")])]
        let items = [AuditDiagnostic(id: "one", severity: "warning", code: "file-lint", source: "/private/customer/config.json", message: "Unexpected /another/private folder/file")]
        let text = try DiagnosticReportBuilder.serialize(DiagnosticReportBuilder.make(configuration: analysis, diagnostics: items))
        #expect(!text.contains("/private/customer"))
        #expect(!text.contains("/another/private"))
        #expect(!text.contains("FAKE-PRIVATE"))
        #expect(text.contains("source-1"))
        #expect(text.contains("\"sessionVerified\" : false"))
        let anonymousWithValues = try DiagnosticReportBuilder.serialize(DiagnosticReportBuilder.make(configuration: analysis, diagnostics: items, includeValues: true))
        #expect(!anonymousWithValues.contains("/private/customer"))
    }
    @Test func optInValuesStillRedactSecretsAndMarkdownIsAvailable() throws {
        var analysis = ConfigurationAnalysis(context: AnalysisContext())
        analysis.settings = [.init(key: ["env", "API_KEY"], value: "FAKE-SENSITIVE", state: "Estimated", origins: [])]
        let report = DiagnosticReportBuilder.make(configuration: analysis, diagnostics: [], anonymizePaths: false, includeValues: true)
        let text = try DiagnosticReportBuilder.serialize(report, markdown: true)
        #expect(!text.contains("FAKE-SENSITIVE"))
        #expect(text.hasPrefix("# AgentsConfig"))
    }
    @Test func cursorAndCopilotAreReadOnlyButSharedFilesKeepExistingCapabilities() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.write(".cursor/mcp.json", #"{"mcpServers":{"cursor":{"command":"fake"}}}"#)
        try env.write(".copilot/settings.json", "{// fixture\n\"model\":\"fake\"}")
        try env.write(".copilot/config.json", #"{"token":"FAKE-AUTH"}"#)
        let project = try env.makeProjectRoot(); defer { try? FileManager.default.removeItem(at: project) }
        try env.write(root: project, "AGENTS.md", "# Shared")
        try env.write(root: project, ".cursor/rules/swift.mdc", "---\nglobs: '**/*.swift'\n---\n# Rule")
        try env.write(root: project, ".github/instructions/swift.instructions.md", "---\napplyTo: '**/*.swift'\n---\n# Rule")
        let store = env.makeStore(); store.addProject(path: project.path)
        #expect(store.agents.contains { $0.id == "cursor" })
        #expect(store.agents.contains { $0.id == "copilot-cli" })
        #expect(store.isReadOnly(env.path(".cursor/mcp.json")))
        #expect(store.isReadOnly(env.path(".copilot/config.json")))
        #expect(store.history(for: env.path(".copilot/config.json")).isEmpty)
        #expect(store.document(for: env.path(".copilot/settings.json"))?.parseError == nil)
        #expect(!store.isReadOnly(project.appendingPathComponent("AGENTS.md").path))
        #expect(store.agents.first { $0.id == "cursor::\(project.path)" }?.files.contains { $0.path.hasSuffix(".mdc") } == true)
        let context = AnalysisContext(agentID: "copilot-cli", projectRoot: project.path, targetFile: "src/main.swift")
        let report = store.knowledgeAnalysis(context, configuration: store.configurationAnalysis(context))
        #expect(report.instructions.contains { $0.path.hasSuffix(".instructions.md") && $0.state == "Candidate" })
    }
    @Test func globalSearchOnlyIndexesRedactedContent() async throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        try env.write(".claude/settings.json", #"{"model":"SEARCH-FIXTURE","env":{"API_KEY":"FAKE-HIDDEN-SEARCH"}}"#)
        let store = env.makeStore()
        #expect(await store.searchCatalog("SEARCH-FIXTURE").count == 1)
        #expect(await store.searchCatalog("FAKE-HIDDEN-SEARCH").isEmpty)
    }
    @Test func analysisStartsWithSelectedProjectAndDisambiguatesNames() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let first = env.path("first/Harbor"), second = env.path("second/Harbor")
        let store = env.makeStore(); store.addProject(path: first); store.addProject(path: second)
        AppSettings.defaults.set(second, forKey: "sidebarProject")
        #expect(store.preferredAnalysisProject == second)
        #expect(store.projectLabel(first) != store.projectLabel(second))
    }

    @Test func exportedReportsUsePrivatePermissions() throws {
        let env = try TestEnvironment(); defer { env.teardown() }
        let text = try DiagnosticReportBuilder.serialize(DiagnosticReportBuilder.make(configuration: .init(context: .init()), diagnostics: []))
        try AtomicWriter.writePreservingPermissions(text, toPath: env.path("report.json"))
        #expect(env.posixPermissions("report.json") == 0o600)
        #expect(try JSONSerialization.jsonObject(with: Data(text.utf8)) is [String: Any])
    }
}
}
