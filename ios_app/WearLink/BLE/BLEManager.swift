import Foundation
import CoreBluetooth
import os

/// In-app BLE log entry (mirrored to os_log + shown in BLELogView so the
/// connection can be diagnosed without a Mac/Console.app).
struct BLELogEntry: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let level: BLELogLevel
    let text: String
}

enum BLELogLevel: String, Hashable {
    case info, warning, error
}

/// Central-side BLE manager. Scans for the WearLink watch, connects, bonds,
/// and exposes the discovered `GattClient`.
///
/// Battery: duty-cycled scan (2 s on / 8 s off) when disconnected;
/// stops scanning immediately on connect. See Software-Structure §4/§6.
@MainActor
@Observable
final class BLEManager: NSObject, CBCentralManagerDelegate {
    /// os_log logger so connection milestones are visible in Console.app /
    /// `log` CLI even for SideStore-installed builds (where `print()` output is
    /// not attached to a debugger). Filter Console by subsystem "com.wearlink".
    private let logger = Logger(subsystem: "com.wearlink", category: "BLE")

    /// In-app log buffer shown by BLELogView (no Mac needed). Capped to 300
    /// entries to bound memory; oldest dropped when full.
    private(set) var logEntries: [BLELogEntry] = []
    private let maxLogEntries = 300

    /// Append a milestone to both os_log and the in-app buffer.
    func log(_ level: BLELogLevel = .info, _ text: String) {
        let entry = BLELogEntry(date: Date(), level: level, text: text)
        logEntries.append(entry)
        if logEntries.count > maxLogEntries {
            logEntries.removeFirst(logEntries.count - maxLogEntries)
        }
        switch level {
        case .info:  logger.info("\(text, privacy: .public)")
        case .warning: logger.warning("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        }
    }

    func clearLogs() { logEntries.removeAll() }

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
    nonisolated(unsafe) private var scanTimer: Timer?
    nonisolated(unsafe) private var restTimer: Timer?
    nonisolated(unsafe) private var heartbeatTimer: Timer?
    private let scanOn: TimeInterval = 2.0
    private let scanOff: TimeInterval = 8.0
    private let scanOffMax: TimeInterval = 120.0
    private var scanFailureCount: Int = 0
    private let heartbeatInterval: TimeInterval = 30.0
    /// Monotonic seq for iOS-originated heartbeats; echoed by the watch in its ACK.
    private var heartbeatSeq: UInt32 = 0

    /// UUID of the watch we last connected to. Persisted so that after the user
    /// pairs the devices in native Bluetooth Settings, opening the app can reconnect
    /// directly via retrievePeripherals(withIdentifiers:) without a noisy scan.
    private let knownPeripheralUUIDKey = "com.wearlink.knownPeripheralUUID"
    private var knownPeripheralUUID: UUID? {
        get {
            guard let uuidString = UserDefaults.standard.string(forKey: knownPeripheralUUIDKey) else { return nil }
            return UUID(uuidString: uuidString)
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey: knownPeripheralUUIDKey)
        }
    }

    override init() {
        // `options` let CoreBluetooth restore state across relaunches.
        self.central = CBCentralManager(delegate: nil, queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false])
        super.init()
        central.delegate = self
        log(.info, "BLEManager init — waiting for CBCentralManager state (Bluetooth permission prompt may appear)")
    }

    deinit {
        scanTimer?.invalidate()
        restTimer?.invalidate()
        heartbeatTimer?.invalidate()
    }

    func startScanning() {
        guard central.state == .poweredOn else {
            log(.warning, "startScanning called but central.state=\(cbStateName(central.state)) — not poweredOn (Bluetooth off or permission denied?)")
            return
        }
        // Native Bluetooth Settings pairing is the foundation: first try to use a
        // peripheral that iOS already knows (system-connected via Settings, or
        // previously connected and persisted). Only scan if nothing is retrievable.
        if connectKnownPeripherals() { return }
        beginScanCycle()
    }

    /// Attempt to connect without scanning. Returns true if a known/connected
    /// peripheral was found and a connection attempt is in progress.
    private func connectKnownPeripherals() -> Bool {
        // 1. Peripherals currently connected to the system via native Settings or other apps.
        let connected = central.retrieveConnectedPeripherals(withServices: [WearLinkUUID.service])
        if let p = connected.first {
            log(.info, "Native Settings path: found already-connected watch \(p.identifier) — connecting directly")
            connectToPeripheral(p)
            return true
        }

        // 2. Previously connected watch that iOS remembers from a prior session.
        if let uuid = knownPeripheralUUID {
            let known = central.retrievePeripherals(withIdentifiers: [uuid])
            if let p = known.first {
                log(.info, "Native Settings path: found previously-connected watch \(p.identifier) — connecting directly")
                connectToPeripheral(p)
                return true
            }
            log(.info, "Known watch UUID \(uuid) is not retrievable; will scan instead")
        }
        return false
    }

    private func connectToPeripheral(_ peripheral: CBPeripheral) {
        central.stopScan()
        invalidateScanTimers()
        scanFailureCount = 0
        state = .connecting
        central.connect(peripheral, options: nil)
    }

    private func invalidateScanTimers() {
        scanTimer?.invalidate(); scanTimer = nil
        restTimer?.invalidate(); restTimer = nil
    }

