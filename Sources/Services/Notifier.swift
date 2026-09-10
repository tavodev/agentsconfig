import Foundation
@preconcurrency import UserNotifications
import AppKit

/// Posts macOS notifications when an agent rewrites a config while the app
/// is in the background. Clicking one selects the file in the app.
/// All public entry points run on the main actor.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()

    /// Called with the changed file path when the user clicks a notification.
    var onSelect: (@MainActor (String) -> Void)?

    private var center: UNUserNotificationCenter? {
        // Guard: requires an app bundle; nil-safe for `swift run` style launches.
        Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil
    }

    func configure() {
        center?.delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Only fires while frontmost; the in-app banner already covers it.
        completion([])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completion: @escaping () -> Void
    ) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            Task { @MainActor in Notifier.shared.onSelect?(path) }
        }
        completion()
    }
}

extension Notifier {
    func postChange(path: String, agentName: String, summary: String) {
        guard AppSettings.notificationsEnabled,
              !NSApplication.shared.isActive,
              let center else { return }
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { Self.deliver(center, path: path, agentName: agentName, summary: summary) }
                }
            case .authorized, .provisional, .ephemeral:
                Self.deliver(center, path: path, agentName: agentName, summary: summary)
            default: break
            }
        }
    }

    nonisolated private static func deliver(_ center: UNUserNotificationCenter,
                                            path: String, agentName: String, summary: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(agentName): config modificada"
        content.body = "\(URL(fileURLWithPath: path).lastPathComponent) — \(summary)"
        content.userInfo = ["path": path]
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "change-\(path)-\(Date().timeIntervalSince1970)",
            content: content, trigger: nil
        )
        center.add(req)
    }
}
