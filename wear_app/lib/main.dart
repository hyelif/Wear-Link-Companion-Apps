import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import 'package:wear_app/ble/gatt_central_client.dart';
import 'package:wear_app/features/call/call_screen.dart';
import 'package:wear_app/features/health/health_screen.dart';
import 'package:wear_app/features/music/music_screen.dart';
import 'package:wear_app/features/notification/notification_screen.dart';
import 'package:wear_app/platform/ble_central_channel.dart';
import 'package:wear_app/platform/health_services_channel.dart';
import 'package:wear_app/signals/ble_signal.dart';
import 'package:wear_app/signals/call_signal.dart';
import 'package:wear_app/signals/health_signal.dart';
import 'package:wear_app/signals/music_signal.dart';
import 'package:wear_app/signals/notification_signal.dart';
import 'package:wear_app/gen/wearlink.pb.dart';

late final BleSignal bleSignal;
late final BleCentralChannel bleCentralChannel;
late final GattCentralClient gattCentral;
late final HealthServicesChannel healthChannel;
late final HealthSignal healthSignal;
late final CallSignal callSignal;
late final NotificationSignal notificationSignal;
late final MusicSignal musicSignal;

/// Health broadcast timer, stored so it can be cancelled/restarted.
Timer? _healthTimer;
/// Health push interval (ms), configured by the iPhone via FE21 SET_INTERVAL_MS.
/// Default 60 s. A SET_INTERVAL_MS command restarts the timer at this cadence.
int _healthIntervalMs = 60000;
/// Sample types the iPhone wants forwarded (FE21 SET_TYPES). null/empty = all.
Set<HealthSample_Type>? _healthTypes;
/// Whether the app is in the foreground (resumed). SET_INTERVAL_MS only restarts
/// the timer while resumed, to honor the pause/cancel lifecycle discipline.
bool _appResumed = true;
/// Monotonic sequence for outbound HealthFrames (W9). Wraps at 2^32 so the phone
/// can order/dedup frames; previously hardcoded 0 so dedup was non-functional.
int _healthFrameSeq = 0;

