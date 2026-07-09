import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import 'package:wear_app/ble/gatt_client.dart';
import 'package:wear_app/features/call/call_screen.dart';
import 'package:wear_app/features/health/health_screen.dart';
import 'package:wear_app/features/music/music_screen.dart';
import 'package:wear_app/features/notification/notification_screen.dart';
import 'package:wear_app/platform/ancs_channel.dart';
import 'package:wear_app/platform/ble_peripheral_channel.dart';
import 'package:wear_app/platform/health_services_channel.dart';
import 'package:wear_app/signals/ble_signal.dart';
import 'package:wear_app/signals/call_signal.dart';
import 'package:wear_app/signals/health_signal.dart';
import 'package:wear_app/signals/music_signal.dart';
import 'package:wear_app/signals/notification_signal.dart';
import 'package:wear_app/gen/wearlink.pb.dart';

late final BleSignal bleSignal;
late final GattClient gatt;
late final HealthSignal healthSignal;
late final CallSignal callSignal;
late final NotificationSignal notificationSignal;
late final MusicSignal musicSignal;
late final AncsChannel ancsChannel;

/// Health broadcast timer, stored so it can be cancelled on app exit.
Timer? _healthTimer;

void main() {
  bleSignal = BleSignal();
  callSignal = CallSignal();
  notificationSignal = NotificationSignal();
  musicSignal = MusicSignal();

  gatt = GattClient(channel: BlePeripheralChannel());
  gatt.start(
    onFrame: (uuid, payload) {
      bleSignal.setFrame(uuid, payload);
      callSignal.updateFromFrame(uuid, payload);
      notificationSignal.updateFromFrame(uuid, payload);
      musicSignal.updateFromFrame(uuid, payload);
    },
    onConn: (state) {
      bleSignal.setConn(switch (state) {
        'CONNECTED' => ConnState.connected,
        'CONNECTING' => ConnState.connecting,
        _ => ConnState.disconnected,
      });
    },
  );

  musicSignal.gatt = gatt;
  notificationSignal.gattClient = gatt;

  healthSignal = HealthSignal(HealthServicesChannel());
  healthSignal.start();

  // Broadcast health data to the phone every 60 seconds.
  _healthTimer = Timer.periodic(const Duration(seconds: 60), (_) {
    if (bleSignal.connection.value != ConnState.connected) return;
    final samples = healthSignal.drainBuffer();
    if (samples.isEmpty) return;
    final frame = HealthFrame(
      sequence: 0,
      samples: samples,
      compressed: false,
    );
    final payload = frame.writeToBuffer();
    gatt.send(GattUuid.healthStream, Uint8List.fromList(payload));
  });

  ancsChannel = AncsChannel();
  ancsChannel.start();

  runApp(const WearLinkApp());
}

class WearLinkApp extends StatefulWidget {
  const WearLinkApp({super.key});

  @override
  State<WearLinkApp> createState() => _WearLinkAppState();
}

class _WearLinkAppState extends State<WearLinkApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _healthTimer?.cancel();
    healthSignal.dispose();
    ancsChannel.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _healthTimer?.cancel();
      _healthTimer = null;
    } else if (state == AppLifecycleState.resumed) {
      _healthTimer?.cancel();
      _healthTimer = Timer.periodic(const Duration(seconds: 60), (_) {
        if (bleSignal.connection.value != ConnState.connected) return;
        final samples = healthSignal.drainBuffer();
        if (samples.isEmpty) return;
        final frame = HealthFrame(
          sequence: 0,
          samples: samples,
          compressed: false,
        );
        final payload = frame.writeToBuffer();
        gatt.send(GattUuid.healthStream, Uint8List.fromList(payload));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WearLink',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0D0D0D),
        colorScheme: ColorScheme.dark(
          primary: Colors.teal,
          secondary: Colors.tealAccent,
        ),
        textTheme: const TextTheme(
          displayLarge: TextStyle(fontSize: 36, fontWeight: FontWeight.bold),
          displayMedium: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
          displaySmall: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
          headlineLarge: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
          headlineMedium: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          headlineSmall: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          titleMedium: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          titleSmall: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          bodyLarge: TextStyle(fontSize: 16),
          bodyMedium: TextStyle(fontSize: 14),
          bodySmall: TextStyle(fontSize: 12),
          labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          labelMedium: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          labelSmall: TextStyle(fontSize: 10, fontWeight: FontWeight.w500),
        ),
      ),
      home: const ConnectionScreen(),
    );
  }
}

/// Dashboard / home screen for the watch.
///
/// Top: BLE connection status indicator (icon + text).
/// Body: scrollable list of feature cards (Health, Calls, Notifications, Music).
/// Each card navigates to its respective feature screen.
class ConnectionScreen extends StatelessWidget {
  const ConnectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            // BLE connection status indicator
            SignalBuilder(
              builder: (context) {
                final conn = bleSignal.connection.value;
                final (connText, connIcon) = switch (conn) {
                  ConnState.disconnected => ('Searching for iPhone…', Icons.bluetooth_disabled),
                  ConnState.connecting => ('Connecting…', Icons.bluetooth_searching),
                  ConnState.connected => ('Connected to iPhone', Icons.bluetooth_connected),
                };

                final connColor = switch (conn) {
                  ConnState.disconnected => Colors.grey[600]!,
                  ConnState.connecting => Colors.orange,
                  ConnState.connected => Colors.teal,
                };

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(connIcon, size: 24, color: connColor),
                      const SizedBox(width: 8),
                      Text(
                        connText,
                        style: theme.textTheme.titleSmall?.copyWith(color: connColor),
                      ),
                    ],
                  ),
                );
              },
            ),
            const Divider(color: Colors.teal, height: 1),
            // Scrollable feature cards
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                children: [
                  _FeatureCard(
                    icon: Icons.favorite,
                    label: 'Health',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => HealthScreen(health: healthSignal),
                      ),
                    ),
                  ),
                  _FeatureCard(
                    icon: Icons.phone,
                    label: 'Calls',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => CallScreen(
                          callSignal: callSignal,
                          gattClient: gatt,
                        ),
                      ),
                    ),
                  ),
                  _FeatureCard(
                    icon: Icons.notifications,
                    label: 'Notifications',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => NotificationScreen(
                          notifSignal: notificationSignal,
                        ),
                      ),
                    ),
                  ),
                  _FeatureCard(
                    icon: Icons.music_note,
                    label: 'Music',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => MusicScreen(music: musicSignal),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A rounded, dark feature card with a teal circular icon, label, and chevron.
class _FeatureCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _FeatureCard({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Material(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
            child: Row(
              children: [
                // Teal circular icon
                Container(
                  width: 48,
                  height: 48,
                  decoration: const BoxDecoration(
                    color: Colors.teal,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: Colors.white, size: 24),
                ),
                const SizedBox(width: 16),
                // Feature label
                Text(
                  label,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                  ),
                ),
                const Spacer(),
                // Chevron indicator
                Icon(
                  Icons.chevron_right,
                  color: Colors.teal[300],
                  size: 28,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
