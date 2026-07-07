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

        // Inbound watch data (callAction / notificationAction / musicCommand) is
        // dispatched by BLEManager.centralManager(_:didConnect:) -> GattClient.onPayload,
        // re-registered on every connect. AppContainer wires the feature controllers
        // into BLEManager in init() (callController / notificationForwarder /
        // musicController), so nothing to register here at launch. The previous
        // `guard let gatt = ble.gatt else { assertionFailure; return }` was wrong: no
        // GATT connection exists at launch, so it bailed (crashing in debug) and
        // skipped health authorization + startScanning — the app never connected.

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
