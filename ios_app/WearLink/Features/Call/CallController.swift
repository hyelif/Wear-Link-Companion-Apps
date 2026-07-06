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
final class CallController: NSObject, CXCallObserverDelegate {
    private let ble: BLEManager
    private let provider: CXProvider
    private let controller = CXCallController()
    private let observer = CXCallObserver()

    init(ble: BLEManager) {
        self.ble = ble
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = false
        cfg.maximumCallGroups = 1
        cfg.maximumCallsPerCallGroup = 1
        self.provider = CXProvider(configuration: cfg)
        super.init()
        provider.setDelegate(self, queue: nil)
        observer.setDelegate(self, queue: nil)
    }

    // CXCallObserverDelegate
    nonisolated func callObserver(_ observer: CXCallObserver, callChanged call: CXCall) {
        guard !call.isOutgoing, !call.hasConnected, !call.hasEnded else { return }
        Task { @MainActor in
            let name = await self.contactName(for: call) ?? "Unknown"
            // TODO: encode CallEvent proto, ble.gatt?.write(_, to: callEvent)
            _ = name
        }
    }

    private func contactName(for call: CXCall) async -> String? {
        // TODO: CNContactStore lookup by handle. Requires NSContactsUsageDescription (in Info.plist).
        return nil
    }

    /// Called when watch sends an action over `callAction`.
    func applyAction(_ action: CallAction) {
        // TODO: map to CXEndCallAction / CXAnswerCallAction -> CXTransaction -> controller.request()
    }
}

enum CallAction { case accept, reject, mute, end }

extension CallController: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {}
}