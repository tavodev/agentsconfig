import SwiftUI
import AppKit
import Sparkle

@main
struct AgentsConfigApp: App {
    @State private var store = makeStore()

    private static func makeStore() -> ConfigStore {
        // The dedicated UI host must never fall back to personal config paths,
        // even if launched manually without XCTest's fixture environment.
        precondition(Bundle.main.bundleIdentifier != "com.tavodev.agentsconfig.ui-fixture" || AppSettings.isIsolatedRun,
                     "The UI test host requires an isolated home and defaults suite.")
        raiseDescriptorLimit()
        return ConfigStore(notifier: AppSettings.isIsolatedRun ? nil : .shared, backgroundScan: true)
    }

    /// launchd starts apps with a low soft `RLIMIT_NOFILE`; the watcher
    /// sizes its budget from it, so raise it (up to OPEN_MAX) before the
    /// store creates the watcher.
    private static func raiseDescriptorLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let target = min(limit.rlim_max, rlim_t(10_240))
        guard limit.rlim_cur < target else { return }
        limit.rlim_cur = target
        _ = setrlimit(RLIMIT_NOFILE, &limit)
    }
    /// nil whenever `UpdaterPolicy` refuses (Debug, UI host, demos, isolated
    /// runs): the Sparkle controller is then never created, so nothing checks
    /// the appcast or touches the installed app.
    @State private var updater: AppUpdater? = makeUpdater()

    private static func makeUpdater() -> AppUpdater? {
        guard UpdaterPolicy.currentProcess else { return nil }
        return AppUpdater(backend: SparkleUpdaterBackend())
    }
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("menuBarExtra", store: AppSettings.defaults) private var menuBarExtra = true
    @AppStorage("appearance", store: AppSettings.defaults) private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(updater)
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
            CommandGroup(after: .appInfo) {
                if let updater {
                    CheckForUpdatesButton(updater: updater)
                }
            }
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
                .environment(updater)
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

/// App menu item; disabled while Sparkle is already checking or installing.
private struct CheckForUpdatesButton: View {
    let updater: AppUpdater

    var body: some View {
        Button(L("Check for Updates…")) { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

/// The only Sparkle-aware code. Created solely when `UpdaterPolicy` allows it
/// (distributed Release build, normal launch); `SPUStandardUpdaterController`
/// then schedules the daily appcast check and, with automatic downloads on,
/// installs signed updates on quit.
@MainActor
final class SparkleUpdaterBackend: NSObject, UpdaterBackend {
    private let controller: SPUStandardUpdaterController
    private var observations: [NSKeyValueObservation] = []
    var onStateChange: (() -> Void)?

    override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
        let updater = controller.updater
        let notify: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onStateChange?() } }
        }
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { _, _ in notify() },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { _, _ in notify() },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { _, _ in notify() },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { _, _ in notify() },
        ]
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
