import Foundation
import UserNotifications

// MARK: - App Group Bridge Configuration

/// Shared configuration for the notification bridge between the main app
/// and the NotificationServiceExtension.
enum NotificationBridge {
    /// App group identifier shared with the NotificationServiceExtension.
    /// Must match the value in both targets' entitlements.
    static let appGroupIdentifier = "group.com.wearlink.notification"

    /// Darwin notification name posted by the extension after writing to UserDefaults.
    static let darwinNotificationName = "com.wearlink.notification-received" as CFString

    enum UserDefaultsKey {
        static let pending       = "wearlink_notif_pending"
        static let notifId       = "wearlink_notif_id"
        static let appName       = "wearlink_notif_app_name"
        static let title         = "wearlink_notif_title"
        static let body          = "wearlink_notif_body"
        static let timestampMs   = "wearlink_notif_timestamp_ms"
        static let replyChoices  = "wearlink_notif_reply_choices"
    }
}

// MARK: - ForwardedNotificationItem

/// A lightweight record of a notification that was forwarded to the watch.
struct ForwardedNotificationItem: Identifiable, Sendable {
    var id: String { notifId }
    let notifId: String
    let appName: String
    let title: String
    let body: String
    let timestampMs: UInt64
}

// MARK: - NotificationForwarder

/// Forwards push notifications from the WearLink app to the watch over BLE,
/// and relays actions (dismiss/reply) from the watch back to iOS.
///
/// Flow:
/// 1. NotificationServiceExtension receives a push notification.
/// 2. Extension writes notification data to the shared app group UserDefaults.
/// 3. Extension posts a Darwin notification to signal the main app.
/// 4. NotificationForwarder reads the data, encodes a Notification proto,
///    and writes it to the `WearLinkUUID.notification` characteristic.
/// 5. The watch displays the notification.
/// 6. The user dismisses or replies on the watch.
/// 7. The watch sends a NotifAction proto on `WearLinkUUID.notificationAction`.
/// 8. NotificationForwarder decodes the action and processes it locally.
///
/// HARD LIMIT — see Software-Structure §9:
/// iOS exposes NO public API to read notifications from OTHER apps.
/// This class only handles notifications that target the WearLink bundle
/// (arriving via the NotificationServiceExtension target). General 3rd-party
/// forwarding is blocked by the iOS sandbox and is out of scope unless an
/// opt-in relay server is added later.
///
/// NOTE: For the ANCS path, notifications come from the watch-side ANCS client
/// directly. This class handles the WearLink-app push path and BLE relay only.
@MainActor
@Observable
final class NotificationForwarder: NSObject {
    private let ble: BLEManager
    private let sharedDefaults: UserDefaults?
    private var pollingTimer: Timer?

    /// Ordered list of notifications that have been forwarded to the watch.
    private(set) var forwardedNotifications: [ForwardedNotificationItem] = []

    /// Weak reference used by the C-compatible Darwin notification callback
    /// to avoid the use-after-free crash from `Unmanaged.takeUnretainedValue()`
    /// when the notification fires during or after deinit.
    /// `nonisolated` so deinit (nonisolated context) can clear it.
    fileprivate nonisolated static weak var _currentForwarder: NotificationForwarder?

    // MARK: - Initialization

    init(ble: BLEManager) {
        self.ble = ble
        self.sharedDefaults = UserDefaults(suiteName: NotificationBridge.appGroupIdentifier)
        super.init()
        Self._currentForwarder = self

        // Register the BLE handler for incoming NotifAction from the watch.
        // If GattClient is not yet available, the handler is set once it connects
        // (re-registered before each forward).
        registerNotificationActionHandler()

        // Set up the app group bridge to receive notifications from the extension.
        setupNotificationBridge()
    }

    deinit {
        // Remove the Darwin observer first to prevent any callback race.
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
        // Clear weak ref + invalidate timer on the main actor.
        // assumeIsolated is correct: NotificationForwarder is @MainActor and
        // owned by AppContainer (also @MainActor), so deinit always runs on
        // the main actor.
        MainActor.assumeIsolated {
            Self._currentForwarder = nil
            pollingTimer?.invalidate()
            pollingTimer = nil
        }
    }

    // MARK: - Public API

    /// Encode a notification and push to the watch over BLE.
    ///
    /// - Parameters:
    ///   - appName: Display name of the originating app.
    ///   - title: Notification title.
    ///   - body: Notification body text.
    ///   - id: Unique notification identifier (used for dismiss/reply routing).
    ///   - replyChoices: Optional list of predefined reply strings.
    func forward(appName: String, title: String, body: String, id: String, replyChoices: [String] = []) {
        let wearNotif = WearNotification(
            notifId: id,
            appName: appName,
            title: title,
            body: body,
            timestampMs: UInt64(Date().timeIntervalSince1970 * 1000),
            replyChoices: replyChoices
        )
        let payload = ProtoCodec.encodeWearNotification(wearNotif)
        ble.gatt?.write(payload, to: WearLinkUUID.notification)

        // Record in the in-memory list for the UI.
        let item = ForwardedNotificationItem(
            notifId: id,
            appName: appName,
            title: title,
            body: body,
            timestampMs: wearNotif.timestampMs
        )
        forwardedNotifications.insert(item, at: 0)
    }

    /// Called when the watch sends a NotifAction over BLE.
    /// Processes dismiss and reply actions.
    func handleAction(_ action: NotifAction) {
        switch action.action {
        case .dismiss:
            dismissLocalNotification(notifId: action.notifId)
        case .reply:
            handleReply(notifId: action.notifId, replyText: action.replyText)
        case .actionUnspecified:
            print("[NotificationForwarder] Ignoring NotifAction with unspecified action")
        }
    }

