import UserNotifications
import Foundation

/// Notification content extension. Intercepts push notifications targeting the
/// WearLink bundle and forwards them to the watch over BLE via a shared
/// app-group bridge.
///
/// HARD LIMIT — see Software-Structure §9: this only sees notifications sent
/// to THIS app bundle. It CANNOT see WhatsApp/iMessage/Instagram etc.
/// General cross-app forwarding requires an opt-in relay server.
final class NotificationService: UNNotificationServiceExtension {
    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttempt: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttempt = request.content.mutableCopy() as? UNMutableNotificationContent

        // TODO: forward payload to main app via app-group / to watch via BLE.
        // For now pass through unchanged.
        if let bestAttempt = bestAttempt { contentHandler(bestAttempt) }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler = contentHandler, let bestAttempt = bestAttempt {
            contentHandler(bestAttempt)
        }
    }
}