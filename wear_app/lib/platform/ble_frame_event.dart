import 'dart:typed_data';

/// Event from the native BLE platform channel, decoded from the raw map
/// emitted by the EventChannel. Shared by both BlePeripheralChannel and
/// BleCentralChannel.
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
