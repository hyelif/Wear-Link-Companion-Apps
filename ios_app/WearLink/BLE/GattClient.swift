import Foundation
import CoreBluetooth

/// Wraps the connected peripheral: service/characteristic discovery,
/// subscriptions (notify), framed writes + chunk reassembly, and inbound
/// payload dispatch to per-characteristic handlers.
final class GattClient: NSObject, CBPeripheralDelegate {
    let peripheral: CBPeripheral
    private var chars: [CBUUID: CBCharacteristic] = [:]
    private let reassembler = Reassembler()
    private var outSeq: UInt16 = 0

    /// Per-uuid inbound payload handlers (set by feature code in later phases).
    var onPayload: [CBUUID: (Data) -> Void] = [:]
    var onLinkControl: ((PacketCodec.Frame) -> Void)?

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
    }

    func discoverServices() {
        peripheral.discoverServices([WearLinkUUID.service])
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == WearLinkUUID.service }) else { return }
        p.discoverCharacteristics(nil, for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] { chars[c.uuid] = c }
        // Subscribe to all notify characteristics.
        for uuid in [WearLinkUUID.healthStream,
                    WearLinkUUID.callEvent,
                    WearLinkUUID.musicNowPlaying,
                    WearLinkUUID.linkControl] {
            if let c = chars[uuid], c.properties.contains(CBCharacteristicProperties.notify) {
                p.setNotifyValue(true, for: c)
            }
        }
    }

    /// Write a framed packet. Splits into MTU-sized chunks; sets continuation flag.
    func write(_ payload: Data, to uuid: CBUUID, type: CBCharacteristicWriteType = .withResponse) {
        guard let c = chars[uuid] else { return }
        let overhead = UInt16(PacketCodec.headerSize + PacketCodec.crcSize)
        let maxChunk = max(Int(peripheral.maximumWriteValueLength(for: type)) - Int(overhead), 1)
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
        guard let raw = c.value, let frame = PacketCodec.decode(raw) else { return }
        // LinkControl frames are handled immediately (no chunking expected).
        if c.uuid == WearLinkUUID.linkControl {
            onLinkControl?(frame)
            return
        }
        if let full = reassembler.add(frame) {
            onPayload[c.uuid]?(full)
        }
    }
}