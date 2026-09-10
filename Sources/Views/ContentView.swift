import SwiftUI

struct ContentView: View {
    @Environment(ConfigStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 280)
        } content: {
            FileListView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 380)
        } detail: {
            EditorView()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Re-escanear agentes")
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(ConfigStore.self) private var store

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selectedAgentID) {
            Section("Agentes detectados") {
                ForEach(store.agents) { agent in
                    AgentRow(agent: agent)
                        .tag(agent.id)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Image(systemName: "eye.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(store.watchedCount) archivos vigilados")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let t = store.lastEventAt {
                    Text(t, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

struct AgentRow: View {
    let agent: Agent

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(agent.color.gradient)
                    .frame(width: 28, height: 28)
                Image(systemName: agent.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                    .font(.system(size: 13, weight: .medium))
                Text("\(agent.files.count) archivos")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if agent.issueCount > 0 {
                Text("\(agent.issueCount)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange))
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - File list

struct FileListView: View {
    @Environment(ConfigStore.self) private var store

    private var agent: Agent? {
        store.agents.first { $0.id == store.selectedAgentID }
    }

    var body: some View {
        @Bindable var store = store
        Group {
            if let agent {
                List(selection: $store.selectedPath) {
                    if let notes = agent.notes {
                        Section {
                            Text(notes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        ForEach(agent.files) { file in
                            FileRow(file: file,
                                    pending: store.externalChanges[file.path] != nil,
                                    dirty: store.dirtyPaths.contains(file.path))
                                .tag(file.path)
                        }
                    } header: {
                        HStack {
                            Text("Archivos de configuración")
                            Spacer()
                            if agent.issueCount > 0 {
                                Label("\(agent.issueCount)", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                ContentUnavailableView("Sin agentes",
                                       systemImage: "tray",
                                       description: Text("No se detectaron agentes de IA en ~"))
            }
        }
        .navigationTitle(agent?.name ?? "Archivos")
    }
}

struct FileRow: View {
    let file: TrackedFile
    var pending: Bool
    var dirty: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: file.role.icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.displayName)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Text(file.format.badge)
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(file.format.badgeColor.opacity(0.15))
                        .foregroundStyle(file.format.badgeColor)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    if file.volatile {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .help("Archivo de estado — muy activo")
                    }
                }
                Text(file.shortPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if pending {
                Circle().fill(.blue).frame(width: 8, height: 8)
                    .help("Cambió fuera de la app")
            }
            if dirty {
                Circle().fill(.orange).frame(width: 8, height: 8)
                    .help("Cambios sin guardar")
            }
            if !file.exists {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .help("No existe")
            } else if !file.issues.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 3)
    }
}
