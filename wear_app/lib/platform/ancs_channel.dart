import 'dart:async';

import 'package:flutter/services.dart';

/// Dart bridge to native AncsPlugin (MethodChannel + EventChannel).
///
/// Channels:
///   MethodChannel "wearlink/ancs"        — start, stop
///   EventChannel  "wearlink/ancs/events" — stream of notification events
class AncsChannel {
  static const _methodChannel = MethodChannel('wearlink/ancs');
  static const _eventChannel = EventChannel('wearlink/ancs/events');

  final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<dynamic>? _eventSub;

  Stream<Map<String, dynamic>> get events => _controller.stream;

  AncsChannel() {
    _eventSub = _eventChannel.receiveBroadcastStream().listen(
      (data) {
        if (data is Map<String, dynamic>) {
          _controller.add(data);
        }
      },
      onError: (error) => _controller.addError(error),
    );
  }

  Future<bool> start() async =>
      (await _methodChannel.invokeMethod('start')) as bool;

  Future<bool> stop() async =>
      (await _methodChannel.invokeMethod('stop')) as bool;

  void dispose() {
    _eventSub?.cancel();
    _controller.close();
  }
}
