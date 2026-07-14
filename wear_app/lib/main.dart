import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signals/signals_flutter.dart';

import 'package:wear_app/ble/gatt_central_client.dart';
import 'package:wear_app/features/settings/health_types_screen.dart';
import 'package:wear_app/features/settings/sync_screen.dart';
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

/// Health type toggle signals for the settings screen.
/// Each represents whether the user wants that type pushed to iPhone.
final heartRateEnabled = signal<bool>(true);
final stepsEnabled = signal<bool>(true);
final spo2Enabled = signal<bool>(false);
final hrvEnabled = signal<bool>(false);
final sleepEnabled = signal<bool>(true);
final caloriesEnabled = signal<bool>(true);
final distanceEnabled = signal<bool>(true);

/// Timestamp (ms) of the last successful health sync.
final lastSyncTimestamp = signal<int>(0);

/// Initialization error message, or null if init succeeded.
final initError = signal<String?>(null);

/// Build the list of HealthTypeOption for the settings screen.
List<HealthTypeOption> get healthTypeOptions => [
  HealthTypeOption(
    label: 'Heart Rate',
    subtitle: 'BPM readings',
    icon: Icons.favorite,
    protoType: HealthSample_Type.HEART_RATE_BPM,
    enabled: heartRateEnabled,
  ),
  HealthTypeOption(
    label: 'Steps',
    subtitle: 'Step count',
    icon: Icons.directions_walk,
    protoType: HealthSample_Type.STEPS,
    enabled: stepsEnabled,
  ),
  HealthTypeOption(
    label: 'SpO2',
    subtitle: 'Blood oxygen',
    icon: Icons.water_drop,
    protoType: HealthSample_Type.SPO2_PERCENT,
    enabled: spo2Enabled,
  ),
  HealthTypeOption(
    label: 'HRV',
    subtitle: 'Heart rate variability',
    icon: Icons.show_chart,
    protoType: HealthSample_Type.HRV_MS,
    enabled: hrvEnabled,
  ),
  HealthTypeOption(
    label: 'Sleep',
    subtitle: 'Sleep stages & duration',
    icon: Icons.bedtime,
    protoType: HealthSample_Type.SLEEP,
    enabled: sleepEnabled,
  ),
  HealthTypeOption(
    label: 'Calories',
    subtitle: 'kcal burned',
    icon: Icons.local_fire_department,
    protoType: HealthSample_Type.CALORIES,
    enabled: caloriesEnabled,
  ),
  HealthTypeOption(
    label: 'Distance',
    subtitle: 'Meters traveled',
    icon: Icons.map,
    protoType: HealthSample_Type.DISTANCE_METERS,
    enabled: distanceEnabled,
  ),
];

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

  // 3. Background async init: request BLE permissions, then start native BLE
  //    central scanner + health collector. UI is already on screen, so any
  //    dialogs overlay a rendered app.
  try {
    // Request BLUETOOTH_SCAN + BLUETOOTH_CONNECT on Wear OS 3+ (API 31+).
    // Without these grants, the BLE scanner silently fails and the watch
    // cannot find the iPhone. The system shows a permission dialog.
    await bleCentralChannel.requestPermissions();

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
        if (uuid == GattCentralUuid.deviceInfo) {
          _handleDeviceInfo(payload);
          return;
        }
        callSignal.updateFromFrame(uuid, payload);
        notificationSignal.updateFromFrame(uuid, payload);
        musicSignal.updateFromFrame(uuid, payload);
      },
      onConn: (state, {deviceName}) {
        bleSignal.setConn(switch (state) {
          'CONNECTED' => ConnState.connected,
          'CONNECTING' => ConnState.connecting,
          _ => ConnState.disconnected,
        });
        if (deviceName != null) {
          bleSignal.setDeviceName(deviceName);
        }
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
    initError.value = 'Initialization failed. Check Bluetooth permissions.';
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

/// Parse and log an inbound DeviceInfo (FE10) response from the iPhone.
/// Called when the async read of FE10 completes.
void _handleDeviceInfo(Uint8List payload) {
  try {
    final info = DeviceInfo.fromBuffer(payload);
    debugPrint('DeviceInfo: model=${info.model}, '
        'firmware=${info.firmware}, battery=${info.batteryPercent}%');
  } catch (_) {
    // Malformed DeviceInfo -- skip; retried on the next health tick.
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
/// to the types the user has enabled in settings AND the types the iPhone
/// requested (if any). No-op when not connected or empty.
void _flushHealth() {
  if (bleSignal.connection.value != ConnState.connected) return;
  var samples = healthSignal.drainBuffer();
  // Filter by user-enabled health types (settings toggles).
  final enabledTypes = <HealthSample_Type>{};
  if (heartRateEnabled.value) enabledTypes.add(HealthSample_Type.HEART_RATE_BPM);
  if (stepsEnabled.value) enabledTypes.add(HealthSample_Type.STEPS);
  if (spo2Enabled.value) enabledTypes.add(HealthSample_Type.SPO2_PERCENT);
  if (hrvEnabled.value) enabledTypes.add(HealthSample_Type.HRV_MS);
  if (sleepEnabled.value) enabledTypes.add(HealthSample_Type.SLEEP);
  if (caloriesEnabled.value) enabledTypes.add(HealthSample_Type.CALORIES);
  if (distanceEnabled.value) enabledTypes.add(HealthSample_Type.DISTANCE_METERS);
  samples = samples.where((s) => enabledTypes.contains(s.type)).toList();
  // Also filter by iPhone-requested types (FE21 SET_TYPES).
  final types = _healthTypes;
  if (types != null && types.isNotEmpty) {
    samples = samples.where((s) => types.contains(s.type)).toList();
  }
  if (samples.isEmpty) return;
  final seq = _healthFrameSeq;
  _healthFrameSeq = (_healthFrameSeq + 1) & 0xFFFFFFFF;
  final frame = HealthFrame(sequence: seq, samples: samples, compressed: false);
  gattCentral.send(GattCentralUuid.healthStream, Uint8List.fromList(frame.writeToBuffer()));
  lastSyncTimestamp.value = DateTime.now().millisecondsSinceEpoch;
}

/// Read FE10 (deviceInfo) from the iPhone. The result arrives asynchronously
/// via the onFrame callback where it is parsed and logged. Called at startup
/// and on each health timer tick so the battery reading stays fresh.
Future<void> _refreshDeviceInfo() async {
  try {
    await gattCentral.read(GattCentralUuid.deviceInfo);
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
        scaffoldBackgroundColor: const Color(0xFF050508),
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFF14E5B3),
          onPrimary: const Color(0xFF00382A),
          primaryContainer: const Color(0xFF00513D),
          onPrimaryContainer: const Color(0xFF6FFFE0),
          secondary: const Color(0xFF14E5B3),
          onSecondary: const Color(0xFF00382A),
          secondaryContainer: const Color(0xFF00513D),
          onSecondaryContainer: const Color(0xFF6FFFE0),
          surface: const Color(0xFF0D0D1A),
          onSurface: const Color(0xFFE0E0E0),
          surfaceContainerHighest: const Color(0xFF1A1A2E),
          onSurfaceVariant: const Color(0xFFB0B0B0),
          outline: const Color(0xFF3A3A4A),
          outlineVariant: const Color(0xFF2A2A3A),
          error: const Color(0xFFFF5252),
          onError: const Color(0xFF601410),
        ),
        textTheme: TextTheme(
          displayLarge: TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: const Color(0xFFE0E0E0)),
          displayMedium: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: const Color(0xFFE0E0E0)),
          displaySmall: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: const Color(0xFFE0E0E0)),
          headlineLarge: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: const Color(0xFFE0E0E0)),
          headlineMedium: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: const Color(0xFFE0E0E0)),
          headlineSmall: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: const Color(0xFFE0E0E0)),
          titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: const Color(0xFFE0E0E0)),
          titleMedium: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: const Color(0xFFE0E0E0)),
          titleSmall: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: const Color(0xFFE0E0E0)),
          bodyLarge: TextStyle(fontSize: 16, color: const Color(0xFFC0C0C0)),
          bodyMedium: TextStyle(fontSize: 14, color: const Color(0xFFC0C0C0)),
          bodySmall: TextStyle(fontSize: 12, color: const Color(0xFFA0A0A0)),
          labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: const Color(0xFFE0E0E0)),
          labelMedium: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: const Color(0xFFB0B0B0)),
          labelSmall: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: const Color(0xFF909090)),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF0D0D1A),
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          margin: EdgeInsets.zero,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF14E5B3),
            foregroundColor: const Color(0xFF00382A),
            minimumSize: const Size(double.infinity, 48),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
            minimumSize: const Size(34, 34),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return const Color(0xFF14E5B3);
            return const Color(0xFF6B6B6B);
          }),
          trackColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return const Color(0xFF14E5B3).withValues(alpha: 0.4);
            return const Color(0xFF3A3A3A);
          }),
        ),
        dividerTheme: const DividerThemeData(
          color: Color(0xFF2A2A3A),
          space: 12,
        ),
      ),
      home: const ConnectionScreen(),
    );
  }
}

