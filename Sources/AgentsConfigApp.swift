import SwiftUI
import AppKit

@main
struct AgentsConfigApp: App {
    @State private var store = makeStore()

    private static func makeStore() -> ConfigStore {
        // The dedicated UI host must never fall back to personal config paths,
        // even if launched manually without XCTest's fixture environment.
        precondition(Bundle.main.bundleIdentifier != "com.tavodev.agentsconfig.ui-fixture" || AppSettings.isIsolatedRun,
                     "The UI test host requires an isolated home and defaults suite.")
        return ConfigStore(notifier: AppSettings.isIsolatedRun ? nil : .shared)
    }
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("menuBarExtra", store: AppSettings.defaults) private var menuBarExtra = true
    @AppStorage("appearance", store: AppSettings.defaults) private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 640)
                .environment(\.previewReducedTransparency, AppSettings.isIsolatedRun && ProcessInfo.processInfo.environment["AGENTSCONFIG_DEMO_REDUCE_TRANSPARENCY"] == "1")
                .onAppear {
                    applyAppearance()
                    appDelegate.store = store
                }
                .onChange(of: appearance) { applyAppearance() }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button(L("Review and save…")) { store.saveSelected() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!store.canSaveSelected)
            }
            CommandGroup(after: .textEditing) {
                Button(L("Find in file")) { store.requestFind() }
                    .keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                ForEach(EditorTab.allCases, id: \.self) { t in
                    Button(L(t.rawValue)) { store.requestedTab = t }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(EditorTab.allCases.firstIndex(of: t)! + 1)")),
                            modifiers: .command
                        )
                }
                Divider()
                Button(store.showInspector ? L("Hide inspector") : L("Show inspector")) {
                    store.showInspector.toggle()
                }
                .keyboardShortcut("0", modifiers: [.option, .command])
            }
        }

        MenuBarExtra(isInserted: $menuBarExtra) {
            MenuBarView()
                .environment(store)
        } label: {
            let pending = store.externalChanges.count
            Image(systemName: pending > 0 ? "bolt.horizontal.fill" : "slider.horizontal.3")
        }
        .menuBarExtraStyle(.window)

        Settings {
            AppSettingsView()
                .frame(width: 620, height: 620)
                .environment(store)
        }
    }

    private func applyAppearance() {
        if AppSettings.isIsolatedRun && ProcessInfo.processInfo.environment["AGENTSCONFIG_DEMO_HIGH_CONTRAST"] == "1" {
            NSApp.appearance = NSAppearance(named: appearance == "dark"
                ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
        } else {
            NSApp.appearance = AppSettings.appearance
        }
    }
}

/// Quit policy: unsaved buffers live only in memory — quitting without
/// asking would silently drop them, so confirm explicitly instead.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: ConfigStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep the running Dock icon correct even if Launch Services cached a
        // placeholder for a previous development build at this bundle path.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        if !store.savingPaths.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("A save is still in progress. Wait before quitting.")
            alert.runModal()
            return .terminateCancel
        }
        guard !store.dirtyPaths.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("Unsaved changes")
        alert.informativeText = L(
            "%d file(s) have unsaved edits. Quitting discards them — they are not saved to disk or history.",
            store.dirtyPaths.count)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Quit anyway"))
        alert.addButton(withTitle: L("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
            ? .terminateNow : .terminateCancel
    }
}
