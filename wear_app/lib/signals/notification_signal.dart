import 'dart:async';
import 'dart:typed_data';

import 'package:signals/signals.dart';
import 'package:wear_app/ble/gatt_client.dart';
import 'package:wear_app/gen/wearlink.pb.dart';

/// Data class representing a notification pushed from the phone
/// (ANCS or WearLink notification characteristic).
class NotifInfo {
  final String notifId;
  final String appName;
  final String title;
  final String body;
  final int timestampMs;
  final List<String> replyChoices;

  const NotifInfo({
    required this.notifId,
    required this.appName,
    required this.title,
    required this.body,
    required this.timestampMs,
    this.replyChoices = const [],
  });

  NotifInfo copyWith({
    String? notifId,
    String? appName,
    String? title,
    String? body,
    int? timestampMs,
    List<String>? replyChoices,
  }) {
    return NotifInfo(
      notifId: notifId ?? this.notifId,
      appName: appName ?? this.appName,
      title: title ?? this.title,
      body: body ?? this.body,
      timestampMs: timestampMs ?? this.timestampMs,
      replyChoices: replyChoices ?? this.replyChoices,
    );
  }

  factory NotifInfo.fromProto(Notification proto) {
    return NotifInfo(
      notifId: proto.notifId,
      appName: proto.appName,
      title: proto.title,
      body: proto.body,
      timestampMs: proto.timestampMs.toInt(),
      replyChoices: proto.replyChoices,
    );
  }
}

/// Notification state store. Receives inbound BLE frames from the
/// Notification characteristic and exposes them as reactive signals.
///
/// Usage:
/// ```dart
/// final notifSignal = NotificationSignal();
/// notifSignal.listen(gatt, GattUuid.notification);
/// // or feed frames directly:
/// notifSignal.updateFromFrame(uuid, data);
/// ```
class NotificationSignal {
  /// Active notifications, newest first.
  final notifications = signal<List<NotifInfo>>([], options: SignalOptions(name: 'notifications'));

  /// Number of unread (active) notifications.
  final unreadCount = signal<int>(0, options: SignalOptions(name: 'unreadCount'));

  /// GattClient for outbound action writes. Set via [listen] or directly.
  GattClient? _gatt;

  /// Set the GattClient instance for outbound writes.
  set gattClient(GattClient client) => _gatt = client;

  StreamSubscription<Uint8List>? _sub;

  /// Start listening to inbound frames on [uuid] (typically
  /// [GattUuid.notification]). Also sets [gatt] for outbound writes.
  void listen(GattClient client, String uuid) {
    _gatt = client;
    _sub?.cancel();
    _sub = client.inbound(uuid).listen(_onFrame);
  }

  /// Process an inbound BLE frame directly. [uuid] is the characteristic
  /// the frame arrived on; only [GattUuid.notification] is handled.
  void updateFromFrame(String uuid, Uint8List data) {
    if (uuid == GattUuid.notification) {
      _onFrame(data);
    }
  }

  /// Send a [NotifAction] to the phone via the notification action
  /// characteristic ([GattUuid.notificationAction]).
  Future<void> sendAction(NotifAction action) async {
    final client = _gatt;
    if (client == null) return;
    // Replay-protection nonce (W7). Matches CallAction's convention.
    action.nonce = DateTime.now().millisecondsSinceEpoch & 0xffff;
    final payload = action.writeToBuffer();
    await client.send(GattUuid.notificationAction, payload);
  }

  /// Dismiss the notification identified by [id]: remove it from the local
  /// list and send a DISMISS action to the phone.
  Future<void> dismiss(String id) async {
    final list = [...notifications.value];
    list.removeWhere((n) => n.notifId == id);
    notifications.value = list;

    await sendAction(NotifAction(
      notifId: id,
      action: NotifAction_Action.DISMISS,
    ));
  }

  void _onFrame(Uint8List data) {
    final proto = Notification.fromBuffer(data);
    final info = NotifInfo.fromProto(proto);

    final list = [...notifications.value];
    final idx = list.indexWhere((n) => n.notifId == info.notifId);
    if (idx >= 0) {
      list[idx] = info;
    } else {
      list.insert(0, info);
    }
    notifications.value = list;
    unreadCount.value = list.length;
  }

  void dispose() {
    _sub?.cancel();
  }
}
