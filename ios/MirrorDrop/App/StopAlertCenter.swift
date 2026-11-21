import Foundation
import UserNotifications

/// App side of the "TV 보내기가 끝났어요" notification (the extension schedules it, see
/// MirrorDropBroadcast/StopAlertArmer.swift): asks for permission, hides it while the app is in front
/// (the main screen shows the same thing), and on a tap brings the user to the start card.
final class StopAlertCenter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = StopAlertCenter()

    /// Set when the user tapped the notification; the main screen shows the start card and clears it.
    @Published var wantsStartCard = false

    /// Must run before the app finishes launching, or a tap that launched the app is missed.
    func setUp() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asks once (only while undecided), when the first broadcast starts. Alert only: no sound or badge.
    func requestPermissionIfNeeded() {
        // No permission prompt over a store screenshot (App/DemoMode.swift; nil in the shipped app).
        if DemoMode.current != nil { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert]) { _, _ in }
        }
    }

    /// Removes a shown "ended" notification. Never removes the pending one: during a broadcast that
    /// is the extension's dead-man alert.
    func clearDelivered() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [StopAlert.identifier])
    }

    /// The broadcast ended while the app is in front: removes the pending alert the extension scheduled at
    /// the end, and a shown one. Only when no broadcast is live (MirrorCastCoordinator).
    func clearAll() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [StopAlert.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [StopAlert.identifier])
    }

    /// The user tapped the main screen's stop card while sending (it opens the system sheet whose "Stop
    /// Broadcast" ends it): the extension then skips the alert (Shared/StopAlert.swift StopAlertFinish).
    func noteUserStopTap() {
        UserStopMark.record()
    }

    // MARK: UNUserNotificationCenterDelegate

    /// In front, the status card already says the broadcast stopped, so no banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        if response.notification.request.identifier == StopAlert.identifier,
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { self.wantsStartCard = true }
        }
        completionHandler()
    }
}
