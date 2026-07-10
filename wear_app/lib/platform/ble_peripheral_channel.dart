// Native platform channel bridge to WearLinkBlePlugin (Kotlin) /
// BlePeripheralService. Transport only — codec + proto decode live in Dart.
import 'dart:async';

import 'package:flutter/services.dart';

class BleFrameEvent {
  final String type; // "conn" | "frame"
  final String? connState; // DISCONNECTED | CONNECTING | CONNECTED
  final String? uuid;
  final Uint8List? data;

  BleFrameEvent.conn(this.connState) : type = 'conn', uuid = null, data = null;
  BleFrameEvent.frame(this.uuid, this.data) : type = 'frame', connState = null;

  factory BleFrameEvent.fromMap(Map<dynamic, dynamic> m) {
    final type = m['type'] as String;
    if (type == 'conn') {
      return BleFrameEvent.conn(m['state'] as String);
    }
    final data = m['data'];
    return BleFrameEvent.frame(
      m['uuid'] as String,
      data is Uint8List ? data : Uint8List.fromList(data.cast<int>()),
    );
  }
}

class BlePeripheralChannel {
  static const MethodChannel _m = MethodChannel('wearlink/ble');
  static const EventChannel _e = EventChannel('wearlink/ble/events');

  StreamSubscription? _sub;
  final void Function(BleFrameEvent event)? onData;

  BlePeripheralChannel({this.onData});

  Future<void> start() async => _m.invokeMethod('start');
  Future<void> stop() async => _m.invokeMethod('stop');
  Future<void> advertiseStart() async => _m.invokeMethod('advertiseStart');
  Future<void> advertiseStop() async => _m.invokeMethod('advertiseStop');

  Future<bool> notify(String uuid, Uint8List frame) async =>
      (await _m.invokeMethod('notify', {'uuid': uuid, 'data': frame})) as bool;

  /// Native device facts (model, firmware, battery, mtu) used to build the
  /// DeviceInfo protobuf served on FE10 reads.
  Future<Map<dynamic, dynamic>> getDeviceInfo() async =>
      (await _m.invokeMethod('getDeviceInfo')) as Map<dynamic, dynamic>;

  /// Cache a framed DeviceInfo payload for the next FE10 read from the iPhone.
  Future<void> setDeviceInfo(Uint8List frame) async =>
      _m.invokeMethod('setDeviceInfo', {'data': frame});

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