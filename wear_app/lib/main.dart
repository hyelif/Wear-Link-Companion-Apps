import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import 'package:wear_app/ble/gatt_client.dart';
import 'package:wear_app/ble/packet_codec.dart';
import 'package:wear_app/features/call/call_screen.dart';
import 'package:wear_app/features/health/health_screen.dart';
import 'package:wear_app/features/music/music_screen.dart';
import 'package:wear_app/features/notification/notification_screen.dart';
import 'package:wear_app/platform/ble_peripheral_channel.dart';
import 'package:wear_app/platform/health_services_channel.dart';
import 'package:wear_app/signals/ble_signal.dart';
import 'package:wear_app/signals/call_signal.dart';
import 'package:wear_app/signals/health_signal.dart';
import 'package:wear_app/signals/music_signal.dart';
import 'package:wear_app/signals/notification_signal.dart';
import 'package:wear_app/gen/wearlink.pb.dart';

late final BleSignal bleSignal;
late final BlePeripheralChannel bleChannel;
late final GattClient gatt;
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
  bleSignal = BleSignal();
  callSignal = CallSignal();
  notificationSignal = NotificationSignal();
  musicSignal = MusicSignal();

  bleChannel = BlePeripheralChannel();
  gatt = GattClient(channel: bleChannel);

  // Wear OS 3+ / API 31+ requires a runtime grant for the dangerous BLE perms
  // (BLUETOOTH_SCAN/CONNECT/ADVERTISE) before the GATT server can run and the
  // advertiser can broadcast. Without it, startAdvertising() silently fails
  // (onStartFailure) and the watch is invisible to the iPhone. Must be awaited
  // before gatt.start() (which calls channel.start() + advertiseStart()).
  await bleChannel.requestPermissions();

  gatt.start(
    onFrame: (uuid, payload) {
      bleSignal.setFrame(uuid, payload);
      if (uuid == GattUuid.linkControl) {
        _handleLinkControl(payload);
        return;
      }
      if (uuid == GattUuid.healthControl) {
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
  );

  musicSignal.gatt = gatt;
  notificationSignal.gattClient = gatt;

  // Wear OS 3+ requires a runtime grant for BODY_SENSORS (HR) + ACTIVITY_RECOGNITION
  // (steps/calories/distance). Request before starting collection, otherwise
  // HealthCollector.start() silently no-ops on a fresh install (W4).
  healthChannel = HealthServicesChannel();
  healthSignal = HealthSignal(healthChannel);
  await healthChannel.requestPermissions();
  healthSignal.start();

  // Broadcast health data to the phone on the configured interval (default 60 s).
  _startHealthTimer();

  // Cache a framed DeviceInfo protobuf before the iPhone can connect, so the
  // FE10 read on discovery returns a decodable frame (not raw ASCII).
  await _refreshDeviceInfo();

  runApp(const WearLinkApp());
}

/// Handle an inbound LinkControl (FE60) frame from the iPhone. iOS originates
/// heartbeats; we answer each with an ACK carrying the matching seq so iOS can
/// confirm the link is alive. ACKs/NACKs are not re-acknowledged (no pingpong).
void _handleLinkControl(Uint8List payload) async {
  try {
    final lc = LinkControl.fromBuffer(payload);
    if (lc.kind == LinkControl_Kind.HEARTBEAT) {
      final ack = LinkControl(kind: LinkControl_Kind.ACK, seq: lc.seq);
      await gatt.send(
        GattUuid.linkControl,
        Uint8List.fromList(ack.writeToBuffer()),
      );
    }
  } catch (_) {
    // Malformed LinkControl — liveness simply isn't confirmed this round.
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
    // Malformed HealthControl — ignore; the phone re-sends config on next connect.
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
  gatt.send(GattUuid.healthStream, Uint8List.fromList(frame.writeToBuffer()));
}

/// Build a framed DeviceInfo protobuf from native device facts and cache it on
/// the Kotlin side for the next FE10 read. Called at startup and on each health
/// timer tick so the battery reading stays fresh.
Future<void> _refreshDeviceInfo() async {
  try {
    final info = await bleChannel.getDeviceInfo();
    final proto = DeviceInfo(
      model: (info['model'] as String?) ?? '',
      firmware: (info['firmware'] as String?) ?? '',
      batteryPercent: (info['battery'] as int?) ?? 0,
      preferredMtu: (info['mtu'] as int?) ?? 247,
    );
    final payload = Uint8List.fromList(proto.writeToBuffer());
    final frame = PacketCodec.encode(
      seq: 0,
      continuation: false,
      payload: payload,
    );
    await bleChannel.setDeviceInfo(frame);
  } catch (_) {
    // Native channel not ready yet — retried on the next health tick.
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
