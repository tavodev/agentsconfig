import Foundation
import Observation

/// Decides whether this process may start the Sparkle updater (issue #7).
/// Pure so it can be tested without Sparkle: the hostless test bundle compiles
/// `Sources/` without the `@main` and never links Sparkle.
///
/// Only the distributed build updates itself. Everything else — Debug
/// (`.debug`), the UI test host (`.ui-fixture`), the test runner, demos and
/// isolated runs (`AGENTSCONFIG_HOME` or `AGENTSCONFIG_DEFAULTS_SUITE`, each on
/// its own), XCTest-launched processes and builds without a feed or public
/// key — never contacts the appcast and never replaces an installed app.
enum UpdaterPolicy {
    static let releaseBundleIdentifier = "com.tavodev.agentsconfig"

    /// Any of these in the environment means "not a normal user launch".
    static let blockingEnvironmentKeys = [
        "AGENTSCONFIG_HOME",
        "AGENTSCONFIG_DEFAULTS_SUITE",
        "XCTestConfigurationFilePath",
        "XCTestBundlePath",
        "XCTestSessionIdentifier",
    ]

    static func shouldStart(bundleIdentifier: String?,
                            environment: [String: String],
                            infoDictionary: [String: Any]) -> Bool {
        guard bundleIdentifier == releaseBundleIdentifier else { return false }
        guard !blockingEnvironmentKeys.contains(where: { environment[$0] != nil }) else { return false }
        guard let feed = infoDictionary["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = infoDictionary["SUPublicEDKey"] as? String,
              !key.trimmingCharacters(in: .whitespaces).isEmpty
        else { return false }
        return true
    }

    /// The decision for the running process.
    static var currentProcess: Bool {
        shouldStart(bundleIdentifier: Bundle.main.bundleIdentifier,
                    environment: ProcessInfo.processInfo.environment,
                    infoDictionary: Bundle.main.infoDictionary ?? [:])
    }
}

/// What the app needs from an updater. The Sparkle implementation lives in
/// `AgentsConfigApp.swift` (the only file that imports Sparkle), so views and
/// tests depend on this protocol instead.
@MainActor
protocol UpdaterBackend: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }
    var lastUpdateCheckDate: Date? { get }
    /// Called whenever `canCheckForUpdates` changes (e.g. during a check).
    var onStateChange: (() -> Void)? { get set }
    func checkForUpdates()
}

/// Observable façade for Settings and the app menu. Toggles write straight
/// through to the backend (Sparkle persists them in the app's defaults).
@Observable
@MainActor
final class AppUpdater {
    @ObservationIgnored private let backend: any UpdaterBackend

    private(set) var canCheckForUpdates: Bool
    private(set) var lastUpdateCheckDate: Date?

    var automaticallyChecksForUpdates: Bool {
        didSet {
            // Values mirrored by `reload()` already match: never write back.
            guard backend.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            backend.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        didSet {
            // Values mirrored by `reload()` already match: never write back.
            guard backend.automaticallyDownloadsUpdates != automaticallyDownloadsUpdates else { return }
            backend.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }

    init(backend: any UpdaterBackend) {
        self.backend = backend
        canCheckForUpdates = backend.canCheckForUpdates
        lastUpdateCheckDate = backend.lastUpdateCheckDate
        automaticallyChecksForUpdates = backend.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = backend.automaticallyDownloadsUpdates
        backend.onStateChange = { [weak self] in self?.reload() }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        backend.checkForUpdates()
    }

    /// Re-reads the backend; Sparkle can change its own settings (e.g. the
    /// "automatically download" checkbox in its update alert).
    func reload() {
        canCheckForUpdates = backend.canCheckForUpdates
        lastUpdateCheckDate = backend.lastUpdateCheckDate
        if automaticallyChecksForUpdates != backend.automaticallyChecksForUpdates {
            automaticallyChecksForUpdates = backend.automaticallyChecksForUpdates
        }
        if automaticallyDownloadsUpdates != backend.automaticallyDownloadsUpdates {
            automaticallyDownloadsUpdates = backend.automaticallyDownloadsUpdates
        }
    }
}
