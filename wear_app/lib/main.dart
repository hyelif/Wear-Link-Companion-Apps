import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import 'package:wear_app/ble/gatt_client.dart';
import 'package:wear_app/features/health/health_screen.dart';
import 'package:wear_app/platform/ble_peripheral_channel.dart';
import 'package:wear_app/platform/health_services_channel.dart';
import 'package:wear_app/signals/ble_signal.dart';
import 'package:wear_app/signals/health_signal.dart';

late final BleSignal bleSignal;
late final GattClient gatt;
late final HealthSignal healthSignal;

void main() {
  bleSignal = BleSignal();
  gatt = GattClient(channel: BlePeripheralChannel());
  gatt.start(
    onFrame: (uuid, payload) => bleSignal.setFrame(uuid, payload),
    onConn: (state) {
      bleSignal.setConn(switch (state) {
        'CONNECTED' => ConnState.connected,
        'CONNECTING' => ConnState.connecting,
        _ => ConnState.disconnected,
      });
    },
  );
  healthSignal = HealthSignal(HealthServicesChannel());
  healthSignal.start();
  runApp(const WearLinkApp());
}

class WearLinkApp extends StatelessWidget {
  const WearLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WearLink',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal)),
      home: const ConnectionScreen(),
    );
  }
}

class ConnectionScreen extends StatelessWidget {
  const ConnectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final conn = watchSignal(context, bleSignal.connection);
    final text = switch (conn) {
      ConnState.disconnected => 'Searching for iPhone…',
      ConnState.connecting => 'Connecting…',
      ConnState.connected => 'Connected to iPhone',
    };
    final icon = switch (conn) {
      ConnState.disconnected => Icons.bluetooth_disabled,
      ConnState.connecting => Icons.bluetooth_searching,
      ConnState.connected => Icons.bluetooth_connected,
    };
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 48),
            const SizedBox(height: 8),
            Text(text, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => HealthScreen(health: healthSignal),
                ),
              ),
              child: const Text('Health'),
            ),
          ],
        ),
      ),
    );
  }
}