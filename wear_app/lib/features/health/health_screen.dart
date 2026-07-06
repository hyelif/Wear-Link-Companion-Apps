import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:wear_app/signals/health_signal.dart';

/// Watch health dashboard. Shows live HR, steps, calories, distance, sleep.
/// Reads from HealthSignal (signals_dart).
class HealthScreen extends StatelessWidget {
  final HealthSignal health;

  const HealthScreen({super.key, required this.health});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Health')),
      body: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            _MetricTile(
              label: 'Heart Rate',
              value: watchSignal(context, health.heartRate),
              unit: 'BPM',
              icon: Icons.favorite,
            ),
            _MetricTile(
              label: 'Steps',
              value: watchSignal(context, health.steps),
              unit: '',
              icon: Icons.directions_walk,
            ),
            _MetricTile(
              label: 'Calories',
              value: watchSignal(context, health.calories),
              unit: 'kcal',
              icon: Icons.local_fire_department,
            ),
            _MetricTile(
              label: 'Distance',
              value: watchSignal(context, health.distance),
              unit: 'm',
              icon: Icons.straighten,
            ),
            _SleepTile(sleep: watchSignal(context, health.sleep)),
            const Spacer(),
            Text(
              'Pending: ${watchSignal(context, health.pendingCount)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  final String label;
  final double? value;
  final String unit;
  final IconData icon;

  const _MetricTile({
    required this.label,
    required this.value,
    required this.unit,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final display = value != null
        ? '${value!.toStringAsFixed(value! < 10 ? 1 : 0)}$unit'
        : '--';
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        trailing: Text(
          display,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
    );
  }
}

class _SleepTile extends StatelessWidget {
  final double? sleep;

  const _SleepTile({required this.sleep});

  @override
  Widget build(BuildContext context) {
    final text = sleep == null
        ? '--'
        : sleep! > 0
            ? 'Asleep'
            : 'Awake';
    final icon = sleep == null
        ? Icons.bedtime_outlined
        : sleep! > 0
            ? Icons.bedtime
            : Icons.wb_sunny;
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: const Text('Sleep'),
        trailing: Text(text, style: Theme.of(context).textTheme.titleMedium),
      ),
    );
  }
}
