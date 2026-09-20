import SwiftUI
import AppKit

struct WorkspaceAnalysisView: View {
    @Environment(ConfigStore.self) private var store
    @State private var context = AnalysisContext()
    @State private var analysis = ConfigurationAnalysis(context: AnalysisContext())
    @State private var knowledge = KnowledgeAnalysis()
    @State private var query = ""
    @State private var selectedTab = "Configuration"

    private func update() {
        analysis = store.configurationAnalysis(context)
        knowledge = store.knowledgeAnalysis(context, configuration: analysis)
    }
    private var settings: [ResolvedSetting] {
        analysis.settings.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) ||
            $0.value.localizedCaseInsensitiveContains(query) || $0.state.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("Configuration for this project")).font(.title2.bold())
                HStack {
                    Picker(L("Agent"), selection: $context.agentID) {
                        ForEach(AgentRegistry.definitions, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Picker(L("Project"), selection: $context.projectRoot) {
                        Text(L("Global")).tag("")
                        ForEach(store.projectRoots, id: \.self) { Text(store.projectLabel($0)).tag($0) }
                    }
                }
                HStack {
                    Text(L("Working folder")).font(.caption)
                    Text(context.workingDirectory.isEmpty ? (context.projectRoot.isEmpty ? L("Global") : context.projectRoot) : context.workingDirectory)
                        .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(L("Choose folder…")) {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                        if panel.runModal() == .OK, let path = panel.url?.path { context.workingDirectory = path }
                    }.disabled(context.projectRoot.isEmpty)
                    Button(L("Project root")) { context.workingDirectory = context.projectRoot }.disabled(context.projectRoot.isEmpty)
                }
                DisclosureGroup(L("Analysis assumptions")) {
                    HStack {
                        TextField(L("Client version (optional)"), text: $context.version)
                            .accessibilityIdentifier("analysis-version")
                        TextField(L("Codex profile (optional)"), text: $context.profile)
                            .disabled(context.agentID != "codex").accessibilityIdentifier("analysis-profile")
                        Picker(L("Trust assumption"), selection: $context.trust) {
                            ForEach(AnalysisContext.Trust.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) }
                        }
                    }
                    Text(L("These controls simulate a context. They do not change client settings or grant permissions."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField(L("Target file for path rules (relative, optional)"), text: $context.targetFile)
                    .accessibilityIdentifier("analysis-target-file")
                Text(L("Estimate from files — session state is not verified."))
                    .font(.callout).foregroundStyle(.secondary)
                Picker(L("Analysis view"), selection: $selectedTab) {
                    Text(L("Configuration")).tag("Configuration")
                    Text(L("Sources")).tag("Sources")
                    Text(L("Instructions")).tag("Instructions")
                    Text(L("Skills")).tag("Skills")
                    Text(L("Diagnostics")).tag("Diagnostics")
                }.pickerStyle(.segmented).accessibilityIdentifier("analysis-tabs")
            }.padding(20)
            Divider()
            if selectedTab == "Sources" { sourcesView }
            else if selectedTab == "Instructions" {
                InstructionListView(items: knowledge.instructions.filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query) }, notices: knowledge.notices)
            } else if selectedTab == "Skills" {
                SkillPackagesView(packages: knowledge.skills.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query) },
                                  projectRoot: context.projectRoot.isEmpty ? nil : context.projectRoot)
            } else if selectedTab == "Diagnostics" {
                DiagnosticsView(configuration: analysis, diagnostics: DiagnosticReportBuilder.diagnostics(configuration: analysis, knowledge: knowledge,
                    files: store.agents.filter { $0.id.components(separatedBy: "::").first == context.agentID && ($0.projectRoot == nil || $0.projectRoot == context.projectRoot) }.flatMap(\.files),
                    mcp: McpComparison.sources(store.mcpIndex.filter { McpComparison.family($0) == context.agentID }, project: context.projectRoot, profile: context.profile)))
            } else { settingsView }
        }
        .navigationTitle(L("Configuration"))
        .searchable(text: $query, prompt: L("Search settings"))
        .onAppear { if context.projectRoot.isEmpty { context.projectRoot = store.preferredAnalysisProject }; update() }
        .onChange(of: context) { old, new in
            if old.projectRoot != new.projectRoot { context.workingDirectory = new.projectRoot }
            update()
        }
        .onChange(of: store.analysisRevision) { _, _ in update() }
    }

    private var settingsView: some View {
        List {
            Section {
                ForEach(analysis.notices, id: \.self) { Text(L($0)).font(.callout).foregroundStyle(.secondary) }
            }
            if settings.isEmpty {
                ContentUnavailableView(L("No settings found"), systemImage: "slider.horizontal.3",
                    description: Text(L("Inspect Sources for missing, invalid or unobserved configuration.")))
            }
            ForEach(settings) { setting in
                DisclosureGroup {
                    ForEach(Array(setting.origins.enumerated()), id: \.offset) { _, origin in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(L(origin.state)).font(.caption.bold())
                                Text(origin.source).font(.caption.monospaced()).textSelection(.enabled)
                                Spacer()
                                Button(L("Open")) { store.openFile(origin.source) }
                            }
                            Text(origin.value).font(.caption.monospaced()).textSelection(.enabled)
                            if !origin.reason.isEmpty { Text(L(origin.reason)).font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 5)
                    }
                } label: {
                    HStack(alignment: .top) {
                        Text(setting.name).font(.body.monospaced()).frame(minWidth: 160, maxWidth: 280, alignment: .leading)
                        Text(setting.value).font(.body.monospaced()).lineLimit(3).textSelection(.enabled)
                        Spacer()
                        Text(L(setting.state)).font(.caption).foregroundStyle(setting.state == "Restricted" ? .orange : .secondary)
                    }
                }.accessibilityIdentifier("resolved:" + setting.id)
            }
        }.listStyle(.inset)
    }

    private var sourcesView: some View {
        List(analysis.sources) { source in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L(source.label)).font(.headline)
                    Text(L(source.state)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Open")) { store.openFile(source.path) }.disabled(source.state == "Missing")
                }
                Text(source.path).font(.caption.monospaced()).textSelection(.enabled)
                if !source.reason.isEmpty { Text(L(source.reason)).font(.callout).foregroundStyle(.secondary) }
                if source.label == "Constraints", let tree = source.tree {
                    Text(ConfigurationResolver.render(tree, key: [])).font(.caption.monospaced()).textSelection(.enabled)
                }
            }.padding(.vertical, 6)
        }.listStyle(.inset)
    }
}
