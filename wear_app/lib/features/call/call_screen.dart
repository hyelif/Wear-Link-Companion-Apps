import 'dart:async';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:wear_app/ble/gatt_central_client.dart';
import 'package:wear_app/gen/wearlink.pb.dart';
import 'package:wear_app/signals/call_signal.dart';

/// Call screen for Galaxy Watch 7 (circular 480x480).
///
/// Renders one of four states based on [CallSignal]:
///   - Idle: "No active call" message
///   - Incoming: Caller name (large), accept (green) + reject (red) buttons, mute toggle
///   - Active: Caller name, duration timer, end call (red) + mute buttons
///   - Outgoing: "Calling..." with cancel button
class CallScreen extends StatelessWidget {
  final CallSignal callSignal;
  final GattCentralClient gattClient;

  const CallScreen({
    super.key,
    required this.callSignal,
    required this.gattClient,
  });

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
    final incoming = callSignal.incomingCall.value;
    final active = callSignal.callActive.value;
    final muted = callSignal.muted.value;
    final outgoing = callSignal.outgoing.value;
    final callerName = callSignal.callerName.value;

    Widget body;
    if (outgoing) {
      body = _OutgoingView(
        onCancel: () =>
            callSignal.sendAction(gattClient, CallAction_Action.END),
      );
    } else if (incoming != null) {
      body = _IncomingView(
        caller: incoming.caller,
        muted: muted,
        onAccept: () =>
            callSignal.sendAction(gattClient, CallAction_Action.ACCEPT),
        onReject: () =>
            callSignal.sendAction(gattClient, CallAction_Action.REJECT),
        onToggleMute: () =>
            callSignal.sendAction(gattClient, CallAction_Action.MUTE),
      );
    } else if (active) {
      body = _ActiveView(
        caller: callerName ?? 'Active Call',
        muted: muted,
        onEnd: () =>
            callSignal.sendAction(gattClient, CallAction_Action.END),
        onToggleMute: () =>
            callSignal.sendAction(gattClient, CallAction_Action.MUTE),
      );
    } else {
      body = const _IdleView();
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(child: body),
    );
      },
    );
  }
}

/// Idle state -- no active call.
class _IdleView extends StatelessWidget {
  const _IdleView();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.phone, size: 48, color: Colors.grey[600]),
        const SizedBox(height: 12),
        Text(
          'No active call',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Colors.grey[500],
              ),
        ),
      ],
    );
  }
}

/// Incoming call state -- caller name, accept/reject, mute.
class _IncomingView extends StatelessWidget {
  final String caller;
  final bool muted;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final VoidCallback onToggleMute;

  const _IncomingView({
    required this.caller,
    required this.muted,
    required this.onAccept,
    required this.onReject,
    required this.onToggleMute,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Incoming',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Colors.grey[400],
                ),
          ),
          const SizedBox(height: 8),
          Text(
            caller,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ActionButton(
                icon: muted ? Icons.volume_off : Icons.volume_up,
                color: Colors.grey[700]!,
                onPressed: onToggleMute,
                label: 'Mute',
              ),
              const SizedBox(width: 16),
              _ActionButton(
                icon: Icons.call,
                color: Colors.green,
                onPressed: onAccept,
                label: 'Accept',
                size: 64,
              ),
              const SizedBox(width: 16),
              _ActionButton(
                icon: Icons.call_end,
                color: Colors.red,
                onPressed: onReject,
                label: 'Reject',
                size: 64,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Active call state -- caller name, duration timer, end + mute.
class _ActiveView extends StatelessWidget {
  final String caller;
  final bool muted;
  final VoidCallback onEnd;
  final VoidCallback onToggleMute;

  const _ActiveView({
    required this.caller,
    required this.muted,
    required this.onEnd,
    required this.onToggleMute,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            caller,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          const _CallTimer(),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ActionButton(
                icon: muted ? Icons.volume_off : Icons.volume_up,
                color: muted ? Colors.orange : Colors.grey[700]!,
                onPressed: onToggleMute,
                label: muted ? 'Unmute' : 'Mute',
              ),
              const SizedBox(width: 24),
              _ActionButton(
                icon: Icons.call_end,
                color: Colors.red,
                onPressed: onEnd,
                label: 'End',
                size: 64,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Outgoing call state -- "Calling..." spinner with cancel button.
class _OutgoingView extends StatelessWidget {
  final VoidCallback onCancel;

  const _OutgoingView({required this.onCancel});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Calling...',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                ),
          ),
          const SizedBox(height: 24),
          _ActionButton(
            icon: Icons.call_end,
            color: Colors.red,
            onPressed: onCancel,
            label: 'Cancel',
            size: 64,
          ),
        ],
      ),
    );
  }
}

/// Circular action button with label, designed for watch touch targets.
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;
  final String label;
  final double size;

  const _ActionButton({
    required this.icon,
    required this.color,
    required this.onPressed,
    required this.label,
    this.size = 56,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size,
          height: size,
          child: Material(
            color: color,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
              child: Icon(icon, color: Colors.white, size: size * 0.45),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Colors.grey[400],
              ),
        ),
      ],
    );
  }
}

/// Elapsed call timer (mm:ss or hh:mm:ss).
class _CallTimer extends StatefulWidget {
  const _CallTimer();

  @override
  State<_CallTimer> createState() => _CallTimerState();
}

class _CallTimerState extends State<_CallTimer> {
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _stopwatch.start();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _stopwatch.stop();
    super.dispose();
  }

  String _format(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '${h.toString().padLeft(2, '0')}:$m:$s';
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _format(_stopwatch.elapsed),
      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            color: Colors.white,
            fontFamily: 'monospace',
          ),
    );
  }
}
