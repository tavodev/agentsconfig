import SwiftUI
import AppKit

/// Permissions audit failures from `SnapshotStore.secureExistingPermissions`
/// are reported here — history that can't be made private must be visible.
/// Reused both by the native `Settings` scene and as an in-app sidebar
/// destination (`ConfigStore.settingsID`), so it must not assume a fixed
/// window width — the caller sizes its own container.
struct AppSettingsView: View {
    @Environment(ConfigStore.self) private var store
    @AppStorage("notificationsEnabled", store: AppSettings.defaults) private var notifications = true
    @AppStorage("maskSecrets", store: AppSettings.defaults) private var maskSecrets = true
    @AppStorage("watchDebounce", store: AppSettings.defaults) private var debounce = 0.35
    @AppStorage("historyLimit", store: AppSettings.defaults) private var historyLimit = 200
    @AppStorage("historyEnabled", store: AppSettings.defaults) private var historyEnabled = true
    @AppStorage("menuBarExtra", store: AppSettings.defaults) private var menuBarExtra = true
    @AppStorage("appearance", store: AppSettings.defaults) private var appearance = "system"
    @AppStorage("mcpLoginShellEnvironment", store: AppSettings.defaults) private var mcpLoginShell = false
    @AppStorage("contextBudgetThreshold", store: AppSettings.defaults) private var budgetThreshold = 8_000

    var body: some View {
        Form {
            Section(L("Appearance")) {
                Picker(L("Language"), selection: Binding(
                    get: { Loc.shared.lang },
                    set: { Loc.shared.lang = $0 }
                )) {
                    ForEach(AppLanguage.allCases) { l in
                        Text(l.label).tag(l)
                    }
                }
                Picker(L("Theme"), selection: $appearance) {
                    Text(L("System")).tag("system")
                    Text(L("Light")).tag("light")
                    Text(L("Dark")).tag("dark")
                }
                .pickerStyle(.segmented)
                Toggle(L("Menu bar icon"), isOn: $menuBarExtra)
            }
            Section(L("Monitoring")) {
                Toggle(L("Notify when an agent modifies a config"), isOn: $notifications)
                LabeledContent(L("Watcher debounce")) {
                    HStack {
                        Slider(value: $debounce, in: 0.1...2.0, step: 0.05)
                            .accessibilityLabel(L("Watcher debounce"))
                            .accessibilityValue(String(format: "%.2f s", debounce))
                        Text(String(format: "%.2f s", debounce))
                            .font(.caption.monospaced())
                            .frame(width: 52, alignment: .trailing)
                    }
                    .frame(minWidth: 140, maxWidth: 260)
                }
                Stepper(L("History per file: %d versions", historyLimit),
                        value: $historyLimit, in: 10...1000, step: 10)
            }
            Section(L("Configuration folders")) {
                Text(L("Choose inspection roots when a client uses a custom configuration folder. Terminal environment overrides are not inferred."))
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(AgentRegistry.definitions.filter { AgentCatalog.defaultRoots[$0.id] != nil }, id: \.id) { agent in
                    VStack(alignment: .leading) {
                        Text(agent.name).font(.headline)
                        Text(AgentCatalog.root(for: agent.id)).font(.caption.monospaced()).textSelection(.enabled)
                        HStack {
                            Button(L("Choose folder…")) { store.pickConfigurationRoot(agentID: agent.id) }
                            Button(L("Use default")) { store.setConfigurationRoot(agentID: agent.id, path: nil) }
                        }
                    }
                }
            }
            Section(L("Context budget")) {
                Stepper(L("Warn above %d estimated tokens", budgetThreshold),
                        value: $budgetThreshold, in: 1_000...200_000, step: 1_000)
                    .accessibilityIdentifier("context-budget-threshold")
                Text(L("Estimated as bytes ÷ 4 from instruction files, skill names and descriptions. Not a tokenizer; MCP tool definitions are not counted."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section(L("MCP checks")) {
                Toggle(L("Read PATH and variable names from the login shell"), isOn: $mcpLoginShell)
                    .accessibilityIdentifier("mcp-login-shell")
                Text(L("Apps opened from the Finder get a shorter PATH than your terminal. When on, AgentsConfig runs your login shell once to read PATH and variable names (values are discarded); this runs its startup files. MCP servers are never started."))
                    .font(.callout).foregroundStyle(.secondary)
                if mcpLoginShell && store.mcpLoginShellFailed {
                    Label(L("The login shell could not be read; using the app environment."), systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            Section(L("Privacy")) {
                Toggle(L("Mask secrets (API keys, tokens…)"), isOn: $maskSecrets)
                    .accessibilityIdentifier("mask-secrets")
                Toggle(L("Record local history"), isOn: $historyEnabled)
                if !historyEnabled {
                    Text(L("New snapshots and save backups are disabled. Existing history is retained; restore with unsaved edits is blocked."))
                        .font(.callout).foregroundStyle(.orange)
                }
                purgeHistoryControls
                if !store.permissionWarnings.isEmpty {
                    ForEach(store.permissionWarnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section {
                Button(L("Open history folder")) {
                    NSWorkspace.shared.open(
                        AppPaths.applicationSupport
                            .appendingPathComponent("AgentsConfig/History", isDirectory: true)
                    )
                }
            }
        }
        .onChange(of: debounce) { _, value in store.setWatchDebounce(value) }
        .onChange(of: mcpLoginShell) { _, _ in store.reloadMcpCheckEnvironment() }
        .formStyle(.grouped)
        .padding(8)
    }

    /// Global purge next to the recording toggle. The dialog lives here (not
    /// in ContentView) because the Settings scene is a separate window.
    @ViewBuilder private var purgeHistoryControls: some View {
        Button(L("Delete all history…"), role: .destructive) { store.requestHistoryPurge() }
            .disabled(store.historyPurgeBlocked)
            .accessibilityIdentifier("purge-history")
            .confirmationDialog(L("Delete all local history?"), isPresented: Binding(
                get: { store.pendingHistoryPurge != nil },
                set: { if !$0 { store.cancelHistoryPurge() } }
            ), titleVisibility: .visible, presenting: store.pendingHistoryPurge) { _ in
                Button(L("Delete all history"), role: .destructive) { store.confirmHistoryPurge() }
                Button(L("Cancel"), role: .cancel) { store.cancelHistoryPurge() }
            } message: { request in
                let s = request.summary
                Text(L("Permanently deletes the history of %d file(s): %d version(s) and %d legacy backup(s), %@ on disk. Config files are not changed and the activity feed is cleared. If recording stays on, future changes create new versions. This cannot be undone.",
                       s.histories, s.versions, s.legacyBackups,
                       ByteCountFormatter.string(fromByteCount: s.bytes, countStyle: .file)))
            }
        if let error = store.historyPurgeError {
            HStack {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
                Button(L("Retry")) { store.retryHistoryPurge() }
                    .disabled(store.historyPurgeBlocked)
            }
        } else if let notice = store.historyPurgeNotice {
            Text(notice).font(.callout).foregroundStyle(.secondary)
        }
    }
}
