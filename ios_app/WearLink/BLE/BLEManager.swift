import Foundation
import CoreBluetooth
import UIKit
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

/// Bridge-model BLE manager. The iPhone acts as a GATT **server**
/// (`CBPeripheralManager`) instead of a GATT client. The watch scans, connects,
/// and subscribes; the iPhone publishes the WearLink service, answers reads,
/// ingests writes, and pushes notifications to subscribed centrals.
///
/// Battery: advertising is duty-cycled when no central is subscribed; the
/// foreground service on the watch keeps the link alive. See GATT.md.
@MainActor
@Observable
final class BLEManager: NSObject, CBPeripheralManagerDelegate {
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

    /// Connection state. Reused for view compatibility: `.scanning` now means
    /// "advertising" (publishing + waiting for a central), `.connected` means a
    /// central is subscribed to at least one characteristic.
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

    /// Feature controllers that receive inbound data from the watch (now
    /// delivered as GATT write requests). Set by AppContainer after init.
    weak var callController: CallController?
    weak var notificationForwarder: NotificationForwarder?
    weak var musicController: MusicController?
    weak var healthManager: HealthManager?
    /// Set by AppContainer so BLEManager can update the device model on incoming data.
    weak var appContainer: AppContainer?

    /// The GATT server. Created in init; publishes the WearLink service once
    /// Bluetooth is powered on.
    private let peripheral: CBPeripheralManager

    /// The published WearLink service and its mutable characteristics keyed by UUID.
    private var service: CBMutableService?
    private var characteristics: [CBUUID: CBMutableCharacteristic] = [:]

    /// Centrals currently subscribed per characteristic. Used to target
    /// `updateValue` notifications and to drive the `.connected` state.
    private var subscribedCentrals: [CBUUID: Set<CBCentral>] = [:]

    /// Monotonic seq for iPhone-originated framed packets (per-direction counter).
    private var outSeq: UInt16 = 0

    /// Per-characteristic chunk reassemblers for inbound writes (watch→phone).
    private var reassemblers: [CBUUID: Reassembler] = [:]

    /// Cached DeviceInfo returned on FE10 reads. Describes the iPhone.
    private var cachedDeviceInfo: DeviceInfo = DeviceInfo(
        model: UIDevice.current.model,
        firmware: UIDevice.current.systemVersion,
        batteryPercent: 0,
        preferredMtu: 247
    )

    private nonisolated(unsafe) var heartbeatTimer: Timer?
    private let heartbeatInterval: TimeInterval = 30.0
    /// Monotonic seq for iPhone-originated heartbeats; echoed by the watch in its ACK.
    private var heartbeatSeq: UInt32 = 0

    /// Last N action nonces per source to drop replays (CallAction, NotifAction,
    /// MusicCommand). Keyed by a coarse source tag; bounded to avoid unbounded growth.
    private var seenNonces: [NonceKey: Set<UInt32>] = [:]
    private let maxSeenNoncesPerKey = 32
    private struct NonceKey: Hashable {
        let uuid: CBUUID
        let callId: String
        let notifId: String
    }

    /// Backward-compatible façade so existing feature controllers that call
    /// `ble.gatt?.write(payload, to: uuid)` keep compiling. In the bridge model
    /// "writing" a characteristic means pushing a framed notification to any
    /// subscribed centrals. The `onPayload` dictionary is preserved so
    /// HealthManager.registerHandler stays valid; it is invoked for inbound
    /// writes on matching characteristics when present.
    private(set) var gatt: GattNotifier?

