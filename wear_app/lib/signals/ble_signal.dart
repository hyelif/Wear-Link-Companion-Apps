// Connection state exposed reactively via signals_dart.
import 'dart:typed_data';

import 'package:signals/signals.dart';

enum ConnState { disconnected, connecting, connected }

class BleSignal {
  final Signal<ConnState> connection =
      signal(ConnState.disconnected, debugLabel: 'ble.connection');

  /// Most recent frame per characteristic uuid (raw). Features read their own.
  final MapSignal<String, Uint8List> lastFrame =
      mapSignal<String, Uint8List>({}, debugLabel: 'ble.lastFrame');

  void setConn(ConnState s) => connection.value = s;
  void setFrame(String uuid, Uint8List data) =>
      lastFrame.value = {...lastFrame.value, uuid: data};
}