import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signals/signals_flutter.dart';
import 'package:wear_app/signals/ble_signal.dart';

/// Sync status screen showing connection state, pending data, and manual sync.
class SyncScreen extends StatefulWidget {
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

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  bool _isSyncing = false;
  String? _syncError;

  String _formatTimestamp(int ms) {
    if (ms <= 0) return 'Never';
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = now - ms;
    if (diff < 60000) return 'Just now';
    if (diff < 3600000) return '${diff ~/ 60000}m ago';
    if (diff < 86400000) return '${diff ~/ 3600000}h ago';
    return '${diff ~/ 86400000}d ago';
  }

  Future<void> _handleSync() async {
    if (_isSyncing) return;
    setState(() {
      _isSyncing = true;
      _syncError = null;
    });
    try {
      widget.onSync();
      HapticFeedback.heavyImpact();
      // Brief delay so the user sees the syncing state.
      await Future.delayed(const Duration(milliseconds: 600));
    } catch (e) {
      _syncError = 'Sync failed. Try again.';
    } finally {
      if (mounted) {
        setState(() => _isSyncing = false);
      }
    }
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
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: SingleChildScrollView(
            child: Column(
            children: [
              // Connection status card
              SignalBuilder(
                builder: (context) {
                  final connected = widget.connection.value == ConnState.connected;
                  final name = widget.deviceName.value ?? '';
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
                  final pending = widget.pendingCount.value;
                  final lastSync = widget.lastSyncTimestamp.value;
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
              // --- Loading state: sync in progress ---
              if (_isSyncing)
                _SyncProgressIndicator()
              // --- Error state: sync failed ---
              else if (_syncError != null)
                _SyncErrorBanner(
                  message: _syncError!,
                  onDismiss: () => setState(() => _syncError = null),
                )
              // --- Normal state: Sync Now button ---
              else
                SignalBuilder(
                  builder: (context) {
                    final connected = widget.connection.value == ConnState.connected;
                    final pending = widget.pendingCount.value;
                    return SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        onPressed: connected && pending > 0 ? _handleSync : null,
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
      ),
    );
  }
}

/// Shown while sync is in progress.
class _SyncProgressIndicator extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12),
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
          color: const Color(0xFF14E5B3).withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: Color(0xFF14E5B3),
            ),
          ),
          const SizedBox(width: 12),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              'Syncing...',
              style: TextStyle(
                color: const Color(0xFF14E5B3).withValues(alpha: 0.8),
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when sync fails with a dismiss action.
class _SyncErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;

  const _SyncErrorBanner({required this.message, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFFFF5252).withValues(alpha: 0.1),
            const Color(0xFF151525),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFFFF5252).withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 18, color: Color(0xFFFF5252)),
          const SizedBox(width: 8),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                message,
                style: const TextStyle(
                  color: Color(0xFFFF5252),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onDismiss,
            child: Icon(
              Icons.close,
              size: 16,
              color: Colors.white.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }
}
