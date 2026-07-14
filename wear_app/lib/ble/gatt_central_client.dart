// High-level BLE central client for the watch side. Wraps the platform channel,
// applies the packet codec, and exposes typed outbound write + inbound frame
// dispatch. Feature code subscribes to inbound frames by UUID.
//
// Mirror of GattClient but for central mode: the watch acts as BLE central
// (scanner) instead of BLE peripheral (advertiser). Outbound frames use
// channel.write() instead of channel.notify().
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:wear_app/ble/packet_codec.dart';
import 'package:wear_app/platform/ble_central_channel.dart';

/// Mirror of ios_app BluetoothUUIDs.swift / protocol/GATT.md.
class GattCentralUuid {
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

class GattCentralClient {
  GattCentralClient({required this.channel});
  final BleCentralChannel channel;

  final Reassembler _reassembler = Reassembler();
  int _outSeq = 0;

  /// Negotiated ATT MTU (ATT default 23 until the remote peripheral responds
  /// to an MTU request). Used to size outbound write chunks so a frame never
  /// exceeds what the link can carry.
  int _negotiatedMtu = 23;

  /// Inbound: uuid -> reassembled protobuf payload stream.
  final Map<String, StreamController<Uint8List>> _inbound = {};
  void Function(String uuid, Uint8List payload)? onFrame;
  /// Connection state callback. [deviceName] is the remote device name when
  /// CONNECTED, null otherwise.
  void Function(String state, {String? deviceName})? onConn;
  /// Fires when the remote peripheral negotiates a new ATT MTU.
  void Function(int mtu)? onMtu;
  /// Fires on native start/operation failure.
  void Function(String msg)? onError;

  bool _started = false;

  /// Call once at startup. Wires the native event stream into the codec.
  /// Idempotent: subsequent calls are no-ops (prevents thrash if the
  /// Flutter engine re-attaches and main() re-runs).
  void start({
    void Function(String uuid, Uint8List payload)? onFrame,
    void Function(String state, {String? deviceName})? onConn,
    void Function(int mtu)? onMtu,
    void Function(String msg)? onError,
  }) {
    if (_started) {
      print('GattCentralClient.start: already started -- skip (idempotent guard)');
      return;
    }
    _started = true;
    this.onFrame = onFrame;
    this.onConn = onConn;
    this.onMtu = onMtu;
    this.onError = onError;
    channel.listen((event) {
      if (event.type == 'conn') {
        _onConn(event.connState, deviceName: event.deviceName);
      } else if (event.type == 'frame') {
        _onRawFrame(event.uuid!, event.data!);
      } else if (event.type == 'mtu') {
        final m = event.mtu;
        if (m != null && m > 0) {
          _negotiatedMtu = m;
          this.onMtu?.call(m);
        }
      } else if (event.type == 'error') {
        this.onError?.call(event.errorMsg ?? 'unknown BLE error');
      }
    });
    channel.startScan();
  }

  /// Hard reconnect of the native BLE engine. Used by Quick Sync when the
  /// central did not auto-connect or scanning stopped.
  ///
  /// Cooldown: ignores calls within 2s of the last reconnect to prevent
  /// thrashing when the button is pressed rapidly.
  DateTime? _lastReconnect;
  Future<void> reconnect() async {
    final now = DateTime.now();
    if (_lastReconnect != null && now.difference(_lastReconnect!).inMilliseconds < 2000) {
      print('GattCentralClient.reconnect: cooldown active -- skipping (last was ${now.difference(_lastReconnect!).inMilliseconds}ms ago)');
      return;
    }
    _lastReconnect = now;
    await channel.disconnect();
    await channel.startScan();
  }

  Future<void> stop() async {
    _started = false;
    channel.disconnect();
    channel.stopScan();
    channel.dispose();
    for (final c in _inbound.values) {
      c.close();
    }
    _inbound.clear();
  }

  /// Initiate a read of the characteristic identified by [uuid] on the remote
  /// GATT server. The result arrives asynchronously via the onFrame callback.
  Future<bool> read(String uuid) async => channel.read(uuid);

  /// Outbound: split a payload into framed chunks and write to the remote.
  /// [uuid] must be a writable characteristic on the remote GATT server.
  /// Chunk size follows the negotiated ATT MTU so frames never exceed the
  /// link capacity.
  Future<void> send(String uuid, Uint8List payload) async {
    final chunkLen = max(1, _negotiatedMtu - PacketCodec.headerSize - PacketCodec.crcSize);
    final seq = _outSeq;
    _outSeq = (_outSeq + 1) & 0xFFFF;
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
        final ok = await channel.write(uuid, frame);
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

  void _onConn(String? state, {String? deviceName}) {
    onConn?.call(state ?? 'DISCONNECTED', deviceName: deviceName);
    if (state == 'DISCONNECTED') {
      _reassembler.clear();
      _outSeq = 0;
    }
  }
}
