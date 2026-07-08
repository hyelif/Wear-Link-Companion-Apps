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
                Task { @MainActor in
                    self?.beginScanCycle()
                }
            }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        Task { @MainActor in
            if c.state == .poweredOn {
                startScanning()
            } else {
                state = .poweredOff
                scanTimer?.invalidate()
                restTimer?.invalidate()
                heartbeatTimer?.invalidate()
                scanTimer = nil
                restTimer = nil
                heartbeatTimer = nil
                gatt = nil
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            central.stopScan()
            scanTimer?.invalidate(); restTimer?.invalidate()
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
                var payload = Data(count: 8)
                g.write(payload, to: WearLinkUUID.linkControl)
            }
        }
    }
}