    override init() {
        // `options` let CoreBluetooth restore state across relaunches. We pass
        // the ShowPowerAlertKey=false to avoid the system alert when Bluetooth
        // is off on launch; the app's UI already communicates the state.
        self.peripheral = CBPeripheralManager(delegate: nil, queue: .main,
            options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
        super.init()
        peripheral.delegate = self
        // The notifier façade is always present so controllers can attach
        // handlers and call write() before any central connects (no-ops until a
        // subscriber is attached, mirroring the old gatt==nil guard behavior).
        self.gatt = GattNotifier(owner: self)
        // Register inbound handlers for the action characteristics that no
        // feature controller self-registers. CallController and
        // NotificationForwarder relied on BLEManager.didConnect() to install
        // their handlers in the central model; in bridge mode we install them
        // on the façade here (the weak controller refs are populated by
        // AppContainer immediately after this init returns, so by the time a
        // write arrives they are set). MusicController and HealthManager
        // self-register on .bleDidReconnect, so we do not register those here.
        registerInboundHandlers()
        log(.info, "BLEManager init — waiting for CBPeripheralManager state (Bridge mode: iPhone is GATT server)")
    }

    deinit {
        heartbeatTimer?.invalidate()
    }

    /// Install inbound handlers on the gatt façade for the action channels
    /// that feature controllers do not self-register. Each closure hops to the
    /// main actor because GattNotifier.onPayload is non-isolated and the
    /// feature controllers are @MainActor-isolated.
    private func registerInboundHandlers() {
        guard let g = gatt else { return }
        g.onPayload[WearLinkUUID.callAction] = { [weak self] data in
            Task { @MainActor in
                guard let self, let action = ProtoCodec.decodeCallAction(from: data) else { return }
                self.callController?.applyAction(action)
            }
        }
        g.onPayload[WearLinkUUID.notificationAction] = { [weak self] data in
            Task { @MainActor in
                guard let self, let action = ProtoCodec.decodeNotifAction(from: data) else { return }
                self.notificationForwarder?.handleAction(action)
            }
        }
    }

    // MARK: - Public API (back-compat with central-mode call sites)

    /// Begin advertising the WearLink service. Kept under the historical name
    /// `startScanning` so AppContainer.start() and BLELogView's "Rescan now"
    /// button keep working without view changes.
    func startScanning() {
        guard peripheral.state == .poweredOn else {
            log(.warning, "startScanning called but peripheral.state is not poweredOn (Bluetooth off or permission denied?)")
            return
        }
        if service == nil {
            buildAndPublishService()
        } else if !peripheral.isAdvertising {
            startAdvertising()
        }
    }

    /// Stop advertising and tear down the link. Kept under the historical name
    /// `disconnect` so AppContainer.disconnectDevice() keeps working.
    func disconnect() {
        peripheral.stopAdvertising()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        for uuid in characteristics.keys { reassemblers[uuid]?.clear() }
        subscribedCentrals.removeAll()
        healthManager?.clear()
        state = .disconnected(nil as Error?)
        log(.info, "Stopped advertising and cleared subscriptions")
    }

    // MARK: - Service / advertising

    /// Build the WearLink service with all 11 characteristics (FE10–FE60) and
    /// publish it on the peripheral manager.
    private func buildAndPublishService() {
        let svc = CBMutableService(type: WearLinkUUID.service, primary: true)

        // Property + permission mapping per GATT.md direction convention.
        // Read  = iPhone responds to reads from the watch.
        // Write = iPhone ingests writes from the watch.
        // Notify = iPhone pushes to subscribed centrals (watch subscribes).
        let deviceInfoChar = CBMutableCharacteristic(
            type: WearLinkUUID.deviceInfo,
            properties: [.read],
            value: nil,
            permissions: [.readable, .readEncryptionRequired])

        let healthStreamChar = CBMutableCharacteristic(
            type: WearLinkUUID.healthStream,
            properties: [.notify, .indicate],
            value: nil,
            permissions: [.readable, .readEncryptionRequired])

        let healthControlChar = CBMutableCharacteristic(
            type: WearLinkUUID.healthControl,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable, .writeEncryptionRequired])

        let callEventChar = CBMutableCharacteristic(
            type: WearLinkUUID.callEvent,
            properties: [.notify, .indicate],
            value: nil,
            permissions: [.readable, .readEncryptionRequired])

        let callActionChar = CBMutableCharacteristic(
            type: WearLinkUUID.callAction,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable, .writeEncryptionRequired])

        let notificationChar = CBMutableCharacteristic(
            type: WearLinkUUID.notification,
            properties: [.notify, .indicate],
            value: nil,
            permissions: [.readable, .readEncryptionRequired])

