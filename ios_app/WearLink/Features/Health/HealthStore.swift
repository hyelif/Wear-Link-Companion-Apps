import Foundation

/// Health-side pending-frame cache. Survives BLE drops; replayed on reconnect.
/// Phase 2 implementation. (Generic on-device cache lives in Storage/SampleStore.swift.)
final class HealthSampleStore {
    // TODO: persist to app group container; replay on BLE reconnect.
}