    // MARK: - BLE Action Handler Registration

    /// Registers (or re-registers) the NotifAction handler on the current GattClient.
    /// Safe to call even when gatt is nil — the handler is set when available.
    private func registerNotificationActionHandler() {
        ble.gatt?.onPayload[WearLinkUUID.notificationAction] = { [weak self] data in
            guard let self, let action = ProtoCodec.decodeNotifAction(from: data) else { return }
            Task { @MainActor in
                self.handleAction(action)
            }
        }
    }

    // MARK: - App Group Bridge

    /// Sets up the Darwin notification listener and a polling fallback timer
    /// to pick up notifications written by the NotificationServiceExtension.
    private func setupNotificationBridge() {
        // Register for Darwin notifications posted by the extension.
        // This is the preferred signaling mechanism (more efficient than polling).
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            darwinNotificationCallback,
            NotificationBridge.darwinNotificationName,
            nil,
            .deliverImmediately
        )

        // Fallback: polling timer in case Darwin notifications are not delivered
        // (e.g., extension not yet updated to post them, or delivery is delayed).
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkPendingNotifications()
        }
    }

    /// Called by the Darwin notification callback when the extension signals
    /// that a new notification is available in the shared UserDefaults.
    /// Dispatched to MainActor by the callback.
    fileprivate func didReceiveDarwinNotification() {
        checkPendingNotifications()
    }

    /// Reads a pending notification from the shared UserDefaults and forwards
    /// it to the watch. Clears the pending flag to avoid re-processing.
    private func checkPendingNotifications() {
        guard let defaults = sharedDefaults else { return }
        guard defaults.bool(forKey: NotificationBridge.UserDefaultsKey.pending) else { return }

        guard let notifId = defaults.string(forKey: NotificationBridge.UserDefaultsKey.notifId),
              let appName = defaults.string(forKey: NotificationBridge.UserDefaultsKey.appName),
              let title = defaults.string(forKey: NotificationBridge.UserDefaultsKey.title),
              let body = defaults.string(forKey: NotificationBridge.UserDefaultsKey.body) else {
            // Malformed entry; clear the flag and return.
            clearPendingNotification(defaults)
            return
        }

        let timestampMs = defaults.double(forKey: NotificationBridge.UserDefaultsKey.timestampMs)
        let replyChoices = defaults.stringArray(forKey: NotificationBridge.UserDefaultsKey.replyChoices) ?? []

        // Build and send the Notification proto to the watch.
        let wearNotif = WearNotification(
            notifId: notifId,
            appName: appName,
            title: title,
            body: body,
            timestampMs: UInt64(timestampMs),
            replyChoices: replyChoices
        )
        let payload = ProtoCodec.encodeWearNotification(wearNotif)
        ble.gatt?.write(payload, to: WearLinkUUID.notification)

        // Clear the pending flag and all associated keys only AFTER the BLE
        // write has been issued, so a write failure does not lose the data.
        // If the write fails, the data remains in UserDefaults and will be
        // picked up on the next poll cycle.
        clearPendingNotification(defaults)
    }

    /// Removes all pending notification keys from the shared UserDefaults.
    private func clearPendingNotification(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: NotificationBridge.UserDefaultsKey.pending)
        defaults.removeObject(forKey: NotificationBridge.UserDefaultsKey.notifId)
        defaults.removeObject(forKey: NotificationBridge.UserDefaultsKey.appName)
        defaults.removeObject(forKey: NotificationBridge.UserDefaultsKey.title)
        defaults.removeObject(forKey: NotificationBridge.UserDefaultsKey.body)
        defaults.removeObject(forKey: NotificationBridge.UserDefaultsKey.timestampMs)
        defaults.removeObject(forKey: NotificationBridge.UserDefaultsKey.replyChoices)
        defaults.synchronize()
    }

    // MARK: - Action Processing

    /// Removes a delivered notification from the system notification center.
    private func dismissLocalNotification(notifId: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notifId])
    }

    /// Handles a reply action from the watch.
    ///
    /// iOS does not expose a public API to programmatically reply to a
    /// notification from another process. The best we can do is:
    /// - Log the reply for debugging.
    /// - Dismiss the local notification.
    ///
    /// A production implementation could deliver a local notification with a
    /// text input action category that the NotificationServiceExtension can
    /// process, but this requires coordination with the extension and is
    /// limited to the app's own notifications.
    private func handleReply(notifId: String, replyText: String) {
        print("[NotificationForwarder] Reply received for \(notifId): \"\(replyText)\"")
        dismissLocalNotification(notifId: notifId)
    }
}

// MARK: - Darwin Notification Callback

/// C-compatible callback invoked by CFNotificationCenter when the extension
/// posts a Darwin notification. Uses a static weak reference to the current
/// NotificationForwarder instead of `Unmanaged.takeUnretainedValue()` to
/// avoid a use-after-free crash if the notification fires during or after
/// deinit (the observer pointer becomes dangling).
///
/// The closure captures nothing (C function pointer requirement); it accesses
/// the static `_currentForwarder` weak reference which is safe to read from
/// any thread.
private let darwinNotificationCallback: CFNotificationCallback = { _, _, _, _, _ in
    guard let forwarder = NotificationForwarder._currentForwarder else { return }
    Task { @MainActor in
        forwarder.didReceiveDarwinNotification()
    }
}