Future<void> main() async {
  // Binding must be initialized before any platform-channel use; channel
  // constructors below call EventChannel.receiveBroadcastStream().listen().
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Construct ALL state + channels synchronously BEFORE runApp so the
  //    first frame never hits an unassigned late final global (the prior
  //    black-screen root cause: healthSignal was built after runApp, so
  //    ConnectionScreen.build threw LateInitializationError on frame 1).
  bleSignal = BleSignal();
  callSignal = CallSignal();
  notificationSignal = NotificationSignal();
  musicSignal = MusicSignal();

  bleCentralChannel = BleCentralChannel();
  gattCentral = GattCentralClient(channel: bleCentralChannel);
  healthChannel = HealthServicesChannel();
  healthSignal = HealthSignal(healthChannel);

  // 2. Render UI immediately. ConnectionScreen reads only the globals above,
  //    all now initialized, so the first frame is safe.
  runApp(const WearLinkApp());

  // 3. Background async init: native BLE central scanner + health collector
  //    start. UI is already on screen, so any dialogs overlay a rendered app.
  try {
    gattCentral.start(
      onFrame: (uuid, payload) {
        bleSignal.setFrame(uuid, payload);
        if (uuid == GattCentralUuid.linkControl) {
          _handleLinkControl(payload);
          return;
        }
        if (uuid == GattCentralUuid.healthControl) {
          _handleHealthControl(payload);
          return;
        }
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
      onMtu: (mtu) => debugPrint('BLE MTU negotiated=$mtu'),
      onError: (msg) => debugPrint('BLE error: $msg'),
    );

    musicSignal.gatt = gattCentral;
    notificationSignal.gattClient = gattCentral;

    // Health perms (BODY_SENSORS + ACTIVITY_RECOGNITION) gate HR/steps capture.
    await healthChannel.requestPermissions();
    healthSignal.start();

    _startHealthTimer();
    await _refreshDeviceInfo();
  } catch (e) {
    debugPrint('Critical init failure: $e');
  }
}

/// Handle an inbound LinkControl (FE60) frame from the iPhone. iOS originates
/// heartbeats; we answer each with an ACK carrying the matching seq so iOS can
/// confirm the link is alive. ACKs/NACKs are not re-acknowledged (no pingpong).
void _handleLinkControl(Uint8List payload) async {
  try {
    final lc = LinkControl.fromBuffer(payload);
    if (lc.kind == LinkControl_Kind.HEARTBEAT) {
      final ack = LinkControl(kind: LinkControl_Kind.ACK, seq: lc.seq);
      await gattCentral.send(
        GattCentralUuid.linkControl,
        Uint8List.fromList(ack.writeToBuffer()),
      );
    }
  } catch (_) {
    // Malformed LinkControl -- liveness simply isn't confirmed this round.
  }
}

/// Apply an inbound HealthControl (FE21) command from the iPhone. The phone
/// configures our capture: SET_INTERVAL_MS paces the broadcast, SET_TYPES filters
/// which samples we forward, SEND_NOW flushes immediately, and START/STOP_ACTIVE
/// toggles high-rate HR capture.
void _handleHealthControl(Uint8List payload) async {
  try {
    final ctrl = HealthControl.fromBuffer(payload);
    switch (ctrl.command) {
      case HealthControl_Command.SEND_NOW:
        _flushHealth();
        break;
      case HealthControl_Command.SET_INTERVAL_MS:
        if (ctrl.intervalMs > 0) {
          _healthIntervalMs = ctrl.intervalMs;
          if (_appResumed) _startHealthTimer();
        }
        break;
      case HealthControl_Command.SET_TYPES:
        _healthTypes = {...ctrl.types};
        break;
      case HealthControl_Command.START_ACTIVE:
        await healthChannel.startActive();
        break;
      case HealthControl_Command.STOP_ACTIVE:
        await healthChannel.stopActive();
        break;
      default:
        break;
    }
  } catch (_) {
    // Malformed HealthControl -- ignore; the phone re-sends config on next connect.
  }
}

/// Start (or restart) the health broadcast timer at the current interval.
void _startHealthTimer() {
  _healthTimer?.cancel();
  _healthTimer = Timer.periodic(Duration(milliseconds: _healthIntervalMs), (_) {
    _refreshDeviceInfo();
    _flushHealth();
  });
}

/// Drain the health buffer and push a HealthFrame to the phone (FE20), filtered
/// to the types the iPhone requested (if any). No-op when not connected or empty.
void _flushHealth() {
  if (bleSignal.connection.value != ConnState.connected) return;
  var samples = healthSignal.drainBuffer();
  final types = _healthTypes;
  if (types != null && types.isNotEmpty) {
    samples = samples.where((s) => types.contains(s.type)).toList();
  }
  if (samples.isEmpty) return;
  final seq = _healthFrameSeq;
  _healthFrameSeq = (_healthFrameSeq + 1) & 0xFFFFFFFF;
  final frame = HealthFrame(sequence: seq, samples: samples, compressed: false);
  gattCentral.send(GattCentralUuid.healthStream, Uint8List.fromList(frame.writeToBuffer()));
}

/// Build a framed DeviceInfo protobuf from native device facts and cache it on
/// the Kotlin side for the next FE10 read. Called at startup and on each health
/// timer tick so the battery reading stays fresh.
Future<void> _refreshDeviceInfo() async {
  try {
    final info = await bleCentralChannel.requestMtu(247);
    // DeviceInfo is served by the peripheral; in central mode we read it
    // from the remote device info characteristic instead of caching locally.
    // For now, log the negotiated MTU as a connectivity check.
    debugPrint('BLE MTU after request: $info');
  } catch (_) {
    // Native channel not ready yet -- retried on the next health tick.
  }
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
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _appResumed = false;
      _healthTimer?.cancel();
      _healthTimer = null;
    } else if (state == AppLifecycleState.resumed) {
      _appResumed = true;
      _startHealthTimer();
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
            // 1. BLE Connection Status Indicator
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
                      Icon(connIcon, size: 20, color: connColor),
                      const SizedBox(width: 8),
                      Text(
                        connText,
                        style: theme.textTheme.labelSmall?.copyWith(color: connColor, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            // 2. Primary Action Chip
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ActionChip(
                label: const Text("Quick Sync", style: TextStyle(color: Colors.white)),
                backgroundColor: Colors.teal,
                onPressed: () async {
                  // Force-reconnect the native BLE central scanner,
                  // refresh the DeviceInfo payload, and push any buffered health
                  // samples. This is the manual recovery path when the auto-start
                  // path fails.
                  try {
                    await gattCentral.reconnect();
                    await _refreshDeviceInfo();
                    _flushHealth();
                  } catch (e) {
                    debugPrint('Quick Sync failed: $e');
                  }
                },
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              ),
            ),
            const SizedBox(height: 12),
            // 3. Live Health Stats Card
            SignalBuilder(
              builder: (context) {
                final steps = healthSignal.steps.value;
                final hr = healthSignal.heartRate.value;

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A2E),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.teal.withValues(alpha: 0.3), width: 1),
                    ),
                    child: Column(
                      children: [
                        Text("Daily Activity", style: theme.textTheme.labelSmall?.copyWith(color: Colors.tealAccent)),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _StatItem(label: "Steps", value: steps.toString(), icon: Icons.directions_walk),
                            const VerticalDivider(color: Colors.grey),
                            _StatItem(label: "HR", value: "$hr BPM", icon: Icons.favorite),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            // 4. Feature Navigation
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                children: [
                  _FeatureCard(
                    icon: Icons.favorite,
                    label: 'Health',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => HealthScreen(health: healthSignal)),
                    ),
                  ),
                  _FeatureCard(
                    icon: Icons.phone,
                    label: 'Calls',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => CallScreen(callSignal: callSignal, gattClient: gattCentral)),
                    ),
                  ),
                  _FeatureCard(
                    icon: Icons.notifications,
                    label: 'Notifications',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => NotificationScreen(notifSignal: notificationSignal)),
                    ),
                  ),
                  _FeatureCard(
                    icon: Icons.music_note,
                    label: 'Music',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => MusicScreen(music: musicSignal)),
                    ),
                  ),
                  const SizedBox(height: 24), // Bezel padding
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _StatItem({required this.label, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, size: 16, color: Colors.tealAccent),
        Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
      ],
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
