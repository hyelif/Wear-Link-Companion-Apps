import Foundation
import CoreBluetooth

/// Wraps the connected peripheral: service/characteristic discovery,
/// subscriptions (notify), framed writes + chunk reassembly, and inbound
/// payload dispatch to per-characteristic handlers.
/// Not @MainActor — CBPeripheralDelegate callbacks arrive on CBCentralManager's
/// queue (set to .main in BLEManager), so all delegate methods are safe on main.
final class GattClient: NSObject, CBPeripheralDelegate {
    let peripheral: CBPeripheral
    private var chars: [CBUUID: CBCharacteristic] = [:]
    private var reassemblers: [CBUUID: Reassembler] = [:]
    private var outSeq: UInt16 = 0

    /// Per-uuid inbound payload handlers (set by feature code in later phases).
    var onPayload: [CBUUID: (Data) -> Void] = [:]
    var onLinkControl: ((PacketCodec.Frame) -> Void)?
    /// Fires once after characteristics are discovered, subscribed, and FE10 read,
    /// so feature code can issue commands that require the chars to be present
    /// (e.g. the FE21 HealthControl config the phone sends on connect).
    var onDiscovered: (() -> Void)?

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
        peripheral.delegate = self
    }

    func discoverServices() {
        peripheral.discoverServices([WearLinkUUID.service])
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("[GattClient] didDiscoverServices error: \(error.localizedDescription)")
        }
        guard let s = p.services?.first(where: { $0.uuid == WearLinkUUID.service }) else { return }
        p.discoverCharacteristics(nil, for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("[GattClient] didDiscoverCharacteristicsFor error: \(error.localizedDescription)")
        }
        for c in service.characteristics ?? [] { chars[c.uuid] = c }
        // Subscribe to all notify characteristics (watch→iOS and bidirectional).
        for uuid in [WearLinkUUID.healthStream,
                    WearLinkUUID.callEvent,
                    WearLinkUUID.musicNowPlaying,
                    WearLinkUUID.linkControl,
                    WearLinkUUID.callAction,
                    WearLinkUUID.notificationAction,
                    WearLinkUUID.musicCommand] {
            if let c = chars[uuid], c.properties.contains(CBCharacteristicProperties.notify) {
                p.setNotifyValue(true, for: c)
            }
        }
        // Read FE10 DeviceInfo once on discovery. The watch responds with a framed
        // DeviceInfo protobuf; the response arrives in didUpdateValueFor, is decoded
        // by PacketCodec, and is dispatched to onPayload[deviceInfo] (BLEManager
        // decodes it into WearableDevice and updates AppContainer). FE10 is a read
        // characteristic (no CCCD), so it is intentionally NOT in the subscribe list.
        if let di = chars[WearLinkUUID.deviceInfo] {
            p.readValue(for: di)
        }
        // Feature code (BLEManager) sends watch config (HealthControl) now that
        // the characteristics are present and subscribed.
        onDiscovered?()
    }

    /// Write a framed packet. Splits into MTU-sized chunks; sets continuation flag.
    func write(_ payload: Data, to uuid: CBUUID, type: CBCharacteristicWriteType = .withResponse) {
        guard let c = chars[uuid] else { return }
        guard peripheral.state == .connected else { return }
        // Verify the characteristic supports the requested write type.
        switch type {
        case .withResponse:
            guard c.properties.contains(.write) else { return }
        case .withoutResponse:
            guard c.properties.contains(.writeWithoutResponse) else { return }
        @unknown default:
            return
        }
        let overhead = PacketCodec.headerSize + PacketCodec.crcSize
        let maxChunk = max(Int(peripheral.maximumWriteValueLength(for: type)) - overhead, 1)
        let seq = outSeq
        outSeq = (outSeq &+ 1) & 0xFFFF
        var offset = 0
        while offset < payload.count {
            let end = min(offset + maxChunk, payload.count)
            let chunk = payload.subdata(in: offset..<end)
            let cont = end < payload.count
            let frame = PacketCodec.encode(seq: seq, continuation: cont, payload: chunk)
            peripheral.writeValue(frame, for: c, type: type)
            offset = end
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if let error = error {
            print("[GattClient] didUpdateValueFor error: \(error.localizedDescription)")
        }
        guard let raw = c.value, let frame = PacketCodec.decode(raw) else { return }
        // LinkControl frames are handled immediately (no chunking expected).
        if c.uuid == WearLinkUUID.linkControl {
            onLinkControl?(frame)
            return
        }
        let r = reassemblers[c.uuid] ?? {
            let r = Reassembler()
            reassemblers[c.uuid] = r
            return r
        }()
        if let full = r.add(frame) {
            onPayload[c.uuid]?(full)
        }
    }
}
