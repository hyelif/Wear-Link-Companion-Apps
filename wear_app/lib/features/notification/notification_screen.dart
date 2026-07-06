import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:wear_app/gen/wearlink.pb.dart';
import 'package:wear_app/signals/notification_signal.dart';

/// Watch notification list screen with circular card design for Galaxy Watch 7.
///
/// States:
///   Empty  – "No notifications" centered message.
///   List   – Scrollable list of notification cards.
///   Detail – Tapped card expands to show full body + reply options.
class NotificationScreen extends StatelessWidget {
  final NotificationSignal notifSignal;

  const NotificationScreen({super.key, required this.notifSignal});

  @override
  Widget build(BuildContext context) {
    final list = watchSignal(context, notifSignal.notifications);

    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: list.isEmpty ? _buildEmpty(context) : _buildList(context, list),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.notifications_none_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              'No notifications',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'You\'re all caught up',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context, List<NotifInfo> list) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      itemCount: list.length,
      itemBuilder: (context, index) {
        final info = list[index];
        return _NotificationCard(
          key: ValueKey(info.notifId),
          info: info,
          onDismiss: () => notifSignal.dismiss(info.notifId),
          onReply: (choice) {
            notifSignal.sendAction(NotifAction(
              notifId: info.notifId,
              action: NotifAction_Action.REPLY,
              replyText: choice,
            ));
          },
        );
      },
    );
  }
}

class _NotificationCard extends StatefulWidget {
  final NotifInfo info;
  final VoidCallback onDismiss;
  final ValueChanged<String> onReply;

  const _NotificationCard({
    super.key,
    required this.info,
    required this.onDismiss,
    required this.onReply,
  });

  @override
  State<_NotificationCard> createState() => _NotificationCardState();
}

class _NotificationCardState extends State<_NotificationCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Dismissible(
      key: ValueKey('dismiss_${info.notifId}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Icon(Icons.delete_outline, color: colorScheme.onErrorContainer),
      ),
      onDismissed: (_) => widget.onDismiss(),
      child: GestureDetector(
        onTap: () => setState(() => _expanded = !_expanded),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // --- Top row: app name + timestamp ---
                Row(
                  children: [
                    Icon(Icons.circle, size: 8, color: _appColor(info.appName)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        info.appName,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      _formatTimestamp(info.timestampMs),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),

                // --- Title ---
                Text(
                  info.title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),

                // --- Body (truncated or full) ---
                Text(
                  info.body,
                  style: theme.textTheme.bodySmall,
                  maxLines: _expanded ? null : 2,
                  overflow: _expanded ? null : TextOverflow.ellipsis,
                ),

                // --- Expanded section: reply options ---
                if (_expanded && info.replyChoices.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  Text(
                    'Reply',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  ...info.replyChoices.map(
                    (choice) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                          onPressed: () => widget.onReply(choice),
                          child: Text(
                            choice,
                            style: theme.textTheme.bodySmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],

                // --- Collapsed hint: reply badge ---
                if (!_expanded && info.replyChoices.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        Icon(
                          Icons.reply_outlined,
                          size: 12,
                          color: colorScheme.primary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${info.replyChoices.length} quick repl${info.replyChoices.length == 1 ? 'y' : 'ies'}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatTimestamp(int ms) {
    final diff = DateTime.now().millisecondsSinceEpoch - ms;
    if (diff < 60000) return 'now';
    if (diff < 3600000) return '${diff ~/ 60000}m';
    if (diff < 86400000) return '${diff ~/ 3600000}h';
    return '${diff ~/ 86400000}d';
  }

  Color _appColor(String appName) {
    // Deterministic color from app name.
    final hash = appName.hashCode;
    const colors = [
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.pink,
      Colors.indigo,
      Colors.amber,
    ];
    return colors[hash.abs() % colors.length];
  }
}