// =============================================================================
// ConnectionScreen — configuration hub
// =============================================================================

/// Home screen for the watch. Acts as a configuration hub with subsystem
/// navigation buttons. No live health stats — the watch is a config panel,
/// not a data display.
class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  bool _firstConnValue = true;
  late final void Function() _connDispose;

  @override
  void initState() {
    super.initState();
    _connDispose = bleSignal.connection.subscribe((_) {
      if (_firstConnValue) {
        _firstConnValue = false;
        return;
      }
      HapticFeedback.mediumImpact();
    });
  }

  @override
  void dispose() {
    _connDispose();
    super.dispose();
  }

  void _showConnectionDialog() {
    showDialog(
      context: context,
      builder: (ctx) => SignalBuilder(
        builder: (_) {
          final conn = bleSignal.connection.value;
          final name = bleSignal.deviceName.value;
          final (stateColor, stateText) = switch (conn) {
            ConnState.connected => (const Color(0xFF00E676), 'Connected'),
            ConnState.connecting => (const Color(0xFFFFD600), 'Connecting...'),
            ConnState.disconnected => (const Color(0xFFFF5252), 'Disconnected'),
          };
          return AlertDialog(
            backgroundColor: const Color(0xFF0D0D1A),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: stateColor.withValues(alpha: 0.3)),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [stateColor.withValues(alpha: 0.2), Colors.transparent],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    conn == ConnState.connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                    size: 24,
                    color: stateColor,
                  ),
                ),
                const SizedBox(height: 12),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    stateText,
                    style: TextStyle(
                      color: stateColor,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (name != null && name.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      name,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF14E5B3),
                      foregroundColor: const Color(0xFF00382A),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0D0D1A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: const Color(0xFF14E5B3).withValues(alpha: 0.2)),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFF14E5B3).withValues(alpha: 0.2),
                    Colors.transparent,
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.watch, size: 24, color: Color(0xFF14E5B3)),
            ),
            const SizedBox(height: 12),
            const FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                'WearLink',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                'Version 0.1.0+1',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                'Wear OS companion app\nfor WearLink iPhone app',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF14E5B3),
                  foregroundColor: const Color(0xFF00382A),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050508),
      body: SafeArea(
        minimum: const EdgeInsets.symmetric(horizontal: 20),
        child: SignalBuilder(
          builder: (_) {
            final err = initError.value;
            final conn = bleSignal.connection.value;

            // --- Error state: init failed ---
            if (err != null) {
              return _ErrorState(
                message: err,
                onRetry: () {
                  initError.value = null;
                  // Re-trigger init by restarting the app's async setup.
                  // For now, just clear the error and let the user re-open.
                },
              );
            }

            // --- Loading state: first connection attempt ---
            if (conn == ConnState.connecting && _firstConnValue) {
              return _LoadingState();
            }

            // --- Empty state: no device paired ---
            if (conn == ConnState.disconnected && _firstConnValue) {
              return _EmptyState();
            }

            // --- Normal state: configuration hub ---
            return Column(
              children: [
                const SizedBox(height: 12),
                // 1. Connection status banner (compact, pushed down)
                const _ConnectionBanner(),
                const SizedBox(height: 12),
                // 2. Scrollable subsystem list
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 12),
                    children: [
                      _SubsystemButton(
                        icon: Icons.favorite,
                        label: 'Health Sync',
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => HealthTypesScreen(options: healthTypeOptions),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      _SubsystemButton(
                        icon: Icons.sync,
                        label: 'Sync Data',
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => SyncScreen(
                              deviceName: bleSignal.deviceName,
                              connection: bleSignal.connection,
                              pendingCount: healthSignal.pendingCount,
                              lastSyncTimestamp: lastSyncTimestamp,
                              onSync: () {
                                _flushHealth();
                                HapticFeedback.heavyImpact();
                              },
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      _SubsystemButton(
                        icon: Icons.bluetooth,
                        label: 'Connection',
                        trailing: SignalBuilder(
                          builder: (_) {
                            final dotConn = bleSignal.connection.value;
                            final dotColor = switch (dotConn) {
                              ConnState.connected => const Color(0xFF00E676),
                              ConnState.connecting => const Color(0xFFFFD600),
                              ConnState.disconnected => const Color(0xFFFF5252),
                            };
                            return Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: dotColor,
                                boxShadow: [
                                  BoxShadow(
                                    color: dotColor.withValues(alpha: 0.5),
                                    blurRadius: 3,
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                        onTap: _showConnectionDialog,
                      ),
                      const SizedBox(height: 6),
                      _SubsystemButton(
                        icon: Icons.info_outline,
                        label: 'About',
                        onTap: _showAboutDialog,
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// =============================================================================
// ConnectionScreen state widgets
// =============================================================================

/// Shown when BLE is initializing for the first time.
class _LoadingState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(
            strokeWidth: 3,
            color: Color(0xFF14E5B3),
          ),
        ),
        const SizedBox(height: 16),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            'Initializing Bluetooth...',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }
}

/// Shown when no iPhone is paired or available.
class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                const Color(0xFFFF5252).withValues(alpha: 0.2),
                Colors.transparent,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.bluetooth_disabled,
            size: 28,
            color: Color(0xFFFF5252),
          ),
        ),
        const SizedBox(height: 16),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            'No iPhone Connected',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 8),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            'Open WearLink on your iPhone\nand ensure Bluetooth is on',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }
}

/// Shown when initialization fails with a retry option.
class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                const Color(0xFFFF5252).withValues(alpha: 0.2),
                Colors.transparent,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.error_outline,
            size: 28,
            color: Color(0xFFFF5252),
          ),
        ),
        const SizedBox(height: 16),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            'Something went wrong',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 12,
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: 160,
          height: 40,
          child: ElevatedButton(
            onPressed: onRetry,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF14E5B3),
              foregroundColor: const Color(0xFF00382A),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              elevation: 0,
            ),
            child: const FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                'Retry',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Connection status banner
// =============================================================================

/// Compact animated banner showing BLE connection state with color coding.
/// Uses FittedBox to auto-size text on round screens.
class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner();

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final conn = bleSignal.connection.value;
        final deviceName = bleSignal.deviceName.value;

        final (bannerColor, icon, text) = switch (conn) {
          ConnState.disconnected => (
            const Color(0xFFFF5252),
            Icons.bluetooth_disabled,
            'Disconnected',
          ),
          ConnState.connecting => (
            const Color(0xFFFFD600),
            Icons.bluetooth_searching,
            'Connecting...',
          ),
          ConnState.connected => (
            const Color(0xFF00E676),
            Icons.check_circle,
            deviceName != null ? 'Connected to $deviceName' : 'Connected',
          ),
        };

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                bannerColor.withValues(alpha: 0.12),
                bannerColor.withValues(alpha: 0.03),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: bannerColor.withValues(alpha: 0.25),
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 16, color: bannerColor),
              const SizedBox(width: 8),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    text,
                    style: TextStyle(
                      color: bannerColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// =============================================================================
// Subsystem button
// =============================================================================

/// A tappable row with a gradient background, circular icon container,
/// label/subtitle, and optional trailing widget. Used for all subsystem
/// navigation in the configuration hub.
///
/// - 44dp minimum height
/// - 24x24dp icon in 44x44dp circular container
/// - Gradient background (not flat)
/// - Subtle shape radius (not pill-shaped)
/// - FittedBox for auto-sizing text
class _SubsystemButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SubsystemButton({
    required this.icon,
    required this.label,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        constraints: const BoxConstraints(minHeight: 40),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [
              Color(0xFF0D0D1A),
              Color(0xFF151525),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.06),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              // Icon in 36x36 circular container
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFF14E5B3).withValues(alpha: 0.2),
                      const Color(0xFF14E5B3).withValues(alpha: 0.05),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 20, color: const Color(0xFF14E5B3)),
              ),
              const SizedBox(width: 10),
              // Label only — no subtitle on watch (saves space)
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // Trailing widget (chevron, status dot, etc.)
              trailing ??
                  Icon(
                    Icons.chevron_right,
                    color: const Color(0xFF14E5B3).withValues(alpha: 0.5),
                    size: 18,
                  ),
            ],
          ),
        ),
      ),
    );
  }
}
