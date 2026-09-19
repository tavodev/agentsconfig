import SwiftUI

/// The matrix compares agent *families*, while its detail pane still exposes
/// every global/project source. Project-local configurations have synthetic
/// ids (`codex::/path/to/project`), which must not turn a narrow matrix into
/// one column per project.
private func mcpAgentFamilyID(_ id: String) -> String {
    String(id.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(id))
}

private func mcpMatrixAgents(_ agents: [Agent]) -> [Agent] {
    var families = Set<String>()
    return agents.filter { families.insert(mcpAgentFamilyID($0.id)).inserted }
}

/// Content column: matrix of MCP server names × agents.
struct McpMatrixView: View {
    @Environment(ConfigStore.self) private var store
    @State private var query = ""
    @State private var addPath: String?
    @State private var showDetail = false

    private var names: [String] {
        let all = Array(Set(store.contextualMcpIndex.map(\.name))).sorted()
        guard !query.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var agents: [Agent] { mcpMatrixAgents(store.agents) }

    var body: some View {
        @Bindable var store = store
        GeometryReader { geometry in
            let columnWidth = max(64, min(110, (geometry.size.width - 240) / CGFloat(max(1, agents.count))))
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("MCP servers")).font(.title2.weight(.semibold))
                    HStack {
                        Picker(L("Project context"), selection: $store.mcpProjectFilter) {
                            Text(L("All sources")).tag("__all__")
                            Text(L("Global only")).tag("")
                            ForEach(store.mcpContextPaths, id: \.self) { Text($0).tag($0) }
                        }.accessibilityIdentifier("mcp-project-filter")
                        TextField(L("Codex profile (optional)"), text: $store.mcpProfileFilter).frame(maxWidth: 240)
                    }
                    Text(L("Compare configured servers across agents. Select a server to inspect its sources."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                if store.mcpIndex.isEmpty {
                    ContentUnavailableView(L("No MCP servers"), systemImage: "server.rack",
                        description: Text(L("No agent declares MCP servers in its config.")))
                } else if names.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    HStack(spacing: 0) {
                        Text(L("Server")).font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(agents) { agent in
                            VStack(spacing: 4) {
                                AgentProductIcon(agent: agent, size: 22)
                                Text(agent.name.components(separatedBy: " (").first ?? agent.name)
                                    .font(.callout).lineLimit(1).truncationMode(.tail)
                            }
                            .frame(width: columnWidth)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    Divider()
                    List(selection: $store.selectedMcpName) {
                        ForEach(names, id: \.self) { name in
                            McpMatrixRow(name: name, agents: agents, columnWidth: columnWidth)
                                .tag(name)
                                .accessibilityIdentifier("mcp-row:" + name)
                                .contextMenu {
                                    Button(L("Server details")) {
                                        store.selectedMcpName = name
                                        showDetail = true
                                    }
                                }
                        }
                    }
                    .listStyle(.inset)
                }
                HStack {
                    Text(L("%d servers", names.count)).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Server details"), systemImage: "sidebar.trailing") { showDetail = true }
                        .disabled(store.mcpEntries(for: store.selectedMcpName ?? "").isEmpty)
                        .accessibilityIdentifier("mcp-details")
                }.padding(16)
            }
        }
        .navigationTitle(L("MCP servers"))
        .searchable(text: $query, prompt: L("Filter servers"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(store.agents) { agent in
                        ForEach(store.mcpTargetFiles(for: agent.id)) { file in
                            Button("\(agent.name) — \(URL(fileURLWithPath: file.path).lastPathComponent)") { addPath = file.path }
                        }
                    }
                } label: {
                    Label(L("Add MCP server"), systemImage: "plus")
                }
                .disabled(!store.agents.contains { !store.mcpTargetFiles(for: $0.id).isEmpty })
            }
        }
        .adaptiveInspector(isPresented: $showDetail, title: L("Server details"), panelThreshold: 1300) {
            McpDetailView()
        }
        .popover(isPresented: Binding(get: { addPath != nil }, set: { if !$0 { addPath = nil } })) {
            if let path = addPath { McpAddForm(path: path) { addPath = nil } }
        }
    }
}

/// A family indicates presence, not that all of its sources have equal settings.
struct McpMatrixRow: View {
    let name: String
    let agents: [Agent]
    let columnWidth: CGFloat
    @Environment(ConfigStore.self) private var store

