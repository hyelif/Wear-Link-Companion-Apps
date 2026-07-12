// High-level BLE client for the watch side. Wraps the platform channel,
// applies the packet codec, and exposes typed outbound notify + inbound
// frame dispatch. Feature code subscribes to inbound frames by UUID.
import 'dart:async';
import 'dart:typed_data';

import 'package:wear_app/ble/packet_codec.dart';
import 'package:wear_app/platform/ble_peripheral_channel.dart';

/// Mirror of ios_app BluetoothUUIDs.swift / protocol/GATT.md.
class GattUuid {
  static const service = 'fe012f26-7d24-4287-98cc-736bc4d49a61';
  static const deviceInfo = 'fe102f26-7d24-4287-98cc-736bc4d49a61';
  static const healthStream = 'fe202f26-7d24-4287-98cc-736bc4d49a61';
  static const healthControl = 'fe212f26-7d24-4287-98cc-736bc4d49a61';
  static const callEvent = 'fe302f26-7d24-4287-98cc-736bc4d49a61';
  static const callAction = 'fe312f26-7d24-4287-98cc-736bc4d49a61';
  static const notification = 'fe402f26-7d24-4287-98cc-736bc4d49a61';
  static const notificationAction = 'fe412f26-7d24-4287-98cc-736bc4d49a61';
  static const musicNowPlaying = 'fe502f26-7d24-4287-98cc-736bc4d49a61';
  static const musicCommand = 'fe512f26-7d24-4287-98cc-736bc4d49a61';
  static const linkControl = 'fe602f26-7d24-4287-98cc-736bc4d49a61';
}

class GattClient {
  GattClient({required this.channel});
  final BlePeripheralChannel channel;

  final Reassembler _reassembler = Reassembler();
  int _outSeq = 0;

  /// Inbound: uuid -> reassembled protobuf payload stream.
  final Map<String, StreamController<Uint8List>> _inbound = {};
  void Function(String uuid, Uint8List payload)? onFrame;
  void Function(String state)? onConn;

  /// Call once at startup. Wires the native event stream into the codec.
  void start({
    void Function(String uuid, Uint8List payload)? onFrame,
    void Function(String state)? onConn,
  }) {
    this.onFrame = onFrame;
    this.onConn = onConn;
    channel.listen((event) {
      if (event.type == 'conn') {
        _onConn(event.connState);
      } else if (event.type == 'frame') {
        _onRawFrame(event.uuid!, event.data!);
      }
    });
    channel.start();
    channel.advertiseStart();
  }

  /// Hard restart of the native BLE engine. Used by Quick Sync when the
  /// foreground service did not auto-start or advertising stopped.
  Future<void> restart() async {
    await channel.stop();
    await channel.start();
    await channel.advertiseStart();
  }

  Future<void> stop() async {
    channel.advertiseStop();
    channel.stop();
    channel.dispose();
    for (final c in _inbound.values) {
      c.close();
    }
    _inbound.clear();
  }

  /// Outbound: split a payload into framed chunks and notify the central.
  /// [uuid] must be a notify characteristic the central has subscribed to.
  Future<void> send(String uuid, Uint8List payload, {int mtu = 240}) async {
    final chunkLen = mtu - PacketCodec.headerSize - PacketCodec.crcSize;
    final seq = _outSeq++;
    var offset = 0;
    while (offset < payload.length) {
      final end = (offset + chunkLen).clamp(0, payload.length);
      final chunk = Uint8List.sublistView(payload, offset, end);
      final cont = end < payload.length;
      final frame = PacketCodec.encode(
        seq: seq,
        continuation: cont,
        payload: chunk,
      );
      try {
        final ok = await channel.notify(uuid, frame);
        if (ok != true) break;
      } catch (_) {
        break;
      }
      offset = end;
    }
  }

  Stream<Uint8List> inbound(String uuid) {
    return (_inbound[uuid] ??= StreamController<Uint8List>.broadcast(
      onCancel: () => _inbound.remove(uuid),
    )).stream;
  }

  void _onRawFrame(String uuid, Uint8List raw) {
    final frame = PacketCodec.decode(raw);
    if (frame == null) return;
    final reassembled = _reassembler.add(frame);
    if (reassembled != null) {
      onFrame?.call(uuid, reassembled);
      (_inbound[uuid] ??= StreamController<Uint8List>.broadcast(
        onCancel: () => _inbound.remove(uuid),
      )).add(reassembled);
    }
  }

  void _onConn(String? state) {
    onConn?.call(state ?? 'DISCONNECTED');
    if (state == 'DISCONNECTED') {
      _reassembler.clear();
      // Reset the outbound seq space on reconnect (codec.md). The watch's GattClient
      // is a singleton that persists across connects, so without this the seq would
      // carry over and eventually collide after 0xFFFF writes.
      _outSeq = 0;
    }
  }
}