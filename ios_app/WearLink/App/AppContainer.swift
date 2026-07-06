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

    private(set) var didStart = false

    init() {
        let ble = BLEManager()
        self.ble = ble
        self.health = HealthViewModel(ble: ble)
        self.call = CallController(ble: ble)
        self.notification = NotificationForwarder(ble: ble)
        self.music = MusicController(ble: ble)
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        ble.startScanning()
    }
}