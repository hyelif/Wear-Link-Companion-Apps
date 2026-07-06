import Foundation

/// Framed packet codec. Mirrors `protocol/codec.md`.
///
/// Layout: [seq:u16][flags:u8][len:u16][payload[]][crc8]
/// - seq: monotonic per-direction counter, used for ack/dedup.
/// - flags: bit0 = continuation (more chunks follow for same seq).
/// - len:  payload byte count (NOT including header/crc).
/// - crc8: over header + payload.
///
/// Chunks > MTU are split by the caller; reassembly tracks seq + continuation.
enum PacketCodec {
    static let headerSize = 5
    static let crcSize = 1

    struct Frame {
        let seq: UInt16
        let flags: UInt8
        let payload: Data
        var isContinuation: Bool { (flags & 0x01) != 0 }
    }

    static func encode(seq: UInt16, continuation: Bool, payload: Data) -> Data {
        var out = Data(capacity: headerSize + payload.count + crcSize)
        out.append(contentsOf: withUnsafeBytes(of: seq.bigEndian) { Array($0) })
        let flags: UInt8 = continuation ? 0x01 : 0x00
        out.append(flags)
        let len = UInt16(payload.count)
        out.append(contentsOf: withUnsafeBytes(of: len.bigEndian) { Array($0) })
        out.append(payload)
        out.append(crc8(of: out))
        return out
    }

    static func decode(_ raw: Data) -> Frame? {
        guard raw.count >= headerSize + crcSize else { return nil }
        let seq = raw.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        let flags = raw[2]
        let len = raw.subdata(in: 3..<5).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        guard raw.count == headerSize + Int(len) + crcSize else { return nil }
        let payload = raw.subdata(in: headerSize..<(headerSize + Int(len)))
        let got = raw[headerSize + Int(len)]
        let want = crc8(of: raw.prefix(headerSize + Int(len)))
        guard got == want else { return nil }
        return Frame(seq: seq, flags: flags, payload: payload)
    }

    /// CRC-8 / SMBUS-style (poly 0x07, init 0x00, no reflection, no final xor).
    /// "123456789" => 0xF4. Must match Dart PacketCodec.crc8.
    static func crc8(of data: Data) -> UInt8 {
        var crc: UInt8 = 0
        for byte in data {
            crc ^= byte
            for _ in 0..<8 {
                crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x07) : (crc << 1)
            }
        }
        return crc
    }
}

/// Reassembles chunked payloads keyed by seq. Mirrors Dart Reassembler.
final class Reassembler {
    private var buf: [UInt16: [Data]] = [:]

    /// Feed a frame. Returns the full payload when the final (non-continuation)
    /// chunk for its seq arrives, otherwise nil.
    func add(_ frame: PacketCodec.Frame) -> Data? {
        if frame.isContinuation {
            buf[frame.seq, default: []].append(frame.payload)
            return nil
        }
        guard let chunks = buf.removeValue(forKey: frame.seq), !chunks.isEmpty else {
            return frame.payload
        }
        var out = Data()
        for c in chunks { out.append(c) }
        out.append(frame.payload)
        return out
    }

    func clear() { buf.removeAll() }
}