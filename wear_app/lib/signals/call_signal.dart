import 'package:signals/signals.dart';
import 'package:wear_app/ble/gatt_central_client.dart';
import 'package:wear_app/gen/wearlink.pb.dart';

/// Data class representing an incoming call notification from the phone.
class CallInfo {
  final String caller;
  final String callId;
  final bool hasVideo;
  final int timestampMs;

  const CallInfo({
    required this.caller,
    required this.callId,
    required this.hasVideo,
    required this.timestampMs,
  });
}

/// Call state store. Receives [CallEvent] frames from the BLE inbound stream
/// and exposes reactive signals for the UI.
///
/// BLE frames arrive via [GattClient.inbound] on [GattUuid.callEvent]. Call
/// actions are sent back through [GattClient.send] on [GattUuid.callAction].
///
/// Usage:
/// ```dart
/// final callSignal = CallSignal();
/// gattClient.inbound(GattUuid.callEvent).listen(
///   (data) => callSignal.updateFromFrame(GattUuid.callEvent, data),
/// );
/// ```
class CallSignal {
  /// Currently incoming call, or `null` if none.
  final incomingCall = Signal<CallInfo?>(null, options: SignalOptions(name: 'incomingCall'));

  /// Whether a call is currently active (in progress).
  final callActive = Signal<bool>(false, options: SignalOptions(name: 'callActive'));

  /// Whether the microphone is muted during an active call.
  final muted = Signal<bool>(false, options: SignalOptions(name: 'muted'));

  /// Whether the watch is currently placing an outgoing call.
  final outgoing = Signal<bool>(false, options: SignalOptions(name: 'outgoing'));

  /// Persisted caller name, kept across incoming→active transition.
  final callerName = Signal<String?>(null, options: SignalOptions(name: 'callerName'));

  /// Process an inbound BLE frame from the phone.
  ///
  /// [uuid] identifies the GATT characteristic (expected [GattUuid.callEvent]).
  /// [data] is the raw protobuf-encoded [CallEvent] payload.
  void updateFromFrame(String uuid, List<int> data) {
    if (uuid != GattCentralUuid.callEvent) return;

    final event = CallEvent.fromBuffer(data);
    if (event.callId.isEmpty) return;

    if (event.caller.isNotEmpty) {
      // Incoming call notification from the phone.
      incomingCall.value = CallInfo(
        caller: event.caller,
        callId: event.callId,
        hasVideo: event.hasVideo,
        timestampMs: event.timestampMs.toInt(),
      );
      callerName.value = event.caller;
      callActive.value = true;
      muted.value = false;
      outgoing.value = false;
    } else {
      // Call ended or state-clear signal (no caller info).
      incomingCall.value = null;
      callActive.value = false;
      muted.value = false;
      outgoing.value = false;
    }
  }

  /// Send a call action (accept, reject, mute, end) to the phone via BLE.
  ///
  /// [client] is the [GattClient] used to write the action characteristic.
  /// [action] is the action to perform (e.g. [CallAction_Action.ACCEPT]).
  /// [callId] overrides the target call ID; defaults to the current
  /// [incomingCall]'s id, or an empty string if none.
  Future<void> sendAction(
    GattCentralClient client,
    CallAction_Action action, {
    String? callId,
  }) async {
    final id = callId ?? incomingCall.value?.callId ?? '';
    final proto = CallAction(
      callId: id,
      action: action,
      nonce: DateTime.now().millisecondsSinceEpoch & 0xffff,
    );
    await client.send(GattCentralUuid.callAction, proto.writeToBuffer());

    // Optimistically update local state to match the action sent.
    switch (action) {
      case CallAction_Action.ACCEPT:
        callActive.value = true;
        break;
      case CallAction_Action.REJECT:
      case CallAction_Action.END:
        incomingCall.value = null;
        callActive.value = false;
        muted.value = false;
        break;
      case CallAction_Action.MUTE:
        muted.value = !muted.value;
        break;
      case CallAction_Action.ACTION_UNSPECIFIED:
        break;
    }
  }

  /// Reset all state to defaults (e.g. on BLE disconnect).
  void reset() {
    incomingCall.value = null;
    callActive.value = false;
    muted.value = false;
    outgoing.value = false;
    callerName.value = null;
  }
}
