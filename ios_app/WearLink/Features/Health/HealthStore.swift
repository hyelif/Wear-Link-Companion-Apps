import Foundation

/// Local on-device cache of health frames received but not yet written to
/// HealthKit. Survives BLE drops; replayed on reconnect. Phase 2.
final class SampleStore {
    // TODO: persist to app group container (replay across launches).
}