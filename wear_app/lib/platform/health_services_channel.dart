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
  StreamSubscription<dynamic>? _eventSub;

  Stream<Map<String, dynamic>> get events => _controller.stream;

  HealthServicesChannel() {
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

  /// Request BODY_SENSORS + ACTIVITY_RECOGNITION at runtime (Android 12+/Wear OS 3+
  /// requires runtime grant for dangerous permissions). Returns true when BODY_SENSORS
  /// — the hard gate for heart-rate capture — is granted. Must be awaited before
  /// [start]; otherwise HealthCollector.start() silently no-ops on a fresh install.
  Future<bool> requestPermissions() async =>
      (await _methodChannel.invokeMethod('requestPermissions')) as bool;

  Future<bool> stop() async =>
      (await _methodChannel.invokeMethod('stop')) as bool;

  Future<bool> startActive() async =>
      (await _methodChannel.invokeMethod('startActive')) as bool;

  Future<bool> stopActive() async =>
      (await _methodChannel.invokeMethod('stopActive')) as bool;

  void dispose() {
    _eventSub?.cancel();
    _controller.close();
  }
}
