import 'dart:async';

import 'package:flutter/services.dart';

/// Dart bridge to native HealthServicesPlugin (MethodChannel + EventChannel).
///
/// Channels:
///   MethodChannel "wearlink/health"      — start, stop, startActive, stopActive
///   EventChannel  "wearlink/health/events" — batch samples stream
class HealthServicesChannel {
  static const _methodChannel = MethodChannel('wearlink/health');
  static const _eventChannel = EventChannel('wearlink/health/events');

  final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get events => _controller.stream;

  HealthServicesChannel() {
    _eventChannel.receiveBroadcastStream().listen(
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

  Future<bool> startActive() async =>
      (await _methodChannel.invokeMethod('startActive')) as bool;

  Future<bool> stopActive() async =>
      (await _methodChannel.invokeMethod('stopActive')) as bool;

  void dispose() {
    _controller.close();
  }
}
