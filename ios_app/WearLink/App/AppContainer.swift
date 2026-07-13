import SwiftUI

/// Tiny dependency-injection container.
/// Created once at app launch; view models read services from it.
@MainActor
@Observable
final class AppContainer {
    let ble: BLEManager
    let call: CallController
    let notification: NotificationForwarder
    let music: MusicController
    let health: HealthManager

    /// Current paired device info (populated via BLE).
    var device: WearableDevice?
    /// User-configurable device settings.
    var settings = DeviceSettings()

    private(set) var didStart = false

    init() {
        let ble = BLEManager()
        self.ble = ble
        self.call = CallController(ble: ble)
        self.health = HealthManager(ble: ble)
        self.notification = NotificationForwarder(ble: ble)
        self.music = MusicController(ble: ble)

        // Wire feature controllers into BLEManager so inbound watch writes
        // (callAction, notificationAction, musicCommand) are dispatched
        // immediately when a central subscribes. In bridge mode the iPhone is
        // the GATT server; these weak refs are the dispatch targets for
        // didReceiveWriteRequests.
        ble.callController = self.call
        ble.notificationForwarder = self.notification
        ble.musicController = self.music
        ble.healthManager = self.health
        ble.appContainer = self
    }

    func start() async {
        guard !didStart else { return }
        didStart = true

        // Bridge model: BLEManager is a CBPeripheralManager. startScanning()
        // (kept under its historical name for view compatibility) publishes the
        // WearLink GATT service and starts advertising; the watch scans and
        // connects. No central-side scan/connect happens on the iPhone anymore.
        ble.startScanning()
    }

    /// Stop advertising and clear the device model.
    func disconnectDevice() {
        ble.disconnect()
        device = nil
        settings = DeviceSettings()
    }
}
