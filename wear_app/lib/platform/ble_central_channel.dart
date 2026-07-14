// Native platform channel bridge to BleCentralPlugin (Kotlin) /
// BleCentralService. Transport only -- codec + proto decode live in Dart.
import 'dart:async';

import 'package:flutter/services.dart';

import 'ble_frame_event.dart';

class BleCentralChannel {
  static const MethodChannel _m = MethodChannel('wearlink/ble_central');
  static const EventChannel _e = EventChannel('wearlink/ble_central/events');

  StreamSubscription? _sub;

  Future<bool> requestPermissions() async =>
      (await _m.invokeMethod('requestPermissions')) as bool;

  Future<void> startScan() async => _m.invokeMethod('startScan');
  Future<void> stopScan() async => _m.invokeMethod('stopScan');
  Future<void> disconnect() async => _m.invokeMethod('disconnect');

  /// Write [data] to the remote characteristic identified by [uuid].
  /// Returns true when the write was acknowledged by the remote GATT server.
  Future<bool> write(String uuid, Uint8List data) async =>
      (await _m.invokeMethod('write', {'uuid': uuid, 'data': data})) as bool;

  /// Read the current value of the characteristic identified by [uuid].
  /// The result arrives asynchronously via the event stream as a frame event.
  Future<bool> read(String uuid) async =>
      (await _m.invokeMethod('read', {'uuid': uuid})) as bool;

  /// Request an ATT MTU of [mtu] bytes from the remote peripheral.
  /// Returns the negotiated MTU (may be lower than requested).
  Future<int> requestMtu(int mtu) async =>
      (await _m.invokeMethod('requestMtu', {'mtu': mtu})) as int;

  /// Forget the paired iPhone: clear saved MAC, disconnect, stop scanning.
  Future<void> forgetDevice() async => _m.invokeMethod('forgetDevice');

  Stream<BleFrameEvent> events() {
    return _e.receiveBroadcastStream().map(
      (raw) => BleFrameEvent.fromMap(raw as Map<dynamic, dynamic>),
    );
  }

  void listen(void Function(BleFrameEvent) onEvent) {
    _sub?.cancel();
    _sub = events().listen(onEvent);
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}