        let notificationActionChar = CBMutableCharacteristic(
            type: WearLinkUUID.notificationAction,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable, .writeEncryptionRequired])

        let musicNowPlayingChar = CBMutableCharacteristic(
            type: WearLinkUUID.musicNowPlaying,
            properties: [.notify, .indicate],
            value: nil,
            permissions: [.readable, .readEncryptionRequired])

        let musicCommandChar = CBMutableCharacteristic(
            type: WearLinkUUID.musicCommand,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable, .writeEncryptionRequired])

        let linkControlChar = CBMutableCharacteristic(
            type: WearLinkUUID.linkControl,
            properties: [.notify, .indicate, .write, .writeWithoutResponse],
            value: nil,
            permissions: [.readable, .writeable, .readEncryptionRequired, .writeEncryptionRequired])

        svc.characteristics = [
            deviceInfoChar, healthStreamChar, healthControlChar,
            callEventChar, callActionChar, notificationChar,
            notificationActionChar, musicNowPlayingChar, musicCommandChar,
            linkControlChar,
        ]
        // Use the local mutable references directly — svc.characteristics returns
        // [CBCharacteristic] which cannot be assigned to [CBUUID: CBMutableCharacteristic].
        let charList: [CBMutableCharacteristic] = [
            deviceInfoChar, healthStreamChar, healthControlChar,
            callEventChar, callActionChar, notificationChar,
            notificationActionChar, musicNowPlayingChar, musicCommandChar,
            linkControlChar,
        ]
        for c in charList {
            characteristics[c.uuid] = c
            reassemblers[c.uuid] = Reassembler()
        }
        self.service = svc
        peripheral.add(svc)
        log(.info, "Publishing WearLink service (\(WearLinkUUID.service.uuidString)) with \(characteristics.count) characteristics")
    }

    private func startAdvertising() {
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [WearLinkUUID.service],
            CBAdvertisementDataLocalNameKey: "WearLink",
        ])
        state = .scanning
        log(.info, "Advertising WearLink service as GATT server (waiting for watch to connect)")
    }

    // MARK: - CBPeripheralManagerDelegate

    nonisolated func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        Task { @MainActor in
            switch p.state {
            case .poweredOn:
                log(.info, "CBPeripheralManager poweredOn — publishing GATT service and advertising")
                log(.info, "Bonding enabled — encrypted characteristics will trigger Pair dialog on access")
                refreshDeviceInfo()
                startScanning()
            case .poweredOff:
                log(.warning, "CBPeripheralManager poweredOff — Bluetooth is OFF on the iPhone")
                state = .poweredOff
                invalidateAll()
            case .unauthorized:
                log(.error, "CBPeripheralManager unauthorized — Bluetooth permission NOT granted. Open Settings → WearLink → enable Bluetooth")
                state = .poweredOff
                invalidateAll()
            case .unsupported:
                log(.error, "CBPeripheralManager unsupported on this device")
                state = .poweredOff
                invalidateAll()
            case .resetting:
                log(.warning, "CBPeripheralManager resetting")
                state = .poweredOff
                invalidateAll()
            case .unknown:
                log(.info, "CBPeripheralManager state unknown")
            @unknown default:
                break
            }
        }
    }

    nonisolated func peripheralManager(_ p: CBPeripheralManager,
                                      didAdd service: CBService, error: Error?) {
        Task { @MainActor in
            if let error {
                log(.error, "Failed to add GATT service: \(error.localizedDescription)")
                return
            }
            log(.info, "GATT service added — starting advertising")
            startAdvertising()
        }
    }

    nonisolated func peripheralManagerDidStartAdvertising(_ p: CBPeripheralManager, error: Error?) {
        Task { @MainActor in
            if let error {
                log(.error, "Failed to start advertising: \(error.localizedDescription)")
                return
            }
            log(.info, "Advertising started — watch can now discover and connect")
        }
    }

    // MARK: - Subscribe / unsubscribe

    nonisolated func peripheralManager(_ p: CBPeripheralManager,
                                       central: CBCentral,
                                       didSubscribeTo characteristic: CBCharacteristic) {
        Task { @MainActor in
            subscribedCentrals[characteristic.uuid, default: []].insert(central)
            updateConnectionState()
            log(.info, "Central \(central.identifier) subscribed to \(characteristic.uuid.uuidString)")
            if characteristic.uuid == WearLinkUUID.linkControl {
                startHeartbeat()
            }
            NotificationCenter.default.post(name: .bleDidReconnect, object: nil)
        }
    }

    nonisolated func peripheralManager(_ p: CBPeripheralManager,
                                       central: CBCentral,
                                       didUnsubscribeFrom characteristic: CBCharacteristic) {
        Task { @MainActor in
            subscribedCentrals[characteristic.uuid]?.remove(central)
            if subscribedCentrals[characteristic.uuid]?.isEmpty == true {
                subscribedCentrals.removeValue(forKey: characteristic.uuid)
            }
            updateConnectionState()
            log(.info, "Central \(central.identifier) unsubscribed from \(characteristic.uuid.uuidString)")
        }
    }

    private func updateConnectionState() {
        let any = subscribedCentrals.values.contains { !$0.isEmpty }
        if any {
            if state != .connected {
                state = .connected
            }
        } else {
            // No subscribers: back to advertising/waiting.
            if state == .connected {
                state = .scanning
                heartbeatTimer?.invalidate()
                heartbeatTimer = nil
            }
        }
    }

    // MARK: - Read requests

    nonisolated func peripheralManager(_ p: CBPeripheralManager,
                                       didReceiveRead request: CBATTRequest) {
        Task { @MainActor in
            let uuid = request.characteristic.uuid
            switch uuid {
            case WearLinkUUID.deviceInfo:
                // Characteristic has .encryption permission — if the central is
                // not yet bonded CoreBluetooth rejects the read automatically and
                // triggers the iOS Pair dialog before this delegate is called.
                log(.info, "Read on encrypted characteristic \(uuid.uuidString) — encryption required, Pair dialog triggers if not bonded")
                let bytes = ProtoCodec.encodeDeviceInfo(cachedDeviceInfo)
                // Truncate to the central's MTU if smaller than the payload.
                let mtu = request.central.maximumUpdateValueLength
                let data: Data
                if bytes.count > mtu {
                    data = bytes.prefix(mtu)
                } else {
                    data = bytes
                }
                // CBPeripheralManager reads are answered by setting request.value
                // then calling respond; value must be set BEFORE respond.
                request.value = data
                p.respond(to: request, withResult: .success)
            default:
                log(.warning, "Read on unsupported characteristic \(uuid.uuidString)")
                p.respond(to: request, withResult: .readNotPermitted)
            }
        }
    }

    // MARK: - Write requests

    nonisolated func peripheralManager(_ p: CBPeripheralManager,
                                       didReceiveWrite request: CBATTRequest) {
        Task { @MainActor in
                let uuid = request.characteristic.uuid
                // Characteristic has .encryption permission — CoreBluetooth
                // rejects writes from unencrypted centrals automatically and
                // triggers the Pair dialog before this delegate is called.
                log(.info, "Write on encrypted characteristic \(uuid.uuidString) — encryption required, Pair dialog triggers if not bonded")
                guard let value = request.value else {
                    p.respond(to: request, withResult: .invalidAttributeValueLength)
                    return
                }
                // Decode the framed packet; LinkControl frames are dispatched
                // directly, all others go through the per-UUID reassembler.
                guard let frame = PacketCodec.decode(value) else {
                    log(.warning, "Bad frame on \(uuid.uuidString) (CRC/len mismatch) — dropping")
                    p.respond(to: request, withResult: .invalidAttributeValueLength)
                    return
                }
                if uuid == WearLinkUUID.linkControl {
                    handleLinkControl(frame.payload)
                    p.respond(to: request, withResult: .success)
                    return
                }
                let reassembler = reassemblers[uuid] ?? Reassembler()
                reassemblers[uuid] = reassembler
                if let full = reassembler.add(frame) {
                    dispatchInbound(uuid: uuid, payload: full)
                }
                p.respond(to: request, withResult: .success)
        }
    }

    // MARK: - Inbound dispatch

    private func dispatchInbound(uuid: CBUUID, payload: Data) {
        // FE21 HealthControl is handled here (no feature controller self-
        // registers for it); everything else is fed to the gatt façade's
        // per-UUID onPayload handlers (set by BLEManager for callAction /
        // notificationAction, and self-registered by MusicController and
        // HealthManager for musicCommand / healthStream). The façade is the
        // single dispatch path for those, avoiding double delivery.
        switch uuid {
        case WearLinkUUID.healthControl:
            guard let cmd = ProtoCodec.decodeHealthControl(from: payload) else { return }
            applyHealthControl(cmd)
            return
        case WearLinkUUID.callAction:
            // Replay-check before delivery. Decode is cheap; the façade handler
            // decodes again to apply the action.
            if let a = ProtoCodec.decodeCallAction(from: payload),
               isReplay(uuid: uuid, nonce: a.nonce, callId: a.callId, notifId: "") { return }
            gatt?.onPayload[uuid]?(payload)
            sendLinkControlAck(seq: 0)
        case WearLinkUUID.notificationAction:
            if let a = ProtoCodec.decodeNotifAction(from: payload),
               isReplay(uuid: uuid, nonce: a.nonce, callId: "", notifId: a.notifId) { return }
            gatt?.onPayload[uuid]?(payload)
            sendLinkControlAck(seq: 0)
        case WearLinkUUID.musicCommand:
            if let c = ProtoCodec.decodeMusicCommand(from: payload),
               isReplay(uuid: uuid, nonce: c.nonce, callId: "", notifId: "") { return }
            gatt?.onPayload[uuid]?(payload)
            sendLinkControlAck(seq: 0)
        default:
            gatt?.onPayload[uuid]?(payload)
        }
    }

    private func applyHealthControl(_ cmd: HealthControl) {
        // The watch now drives health capture config. Forward to HealthManager
        // for future use; for now just log — the iPhone is the data sink.
        switch cmd.command {
        case .sendNow:
            log(.info, "HealthControl: SEND_NOW received from watch")
        case .setIntervalMs:
            log(.info, "HealthControl: SET_INTERVAL_MS=\(cmd.intervalMs) received from watch")
        case .setTypes:
            let names = cmd.types.map { String(describing: $0) }.joined(separator: ",")
            log(.info, "HealthControl: SET_TYPES=[\(names)] received from watch")
        case .startActive:
            log(.info, "HealthControl: START_ACTIVE received from watch")
        case .stopActive:
            log(.info, "HealthControl: STOP_ACTIVE received from watch")
        case .cmdUnspecified:
            break
        }
    }

    // MARK: - LinkControl (heartbeat / ack)

    private func handleLinkControl(_ payload: Data) {
        guard let lc = ProtoCodec.decodeLinkControl(from: payload) else { return }
        switch lc.kind {
        case .heartbeat:
            // Echo an ACK carrying the heartbeat's seq.
            let ack = LinkControl(kind: .ack, seq: lc.seq,
                timestampMs: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: Data())
            sendNotification(WearLinkUUID.linkControl, payload: ProtoCodec.encodeLinkControl(ack))
        case .ack, .nack, .kindUnspecified, .reconnectToken:
            // Inbound ACK/NACK for our heartbeats — liveness proof only.
            break
        }
    }

    private func sendLinkControlAck(seq: UInt32) {
        let ack = LinkControl(kind: .ack, seq: seq,
            timestampMs: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data())
        sendNotification(WearLinkUUID.linkControl, payload: ProtoCodec.encodeLinkControl(ack))
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.heartbeatSeq &+= 1
                let lc = LinkControl(
                    kind: .heartbeat,
                    seq: self.heartbeatSeq,
                    timestampMs: UInt64(Date().timeIntervalSince1970 * 1000),
                    payload: Data()
                )
                self.sendNotification(WearLinkUUID.linkControl, payload: ProtoCodec.encodeLinkControl(lc))
            }
        }
    }

    // MARK: - Replay protection

    private func isReplay(uuid: CBUUID, nonce: UInt32, callId: String, notifId: String) -> Bool {
        guard nonce != 0 else { return false } // 0 = no replay protection.
        let key = NonceKey(uuid: uuid, callId: callId, notifId: notifId)
        var set = seenNonces[key] ?? []
        if set.contains(nonce) { return true }
        set.insert(nonce)
        if set.count > maxSeenNoncesPerKey { set.removeFirst() }
        seenNonces[key] = set
        return false
    }

    // MARK: - Outbound notifications

    /// Push a framed notification to all centrals subscribed to `uuid`. The
    /// payload is a protobuf message body; it is wrapped by `PacketCodec.encode`
    /// and split into MTU-sized chunks (continuation flag set on all but last),
    /// mirroring the old GattClient.write chunking so the watch's Reassembler
    /// can reconstruct the full payload.
    func sendNotification(_ uuid: CBUUID, payload: Data) {
        guard let char = characteristics[uuid] else { return }
        let centrals = Array(subscribedCentrals[uuid] ?? [])
        guard !centrals.isEmpty else { return }

        let overhead = PacketCodec.headerSize + PacketCodec.crcSize
        // For notify characteristics the per-write MTU is bounded by the
        // subscribed centrals' maximum update value length. Use a conservative
        // 247 B default (GATT.md) and let CoreBluetooth fragment below it.
        let defaultMtu = 247
        let maxChunk = max(defaultMtu - overhead, 1)

        let seq = outSeq
        outSeq = (outSeq &+ 1) & 0xFFFF
        var offset = 0
        while offset < payload.count {
            let end = min(offset + maxChunk, payload.count)
            let chunk = payload.subdata(in: offset..<end)
            let cont = end < payload.count
            let frame = PacketCodec.encode(seq: seq, continuation: cont, payload: chunk)
            let ok = peripheral.updateValue(frame, for: char, onSubscribedCentrals: centrals)
            if !ok {
                log(.warning, "Notification queue full on \(uuid.uuidString) — chunk dropped (watch will miss data)")
                // Back off: let the queue drain before retrying remaining chunks.
                break
            }
            offset = end
        }
    }

    // MARK: - Teardown helpers

    private func invalidateAll() {
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        peripheral.stopAdvertising()
        for uuid in characteristics.keys { reassemblers[uuid]?.clear() }
        subscribedCentrals.removeAll()
        healthManager?.clear()
        state = .poweredOff
    }

    /// Refresh cached DeviceInfo from the host iPhone (battery + OS version).
    private func refreshDeviceInfo() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        var battery: UInt32 = 0
        switch UIDevice.current.batteryState {
        case .unknown, .unplugged:
            battery = UInt32(max(0, min(100, Int(UIDevice.current.batteryLevel * 100))))
        default:
            battery = UInt32(max(0, min(100, Int(UIDevice.current.batteryLevel * 100))))
        }
        cachedDeviceInfo = DeviceInfo(
            model: UIDevice.current.model,
            firmware: UIDevice.current.systemVersion,
            batteryPercent: battery,
            preferredMtu: 247
        )
    }
}

// MARK: - GattNotifier façade

/// Thin façade preserving the `ble.gatt?.write(_:to:)` and `onPayload` surface
/// that feature controllers depend on. In bridge mode `write` pushes a framed
/// notification to subscribed centrals; `onPayload` is fed by inbound writes.
final class GattNotifier {
    private weak var owner: BLEManager?
    /// Inbound payload handlers, keyed by characteristic UUID. Set by feature
    /// controllers (e.g. HealthManager.registerHandler); invoked by BLEManager
    /// when a full framed payload arrives on the matching characteristic.
    var onPayload: [CBUUID: (Data) -> Void] = [:]

    init(owner: BLEManager) { self.owner = owner }

    /// Frame `payload` and notify all centrals subscribed to `uuid`. In bridge
    /// mode this is how the iPhone pushes data to the watch.
    @MainActor
    func write(_ payload: Data, to uuid: CBUUID, type: CBCharacteristicWriteType = .withResponse) {
        owner?.sendNotification(uuid, payload: payload)
    }
}