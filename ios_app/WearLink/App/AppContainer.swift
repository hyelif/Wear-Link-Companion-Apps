import SwiftUI

/// Tiny dependency-injection container.
/// Created once at app launch; view models read services from it.
@MainActor
@Observable
final class AppContainer {
    let ble: BLEManager
    let health: HealthViewModel
    let call: CallController
    let notification: NotificationForwarder
    let music: MusicController

    /// Current paired device info (populated via BLE).
    var device: WearableDevice?
    /// User-configurable device settings.
    var settings = DeviceSettings()

    private(set) var didStart = false

    init() {
        let ble = BLEManager()
        self.ble = ble
        self.health = HealthViewModel(ble: ble)
        self.call = CallController(ble: ble)
        self.notification = NotificationForwarder(ble: ble)
        self.music = MusicController(ble: ble)

        // Wire feature controllers into BLEManager so inbound watch data
        // (callAction, notificationAction, musicCommand) is dispatched
        // immediately when GattClient connects.
        ble.callController = self.call
        ble.notificationForwarder = self.notification
        ble.musicController = self.music
    }

    func start() async {
        guard !didStart else { return }
        didStart = true

        // Wire BLE onPayload handlers for inbound watch data.
        // These fire when the watch sends data on the corresponding
        // characteristic; they decode the proto and dispatch to the
        // appropriate feature controller.
        guard let gatt = ble.gatt else {
            assertionFailure("AppContainer.start: gatt not ready — onPayload handlers not registered")
            return
        }
        gatt.onPayload[WearLinkUUID.callAction] = { [weak self] data in
            guard let self, let action = ProtoCodec.decodeCallAction(from: data) else { return }
            self.call.applyAction(action)
        }
        gatt.onPayload[WearLinkUUID.notificationAction] = { [weak self] data in
            guard let self, let action = ProtoCodec.decodeNotifAction(from: data) else { return }
            self.notification.handleAction(action)
        }
        gatt.onPayload[WearLinkUUID.musicCommand] = { [weak self] data in
            guard let self, let command = ProtoCodec.decodeMusicCommand(from: data) else { return }
            self.music.dispatchCommand(command)
        }

        // Start health monitoring (HealthKit authorization).
        // Wrap in do-catch to prevent crashes on devices without HealthKit access
        // (e.g., SideStore unsigned builds with free developer accounts).
        do {
            try await health.requestAuthorization()
        } catch {
            print("[AppContainer] HealthKit authorization failed (non-fatal): \(error)")
        }

        // Begin BLE scanning for the watch.
        ble.startScanning()
    }
}
