// Verifies GattClient pipeline logic: MTU-based chunk sizing (Phase 20.7),
// outbound seq wrap at 0xFFFF (20.9), disconnect resets seq+reassembler,
// and onMtu/onError/onConn dispatch (20.7 / P2 surfacing path).
//
// Uses a fake BlePeripheralChannel so no native BLE stack is needed — pure
// logic, CI-runnable. Mirrors the style of packet_codec_test.dart.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wear_app/ble/gatt_client.dart';
import 'package:wear_app/ble/packet_codec.dart';
import 'package:wear_app/platform/ble_frame_event.dart';
import 'package:wear_app/platform/ble_peripheral_channel.dart';

/// Stub BlePeripheralChannel: captures the event callback for injection,
/// records notify() calls, and lets a test flip notifyResult to exercise the
/// send-abort path. All other methods are no-ops.
class _FakeBleChannel implements BlePeripheralChannel {
  @override
  final void Function(BleFrameEvent event)? onData;

  _FakeBleChannel({this.onData});

  void Function(BleFrameEvent)? onEvent;
  final List<(String, Uint8List)> notifyCalls = [];
  bool notifyResult = true;

  void emit(BleFrameEvent e) => onEvent?.call(e);

  @override
  void listen(void Function(BleFrameEvent) onEvent) {
    this.onEvent = onEvent;
  }

  @override
  Future<bool> notify(String uuid, Uint8List frame) async {
    notifyCalls.add((uuid, frame));
    return notifyResult;
  }

  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> advertiseStart() async {}
  @override
  Future<void> advertiseStop() async {}
  @override
  Future<bool> requestPermissions() async => true;
  @override
  Future<bool> requestBatteryExemption() async => true;
  @override
  Future<Map<dynamic, dynamic>> getDeviceInfo() async => {};
  @override
  Future<void> setDeviceInfo(Uint8List frame) async {}
  @override
  Stream<BleFrameEvent> events() => const Stream.empty();
  @override
  void dispose() {}
}

/// Drive send() N times. Kept as a helper so test bodies stay assertion-only
/// (project testing rule: no loops in tests). Wrap verification is inherently
/// iterative — 0xFFFF+1 sends is the real behavior probe.
Future<void> _sendN(GattClient g, Uint8List payload, int n) async {
  for (var i = 0; i < n; i++) {
    await g.send(GattUuid.healthStream, payload);
  }
}

