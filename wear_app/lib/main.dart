import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
          secondary: const Color(0xFF14E5B3),
          surface: const Color(0xFF0D0D1A),
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
/// Top: animated BLE connection status banner + Quick Sync button.
/// Body: health stats card + scrollable list of feature cards.
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
    // Haptic feedback on connection state changes (skip the initial value).
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Detect round screen via shortest side; round watches are ~280-320 logical px.
    final isRound = MediaQuery.of(context).size.shortestSide < 340;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        minimum: EdgeInsets.all(isRound ? 6 : 8),
        child: Column(
          children: [
            // 1. Top row: connection status banner + Quick Sync button
            Row(
              children: [
                const Expanded(child: _ConnectionBanner()),
                const SizedBox(width: 6),
                const _QuickSyncButton(),
              ],
            ),
            SizedBox(height: isRound ? 6 : 8),
            // 2. Live Health Stats Card
            SignalBuilder(
              builder: (context) {
                final steps = healthSignal.steps.value;
                final hr = healthSignal.heartRate.value;

                return Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(isRound ? 8 : 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D0D1A),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: const Color(0xFF14E5B3).withValues(alpha: 0.25),
                      width: 1,
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        "Daily Activity",
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: const Color(0xFF14E5B3),
                          letterSpacing: 0.5,
                        ),
                      ),
                      SizedBox(height: isRound ? 4 : 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _StatItem(
                            label: "Steps",
                            value: steps.toStringAsFixed(0),
                            icon: Icons.directions_walk,
                          ),
                          Container(
                            width: 1,
                            height: isRound ? 24 : 28,
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                          _StatItem(
                            label: "HR",
                            value: "${hr?.toStringAsFixed(0) ?? '--'} BPM",
                            icon: Icons.favorite,
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
            SizedBox(height: isRound ? 6 : 8),
            // 3. Feature Navigation
            Expanded(
              child: ListView(
                padding: EdgeInsets.only(bottom: isRound ? 12 : 16),
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Connection status banner
// ---------------------------------------------------------------------------

/// Animated full-width banner showing BLE connection state with color coding.
/// Uses a checkmark icon for connected, pulsing background for connecting,
/// and a glow effect for the connected state.
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

        // Connecting state: pulse the entire banner background.
        if (conn == ConnState.connecting) {
          return _ConnectingBanner(color: bannerColor, icon: icon, text: text);
        }

        return AnimatedContainer(
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: bannerColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: bannerColor.withValues(alpha: 0.35)),
            boxShadow: conn == ConnState.connected
                ? [
                    BoxShadow(
                      color: bannerColor.withValues(alpha: 0.3),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: [
              Icon(icon, size: 15, color: bannerColor),
              const SizedBox(width: 6),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: child,
                  ),
                  child: Text(
                    text,
                    key: ValueKey(text),
                    style: TextStyle(
                      color: bannerColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
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

/// Pulsing banner for the connecting state: background color, icon, and text
/// all pulse together with a smooth opacity animation.
class _ConnectingBanner extends StatefulWidget {
  final Color color;
  final IconData icon;
  final String text;

  const _ConnectingBanner({
    required this.color,
    required this.icon,
    required this.text,
  });

  @override
  State<_ConnectingBanner> createState() => _ConnectingBannerState();
}

class _ConnectingBannerState extends State<_ConnectingBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.08, end: 0.25).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulseAnim,
      builder: (context, _) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: _pulseAnim.value),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.color.withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            children: [
              _PulsingIcon(icon: widget.icon, color: widget.color),
              const SizedBox(width: 6),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: child,
                  ),
                  child: Text(
                    widget.text,
                    key: ValueKey(widget.text),
                    style: TextStyle(
                      color: widget.color,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
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

/// Pulsing opacity animation for the connecting-state icon.
class _PulsingIcon extends StatefulWidget {
  final IconData icon;
  final Color color;

  const _PulsingIcon({required this.icon, required this.color});

  @override
  State<_PulsingIcon> createState() => _PulsingIconState();
}

class _PulsingIconState extends State<_PulsingIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _animation = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) => Opacity(
        opacity: _animation.value,
        child: child,
      ),
      child: Icon(widget.icon, size: 15, color: widget.color),
    );
  }
}

// ---------------------------------------------------------------------------
// Quick Sync button
// ---------------------------------------------------------------------------

/// Compact icon button in the top-right corner that forces a BLE reconnect.
/// Shows a loading spinner while the reconnect is in flight.
class _QuickSyncButton extends StatefulWidget {
  const _QuickSyncButton();

  @override
  State<_QuickSyncButton> createState() => _QuickSyncButtonState();
}

class _QuickSyncButtonState extends State<_QuickSyncButton> {
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 34,
      height: 34,
      child: IconButton(
        padding: EdgeInsets.zero,
        icon: _loading
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Color(0xFF14E5B3),
                ),
              )
            : const Icon(Icons.refresh, size: 18, color: Color(0xFF14E5B3)),
        onPressed: _loading ? null : _onSync,
        style: IconButton.styleFrom(
          backgroundColor: const Color(0xFF0D0D1A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(9),
            side: BorderSide(
              color: const Color(0xFF14E5B3).withValues(alpha: 0.25),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _onSync() async {
    setState(() => _loading = true);
    try {
      await gattCentral.reconnect();
      await _refreshDeviceInfo();
      _flushHealth();
    } catch (e) {
      debugPrint('Quick Sync failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}

// ---------------------------------------------------------------------------
// Health stat item
// ---------------------------------------------------------------------------

class _StatItem extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _StatItem({required this.label, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, size: 13, color: const Color(0xFF14E5B3)),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        Text(
          label,
          style: const TextStyle(fontSize: 9, color: Colors.grey),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Feature card
// ---------------------------------------------------------------------------

/// A compact, rounded feature card with a teal circular icon, label, and chevron.
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
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: const Color(0xFF0D0D1A),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            child: Row(
              children: [
                // Teal circular icon
                Container(
                  width: 36,
                  height: 36,
                  decoration: const BoxDecoration(
                    color: Color(0xFF14E5B3),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: const Color(0xFF050508), size: 18),
                ),
                const SizedBox(width: 10),
                // Feature label
                Text(
                  label,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: Colors.white,
                    fontSize: 15,
                  ),
                ),
                const Spacer(),
                // Chevron indicator
                Icon(
                  Icons.chevron_right,
                  color: const Color(0xFF14E5B3).withValues(alpha: 0.6),
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
