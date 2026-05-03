import UIKit
import UserNotifications

/// Bridges UNUserNotificationCenter callbacks into app logic (ETA fallback deadline delivery).
final class LocolarmAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        AlarmService.shared.recoverActiveAlarmPlaybackIfNeeded()
        LocationService.shared.handleEtaFallbackDeadlineNotificationEvent()
    }
}

extension LocolarmAppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.identifier == ETAFallbackConstants.deadlineNotificationIdentifier {
            NotificationCenter.default.post(name: .locolarmEtaFallbackDeadline, object: nil)
            completionHandler([.banner, .sound])
        } else {
            completionHandler([.banner, .sound])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.identifier == ETAFallbackConstants.deadlineNotificationIdentifier {
            NotificationCenter.default.post(name: .locolarmEtaFallbackDeadline, object: nil)
        }
        completionHandler()
    }
}