    var body: some View {
        let entries = store.contextualMcpIndex.filter { $0.name == name }
        let ownerIDs = Set(entries.map { mcpAgentFamilyID($0.agentID) })
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.body.monospaced().weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                Text(entries.count == 1 ? L("1 source") : L("%d sources", entries.count))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(agents) { agent in
                let has = ownerIDs.contains(mcpAgentFamilyID(agent.id))
                let states = Set(store.comparedMcpSources.filter { $0.entry.name == name && mcpAgentFamilyID($0.entry.agentID) == mcpAgentFamilyID(agent.id) && !["Outside context", "Shadowed"].contains($0.state) }.map(\.state))
                Image(systemName: states.contains("Ambiguous") ? "exclamationmark.triangle" : states == ["Disabled"] ? "pause.circle" : has ? "checkmark.circle" : "minus")
                    .font(.body)
                    .foregroundStyle(has ? Color.primary : Color.secondary)
                    .frame(width: columnWidth)
                    .accessibilityLabel(agent.name + ": " + (states.isEmpty ? L("not configured") : states.sorted().map { L($0) }.joined(separator: ", ")))
                    .help(states.sorted().map { L($0) }.joined(separator: ", "))
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

/// Detail pane: per-agent spec cards for the selected server + copy actions.
struct McpDetailView: View {
    @Environment(ConfigStore.self) private var store

    private var entries: [McpServerEntry] {
        store.contextualMcpIndex.filter { $0.name == store.selectedMcpName }
    }

    private var agents: [Agent] { mcpMatrixAgents(store.agents) }

    private var configuredAgentCount: Int {
        Set(entries.map { mcpAgentFamilyID($0.agentID) }).count
    }

    var body: some View {
        if let name = store.selectedMcpName, !entries.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "server.rack")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text(name)
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        Spacer()
                        Text(L("%d of %d agents", configuredAgentCount, agents.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)

                    if let err = store.actionError {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(err).font(.caption)
                            Spacer()
                            Button { store.clearActionError() } label: {
                                Image(systemName: "xmark").font(.callout)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 6)
                    }

                    if entries.count > 1 { McpDefinitionDiffView(entries: entries) }
                    ForEach(agents) { agent in
                        let familyEntries = entries.filter {
                            mcpAgentFamilyID($0.agentID) == mcpAgentFamilyID(agent.id)
                        }
                        if familyEntries.isEmpty {
                            McpMissingCard(agent: agent, source: entries.first)
                        } else {
                            ForEach(familyEntries) { entry in
                                McpAgentCard(agent: agent, entry: entry)
                            }
                        }
                    }
                }
                .padding(.bottom, 20)
            }

        } else {
            ContentUnavailableView(L("Select a server"),
                                   systemImage: "server.rack",
                                   description: Text(L("Pick an MCP server to compare its configuration across agents.")))
        }
    }
}

struct McpAgentCard: View {
    @AppStorage("maskSecrets", store: AppSettings.defaults) private var maskSecrets = true
    let agent: Agent
    let entry: McpServerEntry
    @Environment(ConfigStore.self) private var store

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    AgentProductIcon(agent: agent, size: 16)
                    Text(agent.name).font(.system(size: 13, weight: .semibold))
                    Text(L(entry.scope)).font(.caption).foregroundStyle(.secondary)
                    if let compared = store.comparedMcpSources.first(where: { $0.id == entry.id }) {
                        Text(L(compared.state)).font(.caption).foregroundStyle(.secondary).help(L(compared.reason))
                    }
                    if let en = entry.enabled {
                        Text(en ? L("enabled") : L("disabled"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { store.openFile(entry.sourcePath) } label: {
                        Label(L("Open"), systemImage: "doc.text")
                    }
                    .controlSize(.small)
                }

                HStack(spacing: 8) {
                    Image(systemName: entry.isRemote ? "network" : "terminal")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(Secrets.mcpEndpoint(entry.raw, masking: maskSecrets))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
                if !entry.envKeys.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "key")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(entry.envKeys.joined(separator: ", "))
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                if store.agents.contains(where: { $0.id == entry.agentID && $0.projectRoot != nil }) {
                    Label(L("Project configuration · read-only"), systemImage: "lock")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text(entry.sourcePath.replacingOccurrences(of: AppPaths.home, with: "~"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
    }
}

struct McpMissingCard: View {
    let agent: Agent
    let source: McpServerEntry?
    @Environment(ConfigStore.self) private var store

    var body: some View {
        Card {
            HStack(spacing: 8) {
                AgentProductIcon(agent: agent, size: 16)
                    .opacity(0.55)
                Text(agent.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L("not configured"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let source, !store.mcpTargetFiles(for: agent.id).isEmpty {
                    Menu(L("Copy here")) {
                        ForEach(store.mcpTargetFiles(for: agent.id)) { file in
                            Button(URL(fileURLWithPath: file.path).lastPathComponent) {
                                store.copyMcpServer(source, to: agent.id, targetPath: file.path)
                            }
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 18)

    }
}

/// Shared add form for the structured inspector and the empty MCP matrix.
struct McpAddForm: View {
    let path: String
    let onClose: () -> Void
    @Environment(ConfigStore.self) private var store
    @State private var name = ""
    @State private var transport: McpAdapter.Transport = .stdio
    @State private var command = ""
    @State private var args: [String] = []
    @State private var url = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Add MCP server")).font(.headline)
            Text(path.replacingOccurrences(of: AppPaths.home, with: "~"))
                .font(.caption).foregroundStyle(.secondary)
            TextField(L("Name"), text: $name).accessibilityIdentifier("mcp-name")
            Picker(L("Transport"), selection: $transport) {
                Text("STDIO").tag(McpAdapter.Transport.stdio)
                Text("HTTP").tag(McpAdapter.Transport.http)
                Text("SSE").tag(McpAdapter.Transport.sse)
            }.pickerStyle(.segmented)
            if transport == .stdio {
                TextField(L("Command (e.g. npx)"), text: $command).accessibilityIdentifier("mcp-command")
                Text(L("Arguments (one row per argument; empty rows are preserved)")).font(.caption)
                ScrollView {
                    VStack {
                        ForEach(args.indices, id: \.self) { index in
                            HStack {
                                TextField(L("Argument"), text: $args[index]).accessibilityIdentifier("mcp-argument-\(index)")
                                Button { args.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel(L("Remove argument %d", index + 1))
                            }
                        }
                    }
                }.frame(height: min(150, CGFloat(max(1, args.count)) * 34))
                Button(L("Add argument")) { args.append("") }.accessibilityIdentifier("add-mcp-argument")
            } else { TextField(L("Server URL"), text: $url) }
            HStack {
                Button(L("Cancel"), action: onClose)
                Spacer()
                Button(L("Review change")) {
                    if store.addMcpServer(path: path, name: name, transport: transport,
                                          command: command, args: args, url: url) { onClose() }
                }.accessibilityIdentifier("review-mcp").disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder).padding(16).frame(width: 430)
    }
}

struct McpReviewSheet: View {
    let review: ConfigStore.McpReview
    @Environment(ConfigStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Review MCP change")).font(.headline)
            Text(review.path.replacingOccurrences(of: AppPaths.home, with: "~")).font(.caption)
            if review.replacesExisting {
                Label(L("This replaces the existing server named %@.", review.name), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            ForEach(review.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            Text(L("Apply updates the editor only. Save writes the file. Secret values stay hidden in this diff."))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                CompareView(baseText: review.originalText, baseLabel: L("Current"),
                            otherText: review.proposedText, otherLabel: L("Proposed"), format: review.format)
            }
            HStack {
                Button(L("Cancel")) { store.cancelMcpReview() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Apply to editor")) { store.confirmMcpReview() }
                    .accessibilityIdentifier("apply-mcp")
                    .buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(minWidth: 680, minHeight: 440)
    }
}
