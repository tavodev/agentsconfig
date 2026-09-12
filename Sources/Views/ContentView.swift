import SwiftUI

struct ContentView: View {
    @Environment(ConfigStore.self) private var store

    @State private var inspectorSheetVisible = false
    @State private var columns: NavigationSplitViewVisibility = .all

    private var wideDestination: Bool {
        store.selectedAgentID == ConfigStore.settingsID || store.selectedAgentID == ConfigStore.mcpID
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if wideDestination {
                    NavigationSplitView {
                        SidebarView()
                            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
                    } detail: {
                        if store.selectedAgentID == ConfigStore.settingsID {
                            AppSettingsView()
                                .frame(maxWidth: 760)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .navigationTitle(L("Settings"))
                        } else {
                            McpMatrixView()
                        }
                    }
                } else {
                    NavigationSplitView(columnVisibility: $columns) {
                        SidebarView()
                            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
                    } content: {
                        Group {
                            if store.selectedAgentID == ConfigStore.activityID {
                                ActivityFeedView()
                            } else {
                                FileListView()
                            }
                        }
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
                    } detail: {
                        if store.selectedAgentID == ConfigStore.activityID {
                            ActivityDetailView()
                        } else {
                            EditorView()
                        }
                    }
                }
            }
            .environment(\.workspaceWidth, geometry.size.width)
            .navigationSplitViewStyle(.balanced)
            .onChange(of: geometry.size.width < 1180, initial: true) { _, compact in
                columns = compact ? .doubleColumn : .all
            }
        }
        .environment(\.locale, Locale(identifier: Loc.shared.lang.rawValue))
        .environment(\.inspectorSheetVisibility, $inspectorSheetVisible)
        .toolbar {
            if store.selectedAgentID != ConfigStore.settingsID {
                ToolbarItem(placement: .primaryAction) {
                    Button { store.refresh() } label: {
                        Label(L("Re-scan"), systemImage: "arrow.clockwise")
                    }
                    .help(L("Re-scan"))
                    .accessibilityIdentifier("rescan")
                }
            }
        }
        .sheet(item: Binding(get: { inspectorSheetVisible ? nil : store.pendingSaveReview }, set: { if $0 == nil { store.cancelSaveReview() } })) { review in
            SaveReviewSheet(review: review)
        }
        .sheet(item: Binding(get: { inspectorSheetVisible ? nil : store.pendingMcpReview }, set: { if $0 == nil { store.cancelMcpReview() } })) { review in
            McpReviewSheet(review: review)
        }
        .alert(L("MCP operation failed"), isPresented: Binding(
            get: { !inspectorSheetVisible && store.actionError != nil },
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
        .sheet(item: Binding(get: { inspectorSheetVisible ? nil : store.pendingRestore }, set: { if $0 == nil { store.cancelRestore() } })) { request in
            RestoreReviewSheet(request: request)
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(ConfigStore.self) private var store
    @AppStorage("sidebarScope", store: AppSettings.defaults) private var scope: String = "global"
    @AppStorage("sidebarProject", store: AppSettings.defaults) private var savedProject = ""
    private var activeProject: String? {
        get { savedProject.isEmpty ? nil : savedProject }
        nonmutating set { savedProject = newValue ?? "" }
    }
    @AppStorage("sidebarSubmodule", store: AppSettings.defaults) private var savedSubmodule = ""
    private var activeSubmodule: String? {
        get { savedSubmodule.isEmpty ? nil : savedSubmodule }
        nonmutating set { savedSubmodule = newValue ?? "" }
    }

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

    private var activeProjectName: String {
        guard let activeProject else { return "" }
        return URL(fileURLWithPath: activeProject).lastPathComponent
    }

    private var activeScopeTitle: String { activeSubmodule ?? L("Project root") }

    private var activeScopeDetail: String {
        activeSubmodule == nil
            ? (scopedAgents.count == 1 ? L("1 agent with configuration") : L("%d agents with configuration", scopedAgents.count))
            : L("Git submodule")
    }

    private var activeScopeSymbol: String {
        activeSubmodule == nil ? "folder.fill" : "shippingbox.fill"
    }

    private func syncActiveProject() {
        if activeProject == nil || !store.projectRoots.contains(activeProject!) {
            activeProject = store.projectRoots.first
            activeSubmodule = nil
        }
        if let activeSubmodule, !submodulePaths.contains(activeSubmodule) {
            self.activeSubmodule = nil
        }
    }

    private func syncSelectedAgent() {
        guard let agent = store.agents.first(where: { $0.id == store.selectedAgentID }) else { return }
        if let path = store.selectedPath, !agent.files.contains(where: { $0.path == path }) {
            store.selectedPath = nil
        }
        scope = agent.projectRoot == nil ? "global" : "projects"
        if let root = agent.projectRoot {
            activeProject = root
            activeSubmodule = agent.submodulePath
        }
    }

    private func pickProject() {
        let existing = Set(store.projectRoots)
        store.pickAndAddProject()
        if let added = store.projectRoots.last(where: { !existing.contains($0) }) {
            scope = "projects"
            selectProject(added)
        }
    }

    private func selectProject(_ root: String) {
        activeProject = root
        activeSubmodule = nil
        selectVisibleAgent()
    }

    private func selectVisibleAgent() {
        let visible = scope == "global" ? store.agents.filter { $0.projectRoot == nil } : scopedAgents
        guard !visible.contains(where: { $0.id == store.selectedAgentID }) else { return }
        store.selectedAgentID = visible.first?.id
        store.selectedPath = nil
    }

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selectedAgentID) {
            Section {
                PanelRow(icon: "bolt.horizontal.fill", title: L("Activity"),
                         subtitle: L("change feed"), count: store.externalChanges.count,
                         color: .accentColor)
                    .tag(ConfigStore.activityID)
                    .accessibilityIdentifier("destination-activity")
                PanelRow(icon: "server.rack", title: "MCP",
                         subtitle: L("cross-agent comparator"), count: store.mcpNames.count,
                         color: .teal)
                    .tag(ConfigStore.mcpID)
                    .accessibilityIdentifier("destination-mcp")
                PanelRow(icon: "gearshape", title: L("Settings"),
                         subtitle: L("appearance, privacy"), count: 0,
                         color: .gray)
                    .tag(ConfigStore.settingsID)
                    .accessibilityIdentifier("destination-settings")
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
        .onAppear { syncActiveProject(); syncSelectedAgent() }
        .onChange(of: store.selectedAgentID) { _, _ in syncSelectedAgent() }
        .onChange(of: scope) { _, _ in selectVisibleAgent() }
        .onChange(of: store.projectRoots) { _, _ in syncActiveProject() }
        .onChange(of: submodulePaths) { _, _ in syncActiveProject() }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if !store.externalChanges.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.blue)
                        Text(L("%d external change(s)", store.externalChanges.count))
                            .font(.callout)
                            .foregroundStyle(.blue)
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.top, 6)
                }
                HStack(spacing: 6) {
                    Image(systemName: "eye.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(L("%d files watched", store.watchedCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let t = store.lastEventAt {
                        Text(t, style: .time)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .background { WorkspaceBarBackground() }
        }
    }

    @ViewBuilder
    private var projectsSection: some View {
        Section {
            if store.projectRoots.isEmpty {
                Text(L("No projects registered yet."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                projectPicker
                if !submodulePaths.isEmpty {
                    scopeSelector
                }
                ForEach(scopedAgents) { agent in AgentGroupRow(agent: agent) }
                if scopedAgents.isEmpty {
                    Text(L("No known agent config found in this folder yet."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Button(L("Add project…"), systemImage: "plus") { pickProject() }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("add-project")
        } header: {
            Text(L("Projects"))
        }
    }

    private var projectPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L("Project"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                projectActions
            }
            Menu {
                ForEach(store.projectRoots, id: \.self) { root in
                    Button { selectProject(root) } label: {
                        Label(URL(fileURLWithPath: root).lastPathComponent,
                              systemImage: root == activeProject ? "checkmark" : "folder")
                    }
                    .help(root.replacingOccurrences(of: AppPaths.home, with: "~"))
                }
            } label: {
                ContextSelectorLabel(icon: "folder.fill", title: activeProjectName,
                    detail: activeProject?.replacingOccurrences(of: AppPaths.home, with: "~") ?? "")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .accessibilityLabel(L("Select project"))
            .accessibilityIdentifier("project-selector")
        }
    }

    private var projectActions: some View {
        Menu {
            if let activeProject {
                Button(L("Open folder in Finder")) {
                    store.revealInFinder(activeProject)
                }
                Divider()
                Button(L("Remove project"), role: .destructive) {
                    store.removeProject(path: activeProject)
                    syncActiveProject()
                    selectVisibleAgent()
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .help(L("Project actions"))
    }

    private var scopeSelector: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("Scope"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Menu {
                Button {
                    activeSubmodule = nil
                    selectVisibleAgent()
                } label: {
                    Label(L("Project root"), systemImage: activeSubmodule == nil ? "checkmark" : "folder")
                }
                ForEach(submodulePaths, id: \.self) { sub in
                    Button {
                        activeSubmodule = sub
                        selectVisibleAgent()
                    } label: {
                        Label(sub, systemImage: activeSubmodule == sub ? "checkmark" : "shippingbox")
                    }
                }
            } label: {
                ContextSelectorLabel(icon: activeScopeSymbol, title: activeScopeTitle, detail: activeScopeDetail)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .accessibilityLabel(L("Select scope"))
            .accessibilityIdentifier("scope-selector")
        }
    }
}

/// A context selector makes project and scope visible without turning a
/// sidebar into a horizontally scrolling navigation strip.
private struct ContextSelectorLabel: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
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
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(title).font(.body)
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
    var displayName: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            AgentProductIcon(agent: agent, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName ?? agent.name)
                    .font(.system(size: 13, weight: .medium))
                Text(L("%d files", agent.files.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if agent.issueCount > 0 {
                Label("\(agent.issueCount)", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L("%d issues", agent.issueCount))
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
        AgentRow(agent: agent, displayName: sidebarDisplayName)
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

    private var sidebarDisplayName: String? {
        guard agent.projectRoot != nil,
              let suffix = agent.name.range(of: " (", options: .backwards) else { return nil }
        return String(agent.name[..<suffix.lowerBound])
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
                                       description: Text(L("Select an agent to browse its configuration files.")))
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
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if file.volatile {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .help(L("State file — changes frequently"))
                    }
                }
                Text(file.shortPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note = file.note {
                    Text(L(note))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if pending {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L("Modified outside the app — check the diff"))
                    .help(L("Modified outside the app — check the diff"))
            }
            if dirty {
                Image(systemName: "pencil.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L("You have unsaved changes"))
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
                    .foregroundStyle(.secondary)
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
        .accessibilityLabel(L("Issues detected"))
        .popover(isPresented: $show, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Issues detected"))
                    .font(.system(size: 12, weight: .semibold))
                ForEach(Array(issues.enumerated()), id: \.offset) { _, i in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: i.severity == .error ? "xmark.octagon.fill" :
                                        i.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .font(.callout)
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
