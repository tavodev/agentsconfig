import Foundation
import AppKit

/// App-wide preferences backed by UserDefaults (editable in the Settings scene).
enum AppSettings {
    static var watchDebounce: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "watchDebounce")
        return v > 0 ? v : 0.35
    }

    static var historyLimit: Int {
        let v = UserDefaults.standard.integer(forKey: "historyLimit")
        return v > 0 ? v : 200
    }

    static var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
    }

    static var maskSecrets: Bool {
        UserDefaults.standard.object(forKey: "maskSecrets") as? Bool ?? true
    }

    static var menuBarExtra: Bool {
        UserDefaults.standard.object(forKey: "menuBarExtra") as? Bool ?? true
    }

    static var appearance: NSAppearance? {
        switch UserDefaults.standard.string(forKey: "appearance") ?? "system" {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default: return nil   // follow system
        }
    }
}
