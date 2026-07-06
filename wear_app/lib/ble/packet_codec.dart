// Mirrors ios_app/WearLink/BLE/PacketCodec.swift and protocol/codec.md.
// Any change here MUST be mirrored on iOS. Drift = bug.
import 'dart:typed_data';

/// Frame layout: [seq:u16 BE][flags:u8][len:u16 BE][payload[len]][crc8]
///   flags bit0 = continuation (more chunks for same seq)
///   crc8 = CRC-8/Maxim (poly 0x07) over bytes [0 .. header+len-1]
class PacketCodec {
  static const int headerSize = 5;
  static const int crcSize = 1;
  static const int flagContinuation = 0x01;

  static Uint8List encode({
    required int seq,
    required bool continuation,
    required Uint8List payload,
  }) {
    final out = Uint8List(headerSize + payload.length + crcSize);
    int w = 0;
    out[w++] = (seq >> 8) & 0xFF;
    out[w++] = seq & 0xFF;
    out[w++] = continuation ? flagContinuation : 0x00;
    final len = payload.length;
    out[w++] = (len >> 8) & 0xFF;
    out[w++] = len & 0xFF;
    out.setRange(w, w + len, payload);
    w += len;
    out[w] = crc8(Uint8List.sublistView(out, 0, headerSize + len));
    return out;
  }

  static Frame? decode(Uint8List raw) {
    if (raw.length < headerSize + crcSize) return null;
    final seq = (raw[0] << 8) | raw[1];
    final flags = raw[2];
    final len = (raw[3] << 8) | raw[4];
    if (raw.length != headerSize + len + crcSize) return null;
    final payload = Uint8List.sublistView(raw, headerSize, headerSize + len);
    final got = raw[headerSize + len];
    final want = crc8(Uint8List.sublistView(raw, 0, headerSize + len));
    if (got != want) return null;
    return Frame(
      seq: seq,
      continuation: (flags & flagContinuation) != 0,
      flags: flags,
      payload: payload,
    );
  }

  /// CRC-8 / SMBUS-style. Polynomial 0x07, init 0x00, no reflection,
  /// no final xor. "123456789" => 0xF4. Must match iOS PacketCodec.crc8.
  static int crc8(Uint8List data) {
    int crc = 0;
    for (final b in data) {
      crc ^= b;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x07) & 0xFF : (crc << 1) & 0xFF;
      }
    }
    return crc & 0xFF;
  }
}

class Frame {
  final int seq;
  final bool continuation;
  final int flags;
  final Uint8List payload;
  const Frame({
    required this.seq,
    required this.continuation,
    required this.flags,
    required this.payload,
  });
}

/// Reassembles chunked payloads keyed by [seq]. Mirrors iOS side logic.
class Reassembler {
  final Map<int, List<Uint8List>> _buf = {};

  /// Feed a frame. Returns the full reassembled payload when the final
  /// (continuation=false) chunk for [seq] arrives, otherwise null.
  /// Out-of-order chunks are accepted; final order is the arrival order.
  Uint8List? add(Frame frame) {
    if (frame.continuation) {
      _buf.putIfAbsent(frame.seq, () => []).add(frame.payload);
      return null;
    }
    final list = _buf.remove(frame.seq);
    if (list == null || list.isEmpty) return frame.payload;
    final total =
        list.fold<int>(0, (n, c) => n + c.length) + frame.payload.length;
    final out = Uint8List(total);
    int w = 0;
    for (final c in list) {
      out.setRange(w, w + c.length, c);
      w += c.length;
    }
    out.setRange(w, w + frame.payload.length, frame.payload);
    return out;
  }

  void clear() => _buf.clear();
}