void main() {
  late _FakeBleChannel channel;
  late GattClient gatt;

  setUp(() {
    channel = _FakeBleChannel();
    gatt = GattClient(channel: channel);
    gatt.start();
  });

  Frame _decodedFrame(int index) => PacketCodec.decode(channel.notifyCalls[index].$2)!;

  group('chunk sizing follows negotiated MTU (Phase 20.7)', () {
    test('default MTU 23 splits payload at mtu - header - crc', () async {
      // chunkLen = 23 - 5 - 1 = 17. 40 bytes => 17 + 17 + 6.
      final payload = Uint8List.fromList(List.generate(40, (i) => i));
      await gatt.send(GattUuid.healthStream, payload);

      expect(channel.notifyCalls.length, 3);
      for (final (_, frame) in channel.notifyCalls) {
        expect(frame.length, lessThanOrEqualTo(PacketCodec.headerSize + 17 + PacketCodec.crcSize));
      }
      final f0 = _decodedFrame(0);
      final f1 = _decodedFrame(1);
      final f2 = _decodedFrame(2);
      expect(f0.continuation, isTrue);
      expect(f1.continuation, isTrue);
      expect(f2.continuation, isFalse);
      final got = Reassembler();
      got.add(f0);
      got.add(f1);
      expect(got.add(f2), payload);
    });

    test('negotiated MTU 247 yields larger chunks', () {
      // chunkLen = 247 - 5 - 1 = 241. 300 bytes => 241 + 59.
      channel.emit(BleFrameEvent.mtu(247));
      final payload = Uint8List.fromList(List.generate(300, (i) => i & 0xFF));

      return Future(() async {
        await gatt.send(GattUuid.healthStream, payload);
        expect(channel.notifyCalls.length, 2);
        final f0 = _decodedFrame(0);
        final f1 = _decodedFrame(1);
        expect(f0.continuation, isTrue);
        expect(f1.continuation, isFalse);
        final got = Reassembler();
        got.add(f0);
        expect(got.add(f1), payload);
      });
    });
  });

  group('outbound seq (Phase 20.9)', () {
    test('seq increments per send starting at 0', () {
      final payload = Uint8List.fromList([1]);

      return Future(() async {
        await _sendN(gatt, payload, 3);
        expect(_decodedFrame(0).seq, 0);
        expect(_decodedFrame(1).seq, 1);
        expect(_decodedFrame(2).seq, 2);
      });
    });

    test('seq wraps at 0xFFFF back to 0', () {
      final payload = Uint8List.fromList([1]);

      return Future(() async {
        // 0x10000 sends: seqs 0..0xFFFF, then wraps so the next is 0 again.
        await _sendN(gatt, payload, 0x10000 + 1);
        // Last send (the 65537th) reused seq 0 after wrap.
        expect(_decodedFrame(channel.notifyCalls.length - 1).seq, 0);
        // The 65536th send used seq 0xFFFF just before wrapping.
        expect(_decodedFrame(0xFFFF).seq, 0xFFFF);
      });
    });

    test('disconnect resets outbound seq to 0', () {
      final payload = Uint8List.fromList([1]);

      return Future(() async {
        await _sendN(gatt, payload, 3);
        channel.emit(BleFrameEvent.conn('DISCONNECTED'));
        await gatt.send(GattUuid.healthStream, payload);
        // First send after disconnect reuses seq 0.
        expect(_decodedFrame(channel.notifyCalls.length - 1).seq, 0);
      });
    });
  });

  group('disconnect clears reassembler', () {
    test('partial chunk before disconnect is dropped, not carried over', () {
      final delivered = <Uint8List>[];
      gatt.onFrame = (_, payload) => delivered.add(payload);

      // Partial chunk for seq 9 — should NOT deliver (continuation true).
      channel.emit(BleFrameEvent.frame(
        GattUuid.healthStream,
        PacketCodec.encode(seq: 9, continuation: true, payload: Uint8List.fromList([1, 2, 3])),
      ));
      expect(delivered, isEmpty);

      // Disconnect clears the reassembler buffer.
      channel.emit(BleFrameEvent.conn('DISCONNECTED'));

      // New chunks for the same seq 9 reassemble WITHOUT the pre-disconnect [1,2,3].
      channel.emit(BleFrameEvent.frame(
        GattUuid.healthStream,
        PacketCodec.encode(seq: 9, continuation: true, payload: Uint8List.fromList([4, 5, 6])),
      ));
      channel.emit(BleFrameEvent.frame(
        GattUuid.healthStream,
        PacketCodec.encode(seq: 9, continuation: false, payload: Uint8List.fromList([7, 8, 9])),
      ));
      expect(delivered.length, 1);
      expect(delivered.single, Uint8List.fromList([4, 5, 6, 7, 8, 9]));
    });
  });

  group('event dispatch', () {
    test('onMtu fires with the negotiated value', () {
      var gotMtu = 0;
      gatt.onMtu = (m) => gotMtu = m;
      channel.emit(BleFrameEvent.mtu(180));
      expect(gotMtu, 180);
    });

    test('onError fires with the native failure message (P2 path)', () {
      String? gotErr;
      gatt.onError = (msg) => gotErr = msg;
      channel.emit(BleFrameEvent.error('notify send failed status=5'));
      expect(gotErr, 'notify send failed status=5');
    });

    test('onConn fires with the connection state', () {
      String? gotConn;
      gatt.onConn = (s) => gotConn = s;
      channel.emit(BleFrameEvent.conn('CONNECTED'));
      expect(gotConn, 'CONNECTED');
    });
  });

  group('send abort', () {
    test('send stops chunking when notify returns false', () {
      channel.notifyResult = false;
      final payload = Uint8List.fromList(List.generate(40, (i) => i)); // 3 chunks at MTU 23

      return Future(() async {
        await gatt.send(GattUuid.healthStream, payload);
        expect(channel.notifyCalls.length, 1); // broke after the first failed notify
      });
    });
  });
}