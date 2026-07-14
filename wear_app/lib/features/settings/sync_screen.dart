import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:wear_app/signals/ble_signal.dart';

/// Sync status screen showing connection state, pending data, and manual sync.
/// Simplified to show only essential info + one big Sync Now button.
class SyncScreen extends StatelessWidget {
  final Signal<String?> deviceName;
  final Signal<ConnState> connection;
  final Signal<int> pendingCount;
  final Signal<int> lastSyncTimestamp;
  final VoidCallback onSync;

  const SyncScreen({
    super.key,
    required this.deviceName,
    required this.connection,
    required this.pendingCount,
    required this.lastSyncTimestamp,
    required this.onSync,
  });

  String _formatTimestamp(int ms) {
    if (ms <= 0) return 'Never';
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = now - ms;
    if (diff < 60000) return 'Just now';
    if (diff < 3600000) return '${diff ~/ 60000}m ago';
    if (diff < 86400000) return '${diff ~/ 3600000}h ago';
    return '${diff ~/ 86400000}d ago';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050508),
      appBar: AppBar(
        title: const Text('Sync Data'),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Column(
            children: [
              // Connection status card
              SignalBuilder(
                builder: (context) {
                  final connected = connection.value == ConnState.connected;
                  final name = deviceName.value ?? '';
                  final stateColor = connected
                      ? const Color(0xFF00E676)
                      : const Color(0xFFFF5252);
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          stateColor.withValues(alpha: 0.1),
                          const Color(0xFF151525),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: stateColor.withValues(alpha: 0.25),
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: stateColor,
                            boxShadow: [
                              BoxShadow(
                                color: stateColor.withValues(alpha: 0.5),
                                blurRadius: 4,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              connected
                                  ? (name.isNotEmpty
                                      ? 'Connected to $name'
                                      : 'Connected')
                                  : 'Disconnected',
                              style: TextStyle(
                                color: stateColor,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              // Pending count + last sync card
              SignalBuilder(
                builder: (context) {
                  final pending = pendingCount.value;
                  final lastSync = lastSyncTimestamp.value;
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [
                          Color(0xFF0D0D1A),
                          Color(0xFF151525),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.06),
                      ),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Pending',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: 13,
                              ),
                            ),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                '$pending samples',
                                style: TextStyle(
                                  color: pending > 0
                                      ? Colors.orange
                                      : const Color(0xFF00E676),
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Last sync',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: 13,
                              ),
                            ),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                _formatTimestamp(lastSync),
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              // Big Sync Now button
              SignalBuilder(
                builder: (context) {
                  final connected = connection.value == ConnState.connected;
                  final pending = pendingCount.value;
                  return SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: connected && pending > 0 ? onSync : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF14E5B3),
                        foregroundColor: const Color(0xFF00382A),
                        disabledBackgroundColor:
                            Colors.white.withValues(alpha: 0.05),
                        disabledForegroundColor:
                            Colors.white.withValues(alpha: 0.2),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          pending > 0 ? 'Sync Now ($pending)' : 'All Synced',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
