import Foundation
import UserNotifications

/// Shows the notifications `Alerts` decides on, through macOS's own notification centre (local only).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func start() { center.delegate = self }

    /// Asks macOS for permission (it shows its own question the first time). `done` gets the answer on the main thread.
    func request(_ done: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in DispatchQueue.main.async { done(ok) } }
    }

    func post(_ e: Alerts.Event) {
        let c = UNMutableNotificationContent()
        c.title = e.title
        c.body = e.body
        c.sound = .default
        center.add(UNNotificationRequest(identifier: "\(e.key)|\(Date().timeIntervalSince1970)", content: c, trigger: nil))
    }

    /// Show it even while the app's own panel is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}
