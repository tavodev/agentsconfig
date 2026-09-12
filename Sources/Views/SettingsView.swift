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
            Section(L("Privacy")) {
                Toggle(L("Mask secrets (API keys, tokens…)"), isOn: $maskSecrets)
                    .accessibilityIdentifier("mask-secrets")
                Toggle(L("Record local history"), isOn: $historyEnabled)
                if !historyEnabled {
                    Text(L("New snapshots and save backups are disabled. Existing history is retained; restore with unsaved edits is blocked."))
                        .font(.callout).foregroundStyle(.orange)
                }
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
        .formStyle(.grouped)
        .padding(8)
    }
}
