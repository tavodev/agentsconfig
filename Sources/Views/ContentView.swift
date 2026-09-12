import SwiftUI

struct ContentView: View {
    @Environment(ConfigStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 280)
        } content: {
            Group {
                if store.selectedAgentID == ConfigStore.activityID {
                    ActivityFeedView()
                } else if store.selectedAgentID == ConfigStore.mcpID {
                    McpMatrixView()
                } else if store.selectedAgentID == ConfigStore.settingsID {
                    AppSettingsView()
                } else {
                    FileListView()
                }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 380)
        } detail: {
            if store.selectedAgentID == ConfigStore.activityID {
                ActivityDetailView()
            } else if store.selectedAgentID == ConfigStore.mcpID {
                McpDetailView()
            } else if store.selectedAgentID == ConfigStore.settingsID {
                ContentUnavailableView(L("Settings"), systemImage: "gearshape")
            } else {
                EditorView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.showInspector.toggle() } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .help("Inspector (⌥⌘0)")
                .keyboardShortcut("0", modifiers: [.option, .command])
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.selectedAgentID = ConfigStore.activityID
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "arrow.down.circle")
                        if !store.externalChanges.isEmpty {
                            Text("\(store.externalChanges.count)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(Circle().fill(.blue))
                                .offset(x: 8, y: -8)
                        }
                    }
                }
                .help("Cambios externos pendientes")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Re-escanear agentes")
            }
        }
        .sheet(item: Binding(get: { store.pendingSaveReview }, set: { if $0 == nil { store.cancelSaveReview() } })) { review in
            SaveReviewSheet(review: review)
        }
        .sheet(item: Binding(get: { store.pendingMcpReview }, set: { if $0 == nil { store.cancelMcpReview() } })) { review in
            McpReviewSheet(review: review)
        }
        .alert(L("MCP operation failed"), isPresented: Binding(
            get: { store.actionError != nil },
            set: { if !$0 { store.clearActionError() } }
        )) {
            Button(L("OK")) { store.clearActionError() }
        } message: { Text(store.actionError ?? "") }
        .confirmationDialog(L("Remove history versions?"), isPresented: Binding(
            get: { store.pendingHistoryRemoval != nil },
            set: { if !$0 { store.cancelHistoryRemoval() } }
        ), titleVisibility: .visible, presenting: store.pendingHistoryRemoval) { _ in
            Button(L("Remove versions"), role: .destructive) { store.confirmHistoryRemoval() }
            Button(L("Cancel"), role: .cancel) { store.cancelHistoryRemoval() }
        } message: { request in
            Text(L("Remove %d recorded version(s) for this file? This cannot be undone. The config file and legacy backups are kept; future changes may create new versions.", request.ids.count))
        }
        .sheet(item: Binding(get: { store.pendingRestore }, set: { if $0 == nil { store.cancelRestore() } })) { request in
            RestoreReviewSheet(request: request)
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(ConfigStore.self) private var store
    @AppStorage("sidebarScope") private var scope: String = "global"
    @State private var activeProject: String?
    @State private var activeSubmodule: String?

    private var projectAgents: [Agent] {
        guard let activeProject else { return [] }
        return store.agents.filter { $0.projectRoot == activeProject }
    }
    private var submodulePaths: [String] {
        Array(Set(projectAgents.compactMap(\.submodulePath))).sorted()
    }
    private var scopedAgents: [Agent] {
        projectAgents.filter { $0.submodulePath == activeSubmodule }
    }

    private func syncActiveProject() {
        if activeProject == nil || !store.projectRoots.contains(activeProject!) {
            activeProject = store.projectRoots.first
            activeSubmodule = nil
        }
    }

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selectedAgentID) {
            Section {
                PanelRow(icon: "bolt.horizontal.fill", title: L("Activity"),
                         subtitle: L("change feed"), count: store.activity.count,
                         color: .accentColor)
                    .tag(ConfigStore.activityID)
                PanelRow(icon: "server.rack", title: "MCP",
                         subtitle: L("cross-agent comparator"), count: store.mcpNames.count,
                         color: .teal)
                    .tag(ConfigStore.mcpID)
                PanelRow(icon: "gearshape", title: L("Settings"),
                         subtitle: L("appearance, privacy"), count: 0,
                         color: .gray)
                    .tag(ConfigStore.settingsID)
            }

            Section {
                Picker(L("Scope"), selection: $scope) {
                    Text(L("Global")).tag("global")
                    Text(L("Projects")).tag("projects")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .listRowSeparator(.hidden)

            if scope == "global" {
                Section(L("Detected agents")) {
                    ForEach(store.agents.filter { $0.projectRoot == nil }) { agent in
                        AgentGroupRow(agent: agent)
                    }
                }
            } else {
                projectsSection
            }
        }
        .listStyle(.sidebar)
        .onAppear { syncActiveProject() }
        .onChange(of: store.projectRoots) { _, _ in syncActiveProject() }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if !store.externalChanges.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                        Text(L("%d external change(s)", store.externalChanges.count))
                            .font(.caption2)
                            .foregroundStyle(.blue)
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.top, 6)
                }
                HStack(spacing: 6) {
                    Image(systemName: "eye.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(L("%d files watched", store.watchedCount))
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
            }
            .background(.bar)
        }
    }

    @ViewBuilder
    private var projectsSection: some View {
        Section {
            if store.projectRoots.isEmpty {
                Text(L("No projects registered yet."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                projectPicker
                if !submodulePaths.isEmpty {
                    scopeChips
                }
                ForEach(scopedAgents) { agent in AgentGroupRow(agent: agent) }
                if scopedAgents.isEmpty {
                    Text(L("No known agent config found in this folder yet."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text(L("Projects"))
                Spacer()
                Button { store.pickAndAddProject() } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .help(L("Add project…"))
            }
        }
    }

    private var projectPicker: some View {
        Menu {
            ForEach(store.projectRoots, id: \.self) { root in
                Button {
                    activeProject = root
                    activeSubmodule = nil
                } label: {
                    Label(URL(fileURLWithPath: root).lastPathComponent, systemImage: "folder")
                }
            }
            Divider()
            if let activeProject {
                Button(role: .destructive) {
                    store.removeProject(path: activeProject)
                } label: {
                    Label(L("Remove this project"), systemImage: "trash")
                }
            }
            Button { store.pickAndAddProject() } label: {
                Label(L("Add project…"), systemImage: "plus")
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(activeProject.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(activeProject?.replacingOccurrences(of: AppPaths.home, with: "~") ?? "")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        }
        .menuStyle(.borderlessButton)
    }

    private var scopeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                scopeChip(label: L("Root"), systemImage: "folder", selected: activeSubmodule == nil) {
                    activeSubmodule = nil
                }
                ForEach(submodulePaths, id: \.self) { sub in
                    scopeChip(label: sub, systemImage: "shippingbox", selected: activeSubmodule == sub) {
                        activeSubmodule = sub
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func scopeChip(label: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(selected ? Color.accentColor : Color.primary.opacity(0.06))
                .foregroundStyle(selected ? .white : .secondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Pinned sidebar row for app-level panels (Actividad, MCP).
struct PanelRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color.gradient)
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
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
                Text(L("%d files", agent.files.count))
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

/// A single agent row inside a project or submodule group — shared context
/// menu (reveals the agent's own resolution root, not necessarily the
/// project root: a submodule agent reveals the submodule's own folder).
struct AgentGroupRow: View {
    @Environment(ConfigStore.self) private var store
    let agent: Agent

    var body: some View {
        AgentRow(agent: agent)
            .tag(agent.id)
            .accessibilityIdentifier("agent-row:\(agent.id)")
            .help(agent.notes.map { L($0) } ?? "")
            .contextMenu {
                Button(L("Open folder in Finder")) {
                    store.revealInFinder(AppPaths.expand(agent.detectionPath))
                }
                Button(L("Re-scan")) { store.refresh() }
            }
    }
}

// MARK: - File list

struct FileListView: View {
    @Environment(ConfigStore.self) private var store
    @State private var query = ""

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
                            Text(L(notes))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(groupedRoles(agent), id: \.self) { role in
                        Section {
                            ForEach(files(agent, role: role).filter {
                                query.isEmpty || $0.path.localizedCaseInsensitiveContains(query)
                            }) { file in
                                FileRow(file: file,
                                        pending: store.externalChanges[file.path] != nil,
                                        dirty: store.dirtyPaths.contains(file.path))
                                    .tag(file.path)
                                    .accessibilityIdentifier("file-row:\(file.path)")
                                    .contextMenu { fileMenu(file) }
                            }
                        } header: {
                            Label(L(role.label), systemImage: role.icon)
                        }
                    }
                }
                .listStyle(.inset)
                .searchable(text: $query, prompt: L("Filter files"))
            } else {
                ContentUnavailableView(L("No agents"),
                                       systemImage: "tray",
                                       description: Text(L("No AI agents detected in ~")))
            }
        }
        .navigationTitle(agent?.name ?? L("Files"))
    }

    // MARK: grouping & menus

    private static let roleOrder: [TrackedRole] = [
        .settings, .instructions, .mcp, .permissions, .hooks, .agents, .skills, .plugins, .state, .other
    ]

    private func groupedRoles(_ agent: Agent) -> [TrackedRole] {
        Self.roleOrder.filter { r in agent.files.contains { $0.role == r } }
    }

    private func files(_ agent: Agent, role: TrackedRole) -> [TrackedFile] {
        agent.files.filter { $0.role == role }
    }

    @ViewBuilder
    private func fileMenu(_ file: TrackedFile) -> some View {
        Button(L("Show in Finder")) { store.revealInFinder(file.path) }
        Button(L("Open with default app")) { store.openInDefaultApp(file.path) }
        Button(L("Copy path")) { store.copyPath(file.path) }
        Divider()
        Button(L("Restore previous version")) { store.requestRestorePrevious(file.path) }
            .disabled(store.history(for: file.path).isEmpty || file.readOnly)
        Button(L("Dismiss change banner")) { store.acknowledgeExternal(path: file.path) }
            .disabled(store.externalChanges[file.path] == nil)
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
                            .help(L("State file — changes frequently"))
                    }
                }
                Text(file.shortPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note = file.note {
                    Text(L(note))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if pending {
                Circle().fill(.blue).frame(width: 8, height: 8)
                    .help(L("Modified outside the app — check the diff"))
            }
            if dirty {
                Circle().fill(.orange).frame(width: 8, height: 8)
                    .help(L("You have unsaved changes"))
            }
            if !file.exists {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .help(L("File does not exist on disk"))
            } else if !file.issues.isEmpty {
                FileIssuesButton(issues: file.issues)
            }
            if file.readOnly {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help(L("Read-only"))
            }
        }
        .padding(.vertical, 3)
    }
}

/// Warning icon → tap shows the issue list in a popover.
struct FileIssuesButton: View {
    let issues: [FileIssue]
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
        .help(issues.map(\.message).joined(separator: "\n"))
        .popover(isPresented: $show, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Issues detected"))
                    .font(.system(size: 12, weight: .semibold))
                ForEach(Array(issues.enumerated()), id: \.offset) { _, i in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: i.severity == .error ? "xmark.octagon.fill" :
                                        i.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(i.severity == .error ? .red :
                                                i.severity == .warning ? .orange : .blue)
                        Text(i.message)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: 360)
        }
    }
}
