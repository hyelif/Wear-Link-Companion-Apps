import 'dart:async';

import 'package:fixnum/fixnum.dart';
import 'package:signals/signals.dart';
import 'package:wear_app/gen/wearlink.pb.dart';

import '../platform/health_services_channel.dart';

/// Health data state store. Receives batches from native HealthCollector
/// via platform channel and exposes them as signals.
///
/// Data from Health Services (health-services-client 1.1.0-rc02):
///   heart_rate, steps, calories, distance, sleep (awake/asleep)
/// NOT available: SpO2, HRV, sleep stages (see Software-Structure §9)
class HealthSignal {
  final HealthServicesChannel _channel;

  /// Latest heart rate (BPM), or null.
  final heartRate = signal<double?>(null, options: SignalOptions(name: 'heartRate'));

  /// Step count since boot / last reset.
  final steps = signal<double>(0, options: SignalOptions(name: 'steps'));

  /// Calories burned (kcal).
  final calories = signal<double>(0, options: SignalOptions(name: 'calories'));

  /// Distance traveled (meters).
  final distance = signal<double>(0, options: SignalOptions(name: 'distance'));

  /// Sleep state: 1.0 = asleep, 0.0 = awake, null = unknown.
  final sleep = signal<double?>(null, options: SignalOptions(name: 'sleep'));

  /// Number of samples queued for BLE sync.
  final pendingCount = signal<int>(0, options: SignalOptions(name: 'pendingCount'));

  /// Raw sample buffer for BLE batch send.
  final List<HealthSample> _buffer = [];

  StreamSubscription<Map<String, dynamic>>? _sub;

  HealthSignal(this._channel) {
    _sub = _channel.events.listen(_onEvent);
  }

  /// Start native health collection.
  Future<void> start() => _channel.start();

  void _onEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    if (type == 'batch') {
      final samples = event['samples'] as List<dynamic>?;
      if (samples == null) return;
      for (final s in samples) {
        if (s is! Map<String, dynamic>) continue;
        try {
          _ingest(s);
        } catch (_) {
          // Skip malformed sample; don't crash the health pipeline.
        }
      }
    }
  }

  void _ingest(Map<String, dynamic> sample) {
    final type = sample['type'] as String? ?? '';
    final value = (sample['value'] as num?)?.toDouble() ?? 0;
    final timestampMs = (sample['timestampMs'] as num?)?.toInt() ?? 0;

    switch (type) {
      case 'heart_rate':
        heartRate.value = value;
        break;
      case 'steps':
        steps.value = value;
        break;
      case 'calories':
        calories.value = value;
        break;
      case 'distance':
        distance.value = value;
        break;
      case 'sleep':
        sleep.value = value;
        break;
    }

    // Enqueue for BLE sync.
    final pbType = _toProtoType(type);
    if (pbType != HealthSample_Type.TYPE_UNSPECIFIED) {
      _buffer.add(HealthSample(
        type: pbType,
        value: value,
        timestampMs: Int64(timestampMs),
      ));
      pendingCount.value = _buffer.length;
    }
  }

  /// Drain buffer and return samples for BLE notify.
  List<HealthSample> drainBuffer() {
    final batch = List<HealthSample>.from(_buffer);
    _buffer.clear();
    pendingCount.value = 0;
    return batch;
  }

  HealthSample_Type _toProtoType(String type) {
    switch (type) {
      case 'heart_rate':
        return HealthSample_Type.HEART_RATE_BPM;
      case 'steps':
        return HealthSample_Type.STEPS;
      case 'calories':
        return HealthSample_Type.CALORIES;
      case 'distance':
        return HealthSample_Type.DISTANCE_METERS;
      case 'sleep':
        return HealthSample_Type.SLEEP;
      default:
        return HealthSample_Type.TYPE_UNSPECIFIED;
    }
  }

  void dispose() {
    _sub?.cancel();
  }
}
