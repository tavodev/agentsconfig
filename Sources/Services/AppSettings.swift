import Foundation

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
}
