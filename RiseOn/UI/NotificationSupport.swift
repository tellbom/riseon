import Foundation
import UserNotifications

/// Local notifications for initialization completion/failure (task.md
/// S14.1). Display-only, per plan.md §12: this is called *after*
/// `InitializationQueue` has already settled on its own — it never
/// triggers, extends, or depends on any background computation itself.
public enum WorkspaceNotificationCenter {

    /// Requests notification permission. Safe to call repeatedly — iOS only
    /// prompts once; later calls just report back the existing status.
    @discardableResult
    public static func requestAuthorizationIfNeeded(
        center: UNUserNotificationCenter = .current()
    ) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        case .denied, .ephemeral:
            return false
        @unknown default:
            return false
        }
    }

    /// Schedules an immediate local notification reflecting how a stock's
    /// initialization ended. Never throws — a missing/denied permission
    /// just means no notification appears; that's not something the rest
    /// of the app should have to handle as an error.
    public static func notifyInitializationSettled(
        code: String,
        name: String,
        outcome: InitializationQueue.Outcome,
        center: UNUserNotificationCenter = .current()
    ) async {
        let (title, body) = content(for: code, name: name, outcome: outcome)

        let notification = UNMutableNotificationContent()
        notification.title = title
        notification.body = body
        notification.sound = .default

        // One stable identifier per stock -- a second settle event (e.g.
        // failed, then later a manual retry succeeds) replaces the earlier
        // notification for the same code rather than piling up duplicates.
        let request = UNNotificationRequest(identifier: "workspace-init-\(code)", content: notification, trigger: nil)
        try? await center.add(request)
    }

    /// Pure title/body construction, split out from the actual
    /// `UNUserNotificationCenter` call so the wording itself is unit
    /// testable without needing notification permission or a real device —
    /// same reasoning as `TencentDailyProvider.parseBars` being exposed
    /// separately from the network call it backs.
    static func content(for code: String, name: String, outcome: InitializationQueue.Outcome) -> (title: String, body: String) {
        let displayName = name.isEmpty ? code : name
        switch outcome {
        case .succeeded:
            return ("「\(displayName)」初始化完成", "\(code) 已就绪，现在可以开始问答。")
        case .failed(let step):
            return ("「\(displayName)」初始化失败", "在「\(step.displayName)」这一步失败了，点击重试。")
        }
    }
}
