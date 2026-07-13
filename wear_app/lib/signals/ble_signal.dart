// Connection state exposed reactively via signals_dart.
import 'dart:typed_data';

import 'package:signals/signals.dart';

enum ConnState { disconnected, connecting, connected }

class BleSignal {
  final Signal<ConnState> connection =
      signal(ConnState.disconnected, options: SignalOptions(name: 'ble.connection'));

  /// Name of the connected iPhone (set when a CONNECTED event carries a device name).
  final Signal<String?> deviceName =
      signal<String?>(null, options: SignalOptions(name: 'ble.deviceName'));

  /// Most recent frame per characteristic uuid (raw). Features read their own.
  final MapSignal<String, Uint8List> lastFrame =
      mapSignal<String, Uint8List>({}, options: MapSignalOptions(name: 'ble.lastFrame'));

  void setConn(ConnState s) => connection.value = s;
  void setDeviceName(String? name) => deviceName.value = name;
  void setFrame(String uuid, Uint8List data) =>
      lastFrame.value = {...lastFrame.value, uuid: data};

  void dispose() {}
}