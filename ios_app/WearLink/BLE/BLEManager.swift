import Foundation
import CoreBluetooth

/// Central-side BLE manager. Scans for the WearLink watch, connects, bonds,
/// and exposes the discovered `GattClient`.
///
/// Battery: duty-cycled scan (2 s on / 8 s off) when disconnected;
/// stops scanning immediately on connect. See Software-Structure §4/§6.
@MainActor
@Observable
final class BLEManager: NSObject, CBCentralManagerDelegate {
    enum State: Equatable {
        case poweredOff, scanning, connecting, connected, disconnected(Error?)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.poweredOff, .poweredOff),
                 (.scanning, .scanning),
                 (.connecting, .connecting),
                 (.connected, .connected):
                return true
            case let (.disconnected(le), .disconnected(re)):
                let l = le as NSError?, r = re as NSError?
                return l?.domain == r?.domain && l?.code == r?.code
            default:
                return false
            }
        }
    }

    private(set) var state: State = .poweredOff
    private(set) var gatt: GattClient?

    /// Feature controllers that receive inbound data from the watch.
    /// Set by AppContainer after all controllers are initialized.
    weak var callController: CallController?
    weak var notificationForwarder: NotificationForwarder?
    weak var musicController: MusicController?
    weak var healthManager: HealthManager?
    /// Set by AppContainer so BLEManager can update the device model on incoming data.
    weak var appContainer: AppContainer?

    private let central: CBCentralManager
    private var scanTimer: Timer?
    private var restTimer: Timer?
    private var heartbeatTimer: Timer?
    private let scanOn: TimeInterval = 2.0
    private let scanOff: TimeInterval = 8.0
    private let scanOffMax: TimeInterval = 120.0
    private var scanFailureCount: Int = 0
    private let heartbeatInterval: TimeInterval = 30.0

    override init() {
        // `options` let CoreBluetooth restore state across relaunches.
        self.central = CBCentralManager(delegate: nil, queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false])
        super.init()
        central.delegate = self
    }

    deinit {
        scanTimer?.invalidate()
        restTimer?.invalidate()
        heartbeatTimer?.invalidate()
    }

    func startScanning() {
        guard central.state == .poweredOn else { return }
        beginScanCycle()
    }

    private func beginScanCycle() {
        scanTimer?.invalidate()
        restTimer?.invalidate()
        central.scanForPeripherals(withServices: [WearLinkUUID.service],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        state = .scanning
        scanTimer = Timer.scheduledTimer(withTimeInterval: scanOn, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.central.stopScan()
            // Exponential backoff: if no device found, progressively increase rest
            // period up to scanOffMax (2 min) to save battery.
            let rest = min(self.scanOff * pow(2.0, Double(self.scanFailureCount)), self.scanOffMax)
            self.scanFailureCount += 1
            self.restTimer = Timer.scheduledTimer(withTimeInterval: rest, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.beginScanCycle()
                }
            }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        Task { @MainActor in
            switch c.state {
            case .poweredOn:
                startScanning()
            case .poweredOff:
                state = .poweredOff
                invalidateAll()
            case .unauthorized:
                state = .poweredOff
                print("[BLE] Bluetooth unauthorized — grant Bluetooth permission in Settings")
                invalidateAll()
            case .unsupported:
                state = .poweredOff
                print("[BLE] Bluetooth unsupported on this device")
                invalidateAll()
            case .resetting:
                state = .poweredOff
                invalidateAll()
            case .unknown:
                break
            @unknown default:
                break
            }
        }
    }

    private func invalidateAll() {
        scanTimer?.invalidate(); scanTimer = nil
        restTimer?.invalidate(); restTimer = nil
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        gatt = nil
        scanFailureCount = 0
        state = .poweredOff
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            central.stopScan()
            scanTimer?.invalidate(); restTimer?.invalidate()
            scanFailureCount = 0  // Reset backoff on discovery
            state = .connecting
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            let client = GattClient(peripheral: peripheral)
            // Echo inbound LinkControl frames back as acks (heartbeat echo).
            client.onLinkControl = { [weak self] frame in
                Task { @MainActor in
                    let seqData = withUnsafeBytes(of: frame.seq.bigEndian) { Data($0) }
                    self?.gatt?.write(seqData, to: WearLinkUUID.linkControl)
                }
            }
            // Register inbound payload handlers for feature characteristics
            // that the watch writes to (callAction, notificationAction, musicCommand).
            // Each handler hops to the main actor: BLEManager is @MainActor, so its
            // callController/notificationForwarder/musicController and gatt/state are
            // main-actor-isolated and cannot be touched from the peripheral-delegate
            // (nonisolated) closure directly.
            client.onPayload[WearLinkUUID.callAction] = { [weak self] data in
                Task { @MainActor in
                    guard let self, let action = ProtoCodec.decodeCallAction(from: data) else { return }
                    self.callController?.applyAction(action)
                }
            }
            client.onPayload[WearLinkUUID.notificationAction] = { [weak self] data in
                Task { @MainActor in
                    guard let self, let action = ProtoCodec.decodeNotifAction(from: data) else { return }
                    self.notificationForwarder?.handleAction(action)
                }
            }
            client.onPayload[WearLinkUUID.musicCommand] = { [weak self] data in
                Task { @MainActor in
                    guard let self, let command = ProtoCodec.decodeMusicCommand(from: data) else { return }
                    self.musicController?.dispatchCommand(command)
                }
            }
            client.onPayload[WearLinkUUID.healthStream] = { [weak self] data in
                Task { @MainActor in
                    guard let self, let frame = ProtoCodec.decodeHealthFrame(from: data) else { return }
                    self.healthManager?.ingest(frame)
                }
            }
            self.gatt = client
            self.state = .connected
            peripheral.delegate = client
            client.discoverServices()
            self.startHeartbeat()
            // Register device info handler — decode FE10 notify payload into WearableDevice.
            client.onPayload[WearLinkUUID.deviceInfo] = { [weak self] data in
                Task { @MainActor in
                    guard let self, let info = ProtoCodec.decodeDeviceInfo(from: data) else { return }
                    // Map BLE DeviceInfo proto to the WearableDevice model.
                    let device = WearableDevice(
                        id: "watch-001",
                        name: info.model,
                        model: info.model,
                        androidVersion: info.firmware,
                        appVersion: "1.0.0",
                        batteryLevel: Int(info.batteryPercent),
                        isCharging: false,
                        isConnected: true,
                        lastSeen: Date()
                    )
                    // Update the AppContainer's device — this triggers @Observable view refresh.
                    self.appContainer?.device = device
                }
            }
            // Notify feature controllers that a new BLE connection is established.
            NotificationCenter.default.post(name: .bleDidReconnect, object: nil)
        }
    }

    /// Disconnect from the current peripheral.
    func disconnect() {
        guard let p = gatt?.peripheral else { return }
        p.delegate = nil
        central.cancelPeripheralConnection(p)
        self.gatt = nil
        state = .disconnected(nil as Error?)
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            state = .disconnected(error)
            beginScanCycle()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
            gatt = nil
            healthManager?.clear()
            state = .disconnected(error)
            // Re-enter scan cycle after a brief rest.
            beginScanCycle()
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let g = self.gatt else { return }
                // Heartbeat payload: 8-byte timestamp placeholder (device clock).
                let payload = Data(count: 8)
                g.write(payload, to: WearLinkUUID.linkControl)
            }
        }
    }
}
