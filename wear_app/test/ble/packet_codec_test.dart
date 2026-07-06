// Verifies PacketCodec round-trip + CRC + chunk reassembly.
// Cross-compat: keep a known-answer vector in sync with iOS XCTest.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wear_app/ble/packet_codec.dart';

void main() {
  group('PacketCodec', () {
    test('round-trip single frame', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final enc = PacketCodec.encode(seq: 42, continuation: false, payload: payload);
      expect(enc.length, PacketCodec.headerSize + payload.length + PacketCodec.crcSize);

      final frame = PacketCodec.decode(enc);
      expect(frame, isNotNull);
      expect(frame!.seq, 42);
      expect(frame.continuation, isFalse);
      expect(frame.payload, payload);
    });

    test('continuation flag set correctly', () {
      final enc = PacketCodec.encode(
        seq: 1,
        continuation: true,
        payload: Uint8List.fromList([0xAA, 0xBB]),
      );
      final frame = PacketCodec.decode(enc);
      expect(frame!.continuation, isTrue);
    });

    test('CRC mismatch rejected', () {
      final enc = PacketCodec.encode(
        seq: 1,
        continuation: false,
        payload: Uint8List.fromList([9, 9, 9]),
      );
      enc[enc.length - 1] ^= 0xFF; // corrupt crc
      expect(PacketCodec.decode(enc), isNull);
    });

    test('truncated frame rejected', () {
      final enc = PacketCodec.encode(
        seq: 1,
        continuation: false,
        payload: Uint8List.fromList([1, 2, 3]),
      );
      expect(PacketCodec.decode(Uint8List.sublistView(enc, 0, 3)), isNull);
    });

    test('empty payload round-trips', () {
      final enc = PacketCodec.encode(seq: 0, continuation: false, payload: Uint8List(0));
      final frame = PacketCodec.decode(enc);
      expect(frame!.payload, isEmpty);
    });

    test('CRC-8 known-answer vector (sync with iOS test)', () {
      // "123456789" => CRC-8/SMBUS-style (poly 0x07, init 0x00, no
      // reflection, no final xor) = 0xF4.
      final data = Uint8List.fromList([49, 50, 51, 52, 53, 54, 55, 56, 57]);
      expect(PacketCodec.crc8(data), 0xF4);
    });
  });

  group('Reassembler', () {
    test('reassembles multi-chunk payload in arrival order', () {
      final r = Reassembler();
      final big = Uint8List.fromList(List.generate(100, (i) => i));

      // split into 3 chunks: cont, cont, final
      final c1 = PacketCodec.encode(
          seq: 7, continuation: true, payload: Uint8List.sublistView(big, 0, 30));
      final c2 = PacketCodec.encode(
          seq: 7, continuation: true, payload: Uint8List.sublistView(big, 30, 60));
      final c3 = PacketCodec.encode(
          seq: 7, continuation: false, payload: Uint8List.sublistView(big, 60, 100));

      expect(r.add(PacketCodec.decode(c1)!), isNull);
      expect(r.add(PacketCodec.decode(c2)!), isNull);
      final got = r.add(PacketCodec.decode(c3)!);
      expect(got, isNotNull);
      expect(got, big);
    });

    test('single non-chunked frame returns payload directly', () {
      final r = Reassembler();
      final enc = PacketCodec.encode(
          seq: 5, continuation: false, payload: Uint8List.fromList([1, 1, 1]));
      expect(r.add(PacketCodec.decode(enc)!), Uint8List.fromList([1, 1, 1]));
    });
  });
}