import Foundation
import AppKit

/// App-wide preferences backed by UserDefaults (editable in the Settings scene).
enum AppSettings {
    /// Test seam: preferences are read from this suite instead of
    /// `UserDefaults.standard`. Each test installs an exclusive suite and
    /// restores `.standard` on teardown — mutate only from serialized tests.
    nonisolated(unsafe) static var defaults: UserDefaults = {
        guard isIsolatedRun, let suite = ProcessInfo.processInfo.environment["AGENTSCONFIG_DEFAULTS_SUITE"],
              let defaults = UserDefaults(suiteName: suite) else { return .standard }
        return defaults
    }()

    /// UI verification opts into both a scratch home and a dedicated suite.
    static var isIsolatedRun: Bool {
        ProcessInfo.processInfo.environment["AGENTSCONFIG_HOME"] != nil
            && ProcessInfo.processInfo.environment["AGENTSCONFIG_DEFAULTS_SUITE"] != nil
    }

    static var watchDebounce: TimeInterval {
        let v = defaults.double(forKey: "watchDebounce")
        return v > 0 ? v : 0.35
    }

    static var historyLimit: Int {
        let v = defaults.integer(forKey: "historyLimit")
        return v > 0 ? v : 200
    }

    static var historyEnabled: Bool {
        defaults.object(forKey: "historyEnabled") as? Bool ?? true
    }

    static var notificationsEnabled: Bool {
        defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
    }

    static var maskSecrets: Bool {
        defaults.object(forKey: "maskSecrets") as? Bool ?? true
    }

    static var menuBarExtra: Bool {
        defaults.object(forKey: "menuBarExtra") as? Bool ?? true
    }

    static var appearance: NSAppearance? {
        switch defaults.string(forKey: "appearance") ?? "system" {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default: return nil   // follow system
        }
    }
}
