// Native platform channel bridge to WearLinkBlePlugin (Kotlin) /
// BlePeripheralService. Transport only — codec + proto decode live in Dart.
import 'dart:async';

import 'package:flutter/services.dart';

class BleFrameEvent {
  final String type; // "conn" | "frame" | "mtu" | "error"
  final String? connState; // DISCONNECTED | CONNECTING | CONNECTED
  final String? uuid;
  final Uint8List? data;
  final int? mtu; // negotiated ATT MTU (mtu events)
  final String? errorMsg; // start/operation failure (error events)
  final String? deviceName; // remote device name (conn events only)

  BleFrameEvent.conn(this.connState, {this.deviceName})
      : type = 'conn', uuid = null, data = null, mtu = null, errorMsg = null;
  BleFrameEvent.frame(this.uuid, this.data)
      : type = 'frame', connState = null, mtu = null, errorMsg = null, deviceName = null;
  BleFrameEvent.mtu(this.mtu)
      : type = 'mtu', connState = null, uuid = null, data = null, errorMsg = null, deviceName = null;
  BleFrameEvent.error(this.errorMsg)
      : type = 'error', connState = null, uuid = null, data = null, mtu = null, deviceName = null;

  factory BleFrameEvent.fromMap(Map<dynamic, dynamic> m) {
    final type = m['type'] as String;
    if (type == 'conn') {
      return BleFrameEvent.conn(
        m['state'] as String,
        deviceName: m['deviceName'] as String?,
      );
    }
    if (type == 'mtu') {
      return BleFrameEvent.mtu((m['mtu'] as num?)?.toInt());
    }
    if (type == 'error') {
      return BleFrameEvent.error(m['msg'] as String?);
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

  /// Request BLUETOOTH_SCAN + BLUETOOTH_CONNECT + BLUETOOTH_ADVERTISE at runtime
  /// (Wear OS 3+ / API 31+ requires a runtime grant for the dangerous BLE perms).
  /// MUST be awaited before [start] / [advertiseStart]; otherwise the GATT server
  /// cannot exchange data and the advertiser silently fails (onStartFailure) —
  /// the watch stays invisible to the iPhone. Returns true when all three are
  /// granted. No-op (returns true) below API 31 where these are install-time grants.
  Future<bool> requestPermissions() async =>
      (await _m.invokeMethod('requestPermissions')) as bool;

  /// Request exemption from battery optimization so the system does not kill
  /// the FGS when the app goes to background. Opens the system Settings page
  /// for the user to toggle "Don't optimize" on. Returns true if already
  /// exempted, false if the user needs to grant it manually.
  Future<bool> requestBatteryExemption() async =>
      (await _m.invokeMethod('requestBatteryExemption')) as bool;

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