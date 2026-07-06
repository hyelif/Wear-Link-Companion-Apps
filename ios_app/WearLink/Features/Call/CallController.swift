import Foundation
import CallKit
import Contacts

/// Detects incoming calls (CallKit) and forwards caller info to the watch
/// via `callEvent`. Receives `callAction` (accept/reject/mute/end) from the
/// watch and applies it through CXProvider.
///
/// NOTE: call AUDIO stays on the phone. The watch is a remote control only.
/// See Software-Structure §9.
@MainActor
@Observable
final class CallController: NSObject {
    private let ble: BLEManager
    private let provider: CXProvider
    private let controller = CXCallController()
    private let observer = CXCallObserver()
    private let contactStore = CNContactStore()

    /// Tracks active call UUIDs to avoid re-sending events for the same call.
    private(set) var activeCallIDs = Set<String>()
    /// Name of the most recent incoming caller, if any.
    private(set) var incomingCallerName: String?
    /// Whether there is an incoming call that hasn't been accepted or rejected yet.
    private(set) var hasIncomingCall = false

    init(ble: BLEManager) {
        self.ble = ble

        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = false
        cfg.maximumCallGroups = 1
        cfg.maximumCallsPerCallGroup = 1
        cfg.includesCallsInRecents = true
        self.provider = CXProvider(configuration: cfg)

        super.init()

        provider.setDelegate(self, queue: nil)
        observer.setDelegate(self, queue: nil)

        // Register the BLE handler for incoming CallAction from the watch.
        // If GattClient is not yet available, the handler is set once it connects.
        registerCallActionHandler()
    }

    /// Registers (or re-registers) the CallAction handler on the current GattClient.
    /// Safe to call even when gatt is nil — the handler is set when available.
    private func registerCallActionHandler() {
        ble.gatt?.onPayload[WearLinkUUID.callAction] = { [weak self] data in
            guard let self, let action = ProtoCodec.decodeCallAction(from: data) else { return }
            Task { @MainActor in
                self.applyAction(action)
            }
        }
    }
}

// MARK: - CXCallObserverDelegate

extension CallController: CXCallObserverDelegate {
    nonisolated func callObserver(_ observer: CXCallObserver, callChanged call: CXCall) {
        // Only handle incoming calls that haven't connected or ended yet.
        guard !call.isOutgoing, !call.hasConnected, !call.hasEnded else { return }

        let callId = call.uuid.uuidString

        Task { @MainActor in
            // Deduplicate: skip if we already sent an event for this call.
            guard !self.activeCallIDs.contains(callId) else { return }
            self.activeCallIDs.insert(callId)

            // Ensure the BLE handler is registered (gatt may have connected after init).
            self.registerCallActionHandler()

            // Resolve caller name from contacts.
            let name = await self.contactName(for: call) ?? "Unknown"

            // Update observable state for the UI.
            self.incomingCallerName = name
            self.hasIncomingCall = true

            // Build and send the CallEvent proto to the watch.
            let event = CallEvent(
                callId: callId,
                caller: name,
                hasVideo: false,
                timestampMs: UInt64(Date().timeIntervalSince1970 * 1000)
            )

            let payload = ProtoCodec.encodeCallEvent(event)
            self.ble.gatt?.write(payload, to: WearLinkUUID.callEvent)
        }
    }
}

// MARK: - Contact resolution

extension CallController {
    /// Attempts to resolve the caller's contact name from the system address book.
    /// Returns nil if the caller handle is unavailable or access is denied.
    private func contactName(for call: CXCall) async -> String? {
        let status = CNContactStore.authorizationStatus(for: .contacts)

        switch status {
        case .notDetermined:
            do {
                let granted = try await contactStore.requestAccess(for: .contacts)
                guard granted else { return nil }
            } catch {
                return nil
            }
        case .authorized:
            break
        case .denied, .restricted:
            return nil
        @unknown default:
            return nil
        }

        // CXCall does not expose the remote handle (phone number) through
        // its public API. To obtain the caller number, the app would need to
        // report the call via CXProvider.reportNewIncomingCall() and capture
        // the CXCallUpdate handle, or listen for the underlying telephony
        // notification. Without the handle, CNContactStore lookup is not
        // possible here.
        //
        // Production approach: use CXProvider to report the call and extract
        // the handle from CXCallUpdate, then look up the contact name.
        return nil
    }
}

// MARK: - Watch action handling

extension CallController {
    /// Called when the watch sends a CallAction over BLE.
    /// Maps the action to a CXTransaction and enqueues it with CXCallController.
    func applyAction(_ action: CallAction) {
        guard let callUUID = UUID(uuidString: action.callId) else {
            print("[CallController] Invalid callId in CallAction: \(action.callId)")
            return
        }

        let transaction: CXTransaction

        switch action.action {
        case .accept:
            let answerAction = CXAnswerCallAction(call: callUUID)
            transaction = CXTransaction(action: answerAction)

        case .reject, .end:
            let endAction = CXEndCallAction(call: callUUID)
            transaction = CXTransaction(action: endAction)

        case .mute:
            let muteAction = CXSetMutedCallAction(call: callUUID, muted: true)
            transaction = CXTransaction(action: muteAction)

        case .actionUnspecified:
            print("[CallController] Ignoring CallAction with unspecified action")
            return
        }

        controller.request(transaction) { error in
            if let error = error {
                print("[CallController] CXTransaction failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - CXProviderDelegate

extension CallController: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in
            self.activeCallIDs.removeAll()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        Task { @MainActor in
            self.activeCallIDs.remove(action.call.uuidString)
            if self.activeCallIDs.isEmpty {
                self.hasIncomingCall = false
                self.incomingCallerName = nil
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // Call audio stays on the phone; the watch is a remote control only.
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // No-op: audio is managed by the system.
    }
}
