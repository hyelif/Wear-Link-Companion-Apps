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

    private let central: CBCentralManager
    private var scanTimer: Timer?
    private var restTimer: Timer?
    private var heartbeatTimer: Timer?
    private let scanOn: TimeInterval = 2.0
    private let scanOff: TimeInterval = 8.0
    private let heartbeatInterval: TimeInterval = 30.0

    override init() {
        // `options` let CoreBluetooth restore state across relaunches.
        self.central = CBCentralManager(delegate: nil, queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false])
        super.init()
        central.delegate = self
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
            self.restTimer = Timer.scheduledTimer(withTimeInterval: self.scanOff, repeats: false) { [weak self] _ in
                self?.beginScanCycle()
            }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { return }
        Task { @MainActor in
            self.startScanning()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            central.stopScan()
            self.scanTimer?.invalidate(); self.restTimer?.invalidate()
            self.state = .connecting
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            let client = GattClient(peripheral: peripheral)
            peripheral.delegate = client   // GattClient receives discovery + value callbacks
            // Echo inbound LinkControl frames back as acks (heartbeat echo).
            client.onLinkControl = { [weak self] frame in
                // Echo the same seq back as ACK — watch confirms liveness.
                self?.gatt?.write(frame.payload, to: WearLinkUUID.linkControl)
            }
            // Register inbound payload handlers for feature characteristics
            // that the watch writes to (callAction, notificationAction, musicCommand).
            client.onPayload[WearLinkUUID.callAction] = { [weak self] data in
                guard let self, let action = ProtoCodec.decodeCallAction(from: data) else { return }
                Task { @MainActor in
                    self.callController?.applyAction(action)
                }
            }
            client.onPayload[WearLinkUUID.notificationAction] = { [weak self] data in
                guard let self, let action = ProtoCodec.decodeNotifAction(from: data) else { return }
                Task { @MainActor in
                    self.notificationForwarder?.handleAction(action)
                }
            }
            client.onPayload[WearLinkUUID.musicCommand] = { [weak self] data in
                guard let self, let command = ProtoCodec.decodeMusicCommand(from: data) else { return }
                Task { @MainActor in
                    self.musicController?.dispatchCommand(command)
                }
            }
            self.gatt = client
            self.state = .connected
            client.discoverServices()
            self.startHeartbeat()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.heartbeatTimer?.invalidate()
            self.heartbeatTimer = nil
            self.gatt = nil
            self.state = .disconnected(error)
            // Re-enter scan cycle after a brief rest.
            self.beginScanCycle()
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            guard let self, let g = self.gatt else { return }
            // Heartbeat payload: 8-byte timestamp placeholder (device clock).
            var payload = Data(count: 8)
            g.write(payload, to: WearLinkUUID.linkControl)
        }
    }
}

extension BLEManager: CBPeripheralDelegate {}
