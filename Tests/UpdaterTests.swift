import Testing
import Foundation

/// Issue #7: Sparkle may only run in the distributed build launched normally.
/// The decision is pure, so it is exercised with fictitious inputs; the test
/// bundle never links Sparkle and never contacts the appcast.
extension AgentsConfigTestSuite {
@Suite("Updater policy", .serialized)
@MainActor
struct UpdaterTests {
    private static let release = "com.tavodev.agentsconfig"
    private static let info: [String: Any] = [
        "SUFeedURL": "https://github.com/tavodev/agentsconfig/releases/latest/download/appcast.xml",
        "SUPublicEDKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    ]

    private func start(_ id: String?, env: [String: String] = [:],
                       info: [String: Any] = UpdaterTests.info) -> Bool {
        UpdaterPolicy.shouldStart(bundleIdentifier: id, environment: env, infoDictionary: info)
    }

    @Test func releaseBuildLaunchedNormallyStartsTheUpdater() {
        #expect(start(Self.release, env: ["HOME": "/Users/fixture", "PATH": "/usr/bin"]))
    }

    @Test func debugUIHostTestsAndUnknownBundlesNeverStart() {
        for id in ["com.tavodev.agentsconfig.debug", "com.tavodev.agentsconfig.ui-fixture",
                   "com.tavodev.agentsconfig.tests", "com.apple.dt.xctest.tool",
                   "com.tavodev.agentsconfig.uitests", "com.tavodev.agentsconfigx", ""] {
            #expect(!start(id), "\(id)")
        }
        #expect(!start(nil))
    }

    @Test func eachIsolationVariableAloneBlocksTheUpdater() {
        for key in ["AGENTSCONFIG_HOME", "AGENTSCONFIG_DEFAULTS_SUITE",
                    "XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"] {
            #expect(!start(Self.release, env: [key: "/tmp/fixture"]), "\(key)")
            // Presence counts, even with an empty value.
            #expect(!start(Self.release, env: [key: ""]), "\(key) empty")
        }
    }

    @Test func missingOrInsecureFeedConfigurationBlocksTheUpdater() {
        var noKey = Self.info; noKey["SUPublicEDKey"] = nil
        var blankKey = Self.info; blankKey["SUPublicEDKey"] = "  "
        var noFeed = Self.info; noFeed["SUFeedURL"] = nil
        var http = Self.info; http["SUFeedURL"] = "http://github.com/tavodev/agentsconfig/appcast.xml"
        var garbage = Self.info; garbage["SUFeedURL"] = "not a url"
        for info in [noKey, blankKey, noFeed, http, garbage, [:]] {
            #expect(!start(Self.release, info: info))
        }
    }

    @Test func theHostlessTestProcessItselfNeverStartsTheUpdater() {
        #expect(!UpdaterPolicy.currentProcess)
    }

    /// The generated Info.plist is what ships: feed, key and the owner's
    /// defaults (check daily, download and install automatically).
    @Test func shippedInfoPlistConfiguresSignedDailyAutomaticUpdates() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Support/Info.plist")
        let data = try Data(contentsOf: plist)
        let info = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(info["SUFeedURL"] as? String
                == "https://github.com/tavodev/agentsconfig/releases/latest/download/appcast.xml")
        let key = try #require(info["SUPublicEDKey"] as? String)
        #expect(Data(base64Encoded: key)?.count == 32)
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(info["SUAutomaticallyUpdate"] as? Bool == true)
        #expect(info["SUScheduledCheckInterval"] as? Int == 86_400)
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(info["SURequireSignedFeed"] as? Bool == true)
        #expect(info["SUEnableSystemProfiling"] == nil)
        #expect(start(Self.release, info: info))
    }

    @Test func togglesWriteThroughAndReloadFollowsTheBackend() {
        let backend = FakeUpdaterBackend()
        let updater = AppUpdater(backend: backend)
        #expect(updater.automaticallyChecksForUpdates)
        #expect(updater.automaticallyDownloadsUpdates)

        updater.automaticallyDownloadsUpdates = false
        #expect(!backend.automaticallyDownloadsUpdates)
        updater.automaticallyChecksForUpdates = false
        #expect(!backend.automaticallyChecksForUpdates)
        #expect(backend.writes == 2)

        // Sparkle changing its own settings (update alert checkbox) is mirrored
        // without being written back.
        backend.automaticallyDownloadsUpdates = true
        backend.canCheckForUpdates = false
        backend.onStateChange?()
        #expect(updater.automaticallyDownloadsUpdates)
        #expect(!updater.canCheckForUpdates)
        #expect(backend.writes == 3)

        updater.checkForUpdates()
        #expect(backend.checks == 0)
        backend.canCheckForUpdates = true
        backend.onStateChange?()
        updater.checkForUpdates()
        #expect(backend.checks == 1)
    }
}
}

@MainActor
private final class FakeUpdaterBackend: UpdaterBackend {
    var writes = 0
    var checks = 0
    var automaticallyChecksForUpdates = true { didSet { writes += 1 } }
    var automaticallyDownloadsUpdates = true { didSet { writes += 1 } }
    var canCheckForUpdates = true
    var lastUpdateCheckDate: Date?
    var onStateChange: (() -> Void)?
    func checkForUpdates() { checks += 1 }
}
