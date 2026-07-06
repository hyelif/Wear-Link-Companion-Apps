import Foundation

/// On-device cache for health frames pending HealthKit write.
/// Survives BLE drops; replayed on reconnect. Phase 2 implementation.
final class SampleStore {
    // TODO: persist to app group container; replay on BLE reconnect.
}