    private func beginScanCycle() {
        scanTimer?.invalidate()
        restTimer?.invalidate()
        central.scanForPeripherals(withServices: [WearLinkUUID.service],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        state = .scanning
        log(.info, "Scan: scanning for watch (service \(WearLinkUUID.service.uuidString), 2s on)…")
        scanTimer = Timer.scheduledTimer(withTimeInterval: scanOn, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.central.stopScan()
                // Exponential backoff: if no device found, progressively increase rest
                // period up to scanOffMax (2 min) to save battery.
                let rest = min(self.scanOff * pow(2.0, Double(self.scanFailureCount)), self.scanOffMax)
                self.scanFailureCount += 1
                self.log(.info, "Scan: no watch found — resting \(String(format: "%.1f", rest))s before retry (attempt \(self.scanFailureCount))")
                self.restTimer = Timer.scheduledTimer(withTimeInterval: rest, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        self?.beginScanCycle()
                    }
                }
            }
        }
    }

    private func cbStateName(_ s: CBManagerState) -> String {
        switch s {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        @unknown default: return "other"
        }
    }

    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        Task { @MainActor in
            switch c.state {
            case .poweredOn:
                log(.info, "CBCentralManager poweredOn — try native Settings connection first, then scan")
                startScanning()
            case .poweredOff:
                log(.warning, "CBCentralManager poweredOff — Bluetooth is OFF on the iPhone")
                state = .poweredOff
                invalidateAll()
            case .unauthorized:
                log(.error, "CBCentralManager unauthorized — Bluetooth permission NOT granted. Open Settings → WearLink → enable Bluetooth")
                state = .poweredOff
                invalidateAll()
            case .unsupported:
                log(.error, "CBCentralManager unsupported on this device")
                state = .poweredOff
                invalidateAll()
            case .resetting:
                log(.warning, "CBCentralManager resetting")
                state = .poweredOff
                invalidateAll()
            case .unknown:
                log(.info, "CBCentralManager state unknown")
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
            log(.info, "Discovered WearLink watch (RSSI=\(RSSI.intValue)) — connecting")
            connectToPeripheral(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            // Remember this watch so future launches can reconnect directly via
            // native Settings / retrievePeripherals without a noisy scan.
            knownPeripheralUUID = peripheral.identifier
            log(.info, "Connected to watch \(peripheral.identifier) — discovering GATT services")
            let client = GattClient(peripheral: peripheral)
            // Feed GattClient discovery/error logs into the in-app buffer.
            client.onLog = { [weak self] text in
                self?.log(.info, text)
            }
            // LinkControl (FE60) keepalive handshake. The watch may originate
            // heartbeats; we ACK those with a matching seq. We also originate
            // heartbeats (startHeartbeat); inbound ACKs/NACKs for those are proof of
            // liveness and are NOT re-ACKed (prevents an ack-pingpong loop). FE60 is
            // not chunked, so frame.payload is the full LinkControl protobuf.
            client.onLinkControl = { [weak self] frame in
                Task { @MainActor in
                    guard let self else { return }
                    guard let lc = ProtoCodec.decodeLinkControl(from: frame.payload) else { return }
                    switch lc.kind {
                    case .heartbeat:
                        let ack = LinkControl(kind: .ack, seq: lc.seq,
                            timestampMs: UInt64(Date().timeIntervalSince1970 * 1000),
                            payload: Data())
                        self.gatt?.write(ProtoCodec.encodeLinkControl(ack),
                                         to: WearLinkUUID.linkControl)
                    case .ack, .nack, .kindUnspecified, .reconnectToken:
                        break
                    }
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
            log(.info, "GATT connected — state=.connected, discovering services")
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
                    self.log(.info, "DeviceInfo received: model=\(info.model) fw=\(info.firmware) battery=\(info.batteryPercent)%")
                }
            }
            // Notify feature controllers that a new BLE connection is established.
            NotificationCenter.default.post(name: .bleDidReconnect, object: nil)
            // Once characteristics are discovered, configure the watch's health
            // capture (FE21 HealthControl): push interval + the types we want.
            client.onDiscovered = { [weak self] in
                Task { @MainActor in
                    self?.sendHealthControlConfig()
                }
            }
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
            log(.error, "Failed to connect to watch: \(error?.localizedDescription ?? "unknown")")
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
            log(.warning, "Disconnected from watch: \(error?.localizedDescription ?? "clean") — resuming scan")
            // Re-enter scan cycle after a brief rest.
            beginScanCycle()
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let g = self.gatt else { return }
                // Heartbeat = a real LinkControl{HEARTBEAT} protobuf (not 8 zero bytes),
                // framed by GattClient.write. The watch decodes it and returns an ACK
                // with the matching seq, which arrives via onLinkControl above.
                self.heartbeatSeq &+= 1
                let lc = LinkControl(
                    kind: .heartbeat,
                    seq: self.heartbeatSeq,
                    timestampMs: UInt64(Date().timeIntervalSince1970 * 1000),
                    payload: Data()
                )
                g.write(ProtoCodec.encodeLinkControl(lc), to: WearLinkUUID.linkControl)
            }
        }
    }

    /// Configure the watch's health broadcast via FE21 HealthControl: set the push
    /// interval (ms) and the sample types we want forwarded. Sent after GATT
    /// discovery completes (onDiscovered) so the FE21 characteristic is present.
    private func sendHealthControlConfig() {
        guard let g = gatt else { return }
        log(.info, "GATT discovered — sending health config (FE21: interval=60s, types=HR+steps+cal+dist+sleep)")
        let setInterval = HealthControl(command: .setIntervalMs, intervalMs: 60_000, types: [])
        g.write(ProtoCodec.encodeHealthControl(setInterval), to: WearLinkUUID.healthControl)
        let setTypes = HealthControl(command: .setTypes, intervalMs: 0,
            types: [.heartRateBpm, .steps, .calories, .distanceMeters, .sleep])
        g.write(ProtoCodec.encodeHealthControl(setTypes), to: WearLinkUUID.healthControl)
    }
}