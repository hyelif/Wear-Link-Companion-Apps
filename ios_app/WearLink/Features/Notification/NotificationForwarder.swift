import Foundation

/// Forwards notifications to the watch.
///
/// HARD LIMIT — see Software-Structure §9:
/// iOS exposes NO public API to read notifications from OTHER apps.
/// This class therefore only handles notifications that target the WearLink
/// bundle (arriving via the NotificationServiceExtension target). General
/// 3rd-party forwarding is blocked by the iOS sandbox and is out of scope
/// unless an opt-in relay server is added later.
@MainActor
@Observable
final class NotificationForwarder {
    private let ble: BLEManager

    init(ble: BLEManager) { self.ble = ble }

    /// Encode a WearLink-app notification and push to the watch.
    func forward(appName: String, title: String, body: String, id: String) {
        // TODO: encode Notification proto, ble.gatt?.write(_, to: notification)
        _ = appName; _ = title; _ = body; _ = id
    }

    /// Watch replied / dismissed a notification.
    func handleAction(_ action: NotificationAction) {
        // TODO: route back to originating push / mark read.
    }
}

enum NotificationAction { case dismiss, reply(String) }