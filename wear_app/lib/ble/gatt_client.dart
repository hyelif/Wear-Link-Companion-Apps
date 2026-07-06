// High-level BLE client for the watch side. Wraps the platform channel,
// applies the packet codec, and exposes typed outbound notify + inbound
// frame dispatch. Feature code subscribes to inbound frames by UUID.
import 'dart:async';
import 'dart:typed_data';

import 'package:wear_app/ble/packet_codec.dart';
import 'package:wear_app/platform/ble_peripheral_channel.dart';

/// Mirror of ios_app BluetoothUUIDs.swift / protocol/GATT.md.
class GattUuid {
  static const service = '0000fe01-0000-1000-8000-00805f9b34fb';
  static const deviceInfo = '0000fe10-0000-1000-8000-00805f9b34fb';
  static const healthStream = '0000fe20-0000-1000-8000-00805f9b34fb';
  static const healthControl = '0000fe21-0000-1000-8000-00805f9b34fb';
  static const callEvent = '0000fe30-0000-1000-8000-00805f9b34fb';
  static const callAction = '0000fe31-0000-1000-8000-00805f9b34fb';
  static const notification = '0000fe40-0000-1000-8000-00805f9b34fb';
  static const notificationAction = '0000fe41-0000-1000-8000-00805f9b34fb';
  static const musicNowPlaying = '0000fe50-0000-1000-8000-00805f9b34fb';
  static const musicCommand = '0000fe51-0000-1000-8000-00805f9b34fb';
  static const linkControl = '0000fe60-0000-1000-8000-00805f9b34fb';
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
      final ok = await channel.notify(uuid, frame);
      if (ok != true) break;
      offset = end;
    }
  }

  Stream<Uint8List> inbound(String uuid) {
    return (_inbound[uuid] ??= StreamController<Uint8List>.broadcast()).stream;
  }

  void _onRawFrame(String uuid, Uint8List raw) {
    final frame = PacketCodec.decode(raw);
    if (frame == null) return;
    final reassembled = _reassembler.add(frame);
    if (reassembled != null) {
      onFrame?.call(uuid, reassembled);
      (_inbound[uuid] ??= StreamController<Uint8List>.broadcast())
          .add(reassembled);
    }
  }

  void _onConn(String? state) {
    onConn?.call(state ?? 'DISCONNECTED');
    if (state == 'DISCONNECTED') _reassembler.clear();
  }
}