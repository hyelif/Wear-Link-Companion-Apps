import Foundation

/// Receives health frames from the watch over BLE (`FE20`), decodes them,
/// and exposes the latest values per metric type as `@Observable` properties
/// for the UI layer.
///
/// This replaces the HealthKit-write path (removed for SideStore free-account
/// compatibility). No entitlement needed — data flows entirely over BLE.
@MainActor
@Observable
final class HealthManager {
    // MARK: - Latest values (nil = no data received yet)

    private(set) var lastHeartRate: Double?
    private(set) var lastSteps: Int?
    private(set) var lastSpo2: Double?
    private(set) var lastHrv: Double?
    private(set) var lastCalories: Double?
    private(set) var lastDistance: Double?
    /// Timestamp of the most recent `HealthFrame` received.
    private(set) var lastUpdate: Date?
    /// Sequence number of the most recent frame (for ordering).
    private(set) var lastSequence: UInt32 = 0

    /// Whether any health data has ever been received.
    var hasData: Bool { lastUpdate != nil }

    // MARK: - Dependencies

    private let ble: BLEManager

    init(ble: BLEManager) {
        self.ble = ble
        registerHandler()
        observeReconnection()
    }

    deinit {
        NotificationCenter.default.removeObserver(
            self,
            name: .bleDidReconnect,
            object: nil
        )
    }

    // MARK: - Ingest

    /// Called by BLEManager's onPayload handler when a `HealthFrame` arrives
    /// on the `FE20` characteristic.
    func ingest(_ frame: HealthFrame) {
        lastSequence = frame.sequence
        lastUpdate = Date()

        for sample in frame.samples {
            switch sample.type {
            case .heartRateBpm:
                lastHeartRate = sample.value
            case .steps:
                lastSteps = Int(sample.value)
            case .spo2Percent:
                lastSpo2 = sample.value
            case .hrvMs:
                lastHrv = sample.value
            case .calories:
                lastCalories = sample.value
            case .distanceMeters:
                lastDistance = sample.value
            case .sleep:
                // Sleep is a complex type; Phase 2 handling.
                break
            case .typeUnspecified:
                break
            }
        }
    }

    /// Reset all values (called on BLE disconnect).
    func clear() {
        lastHeartRate = nil
        lastSteps = nil
        lastSpo2 = nil
        lastHrv = nil
        lastCalories = nil
        lastDistance = nil
        lastUpdate = nil
        lastSequence = 0
    }

    // MARK: - BLE handler registration

    /// Registers the inbound health-stream handler on the current GattClient.
    /// Safe to call when gatt is nil — handler is set when available.
    func registerHandler() {
        ble.gatt?.onPayload[WearLinkUUID.healthStream] = { [weak self] data in
            guard let self,
                  let frame = ProtoCodec.decodeHealthFrame(from: data)
            else { return }
            Task { @MainActor in
                self.ingest(frame)
            }
        }
    }

    // MARK: - Reconnection

    private func observeReconnection() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleReconnection),
            name: .bleDidReconnect,
            object: nil
        )
    }

    @objc private func handleReconnection() {
        registerHandler()
    }
}