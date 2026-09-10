import SwiftUI

/// Content column: matrix of MCP server names × agents.
struct McpMatrixView: View {
    @Environment(ConfigStore.self) private var store
    @State private var query = ""

    private var names: [String] {
        let all = store.mcpNames
        guard !query.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        @Bindable var store = store
        Group {
            if store.mcpIndex.isEmpty {
                ContentUnavailableView(
                    "Sin MCP servers",
                    systemImage: "server.rack",
                    description: Text("Ningún agente declara servidores MCP en su configuración.")
                )
            } else {
                List(selection: $store.selectedMcpName) {
                    Section {
                        ForEach(names, id: \.self) { name in
                            McpMatrixRow(name: name)
                                .tag(name)
                        }
                    } header: {
                        HStack {
                            Text("Servidores MCP")
                            Spacer()
                            Text("\(names.count)")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
                .searchable(text: $query, prompt: "Filtrar servidores")
            }
        }
        .navigationTitle("MCP servers")
    }
}

struct McpMatrixRow: View {
    let name: String
    @Environment(ConfigStore.self) private var store

    var body: some View {
        let entries = store.mcpEntries(for: name)
        let ownerIDs = Set(entries.map(\.agentID))
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                if let first = entries.first {
                    Text(first.isRemote ? "remoto" : "local")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background((first.isRemote ? Color.purple : Color.teal).opacity(0.15))
                        .foregroundStyle(first.isRemote ? Color.purple : Color.teal)
                        .clipShape(Capsule())
                }
                Spacer()
            }
            HStack(spacing: 5) {
                ForEach(store.agents) { agent in
                    let has = ownerIDs.contains(agent.id)
                    Text(short(agent.name))
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(has ? agent.color.opacity(0.18) : Color.primary.opacity(0.05))
                        .foregroundStyle(has ? agent.color : Color.secondary.opacity(0.5))
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(agent.color.opacity(has ? 0.5 : 0.12)))
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func short(_ name: String) -> String {
        name.replacingOccurrences(of: " Code", with: "")
            .replacingOccurrences(of: " / Gemini", with: "")
    }
}

/// Detail pane: per-agent spec cards for the selected server + copy actions.
struct McpDetailView: View {
    @Environment(ConfigStore.self) private var store

    private var entries: [McpServerEntry] {
        store.mcpEntries(for: store.selectedMcpName ?? "")
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
                        Text("\(entries.count) de \(store.agents.count) agentes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)

                    ForEach(store.agents) { agent in
                        if let entry = entries.first(where: { $0.agentID == agent.id }) {
                            McpAgentCard(agent: agent, entry: entry)
                        } else {
                            McpMissingCard(agent: agent, source: entries.first)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .navigationTitle(name)
        } else {
            ContentUnavailableView("Selecciona un servidor",
                                   systemImage: "server.rack",
                                   description: Text("Elige un MCP server para comparar su configuración entre agentes."))
        }
    }
}

struct McpAgentCard: View {
    let agent: Agent
    let entry: McpServerEntry
    @Environment(ConfigStore.self) private var store

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: agent.symbol).foregroundStyle(agent.color)
                    Text(agent.name).font(.system(size: 13, weight: .semibold))
                    if let en = entry.enabled {
                        Text(en ? "activo" : "desactivado")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background((en ? Color.green : Color.gray).opacity(0.15))
                            .foregroundStyle(en ? .green : .secondary)
                            .clipShape(Capsule())
                    }
                    Spacer()
                    Button { store.openFile(entry.sourcePath) } label: {
                        Label("Abrir", systemImage: "doc.text")
                    }
                    .controlSize(.small)
                }

                HStack(spacing: 8) {
                    Image(systemName: entry.isRemote ? "network" : "terminal")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(entry.endpoint)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
                if !entry.envKeys.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "key")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(entry.envKeys.joined(separator: ", "))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(entry.sourcePath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
                Image(systemName: agent.symbol)
                    .foregroundStyle(.secondary)
                Text(agent.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("no configurado")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let source, store.mcpTargetFile(for: agent.id) != nil {
                    Menu("Copiar aquí") {
                        Button("Copiar «\(source.name)» a \(agent.name)") {
                            store.copyMcpServer(source, to: agent.id)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 18)
        .opacity(0.75)
    }
}
