import Foundation
import CallKit
import AVFoundation

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

    /// Tracks active call UUIDs to avoid re-sending events for the same call.
    private(set) var activeCallIDs = Set<String>()
    /// Name of the most recent incoming caller, if any.
    private(set) var incomingCallerName: String?
    /// Whether there is an incoming call that hasn't been accepted or rejected yet.
    private(set) var hasIncomingCall = false

    init(ble: BLEManager) {
        self.ble = ble

        let cfg = CXProviderConfiguration(localizedName: "WearLink")
        cfg.supportsVideo = false
        cfg.maximumCallGroups = 1
        cfg.maximumCallsPerCallGroup = 1
        cfg.includesCallsInRecents = true
        self.provider = CXProvider(configuration: cfg)

        super.init()

        provider.setDelegate(self, queue: nil)
        observer.setDelegate(self, queue: nil)
    }

    deinit {
        // CXProvider.invalidate() must be called on the main thread.
        // Capture the provider value; deinit is not actor-isolated.
        let p = provider
        Task { @MainActor in
            p.invalidate()
        }
    }
}

// MARK: - CXCallObserverDelegate

extension CallController: CXCallObserverDelegate {
    nonisolated func callObserver(_ observer: CXCallObserver, callChanged call: CXCall) {
        // When an incoming call connects (user accepts on phone), clear
        // hasIncomingCall so the watch UI reflects the active call state.
        if !call.isOutgoing, call.hasConnected {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hasIncomingCall = false
            }
            return
        }

        // Only handle incoming calls that haven't connected or ended yet.
        guard !call.isOutgoing, !call.hasConnected, !call.hasEnded else { return }

        let callId = call.uuid.uuidString

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Deduplicate: skip if we already sent an event for this call.
            guard !self.activeCallIDs.contains(callId) else { return }
            self.activeCallIDs.insert(callId)

            // Update observable state for the UI.
            self.incomingCallerName = "Unknown"
            self.hasIncomingCall = true

            // Build and send the CallEvent proto to the watch.
            self.sendCallEvent(callId: callId, caller: "Unknown", hasVideo: false)
        }
    }
}

// MARK: - Sending call events to the watch

extension CallController {
    /// Create a `CallEvent` proto and push it to the watch via `BLEManager.sendCallEvent()`.
    /// Called when an incoming call is detected by `CXCallObserver`.
    func sendCallEvent(callId: String, caller: String, hasVideo: Bool) {
        let event = CallEvent(
            callId: callId,
            caller: caller,
            hasVideo: hasVideo,
            timestampMs: UInt64(Date().timeIntervalSince1970 * 1000)
        )
        ble.sendCallEvent(event)
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.activeCallIDs.removeAll()
            self.hasIncomingCall = false
            self.incomingCallerName = nil
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.activeCallIDs.remove(action.callUUID.uuidString)
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
