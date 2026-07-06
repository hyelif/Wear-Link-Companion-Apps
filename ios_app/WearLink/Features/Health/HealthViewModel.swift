import Foundation
import HealthKit

/// Receives health frames from the watch (via BLEManager) and writes them
/// to HealthKit. Batches + dedupes before write to limit HealthKit calls.
@MainActor
@Observable
final class HealthViewModel {
    private let ble: BLEManager
    private let store = HKHealthStore()
    private var pending: [HKSample] = []

    /// Whether HealthKit authorization has been granted.
    private(set) var isAuthorized = false
    /// Most recent heart rate value received from the watch (bpm).
    private(set) var lastHeartRate: Double?
    /// Most recent step count received from the watch.
    private(set) var lastSteps: Int?

    init(ble: BLEManager) { self.ble = ble }

    // TODO Phase 2: subscribe to BLE health-stream frames, decode proto,
    // build HKQuantitySample / HKCategorySample, enqueue, flush on timer.
    func requestAuthorization() async throws {
        // Check if HealthKit is available on this device.
        guard HKHealthStore.isHealthDataAvailable() else {
            print("[HealthViewModel] HealthKit not available on this device")
            isAuthorized = false
            return
        }

        // Request write for: heart rate, steps, SpO2, HRV, sleep.
        let types: Set<HKSampleType> = {
            var s: Set<HKSampleType> = []
            [.heartRate, .stepCount, .oxygenSaturation, .heartRateVariabilitySDNN]
                .compactMap { HKQuantityType.quantityType(forIdentifier: $0) }
                .forEach { s.insert($0) }
            if let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sleep) }
            return s
        }()
        do {
            try await store.requestAuthorization(toShare: types, read: [])
            isAuthorized = true
        } catch {
            print("[HealthViewModel] Authorization failed: \(error.localizedDescription)")
            isAuthorized = false
            throw error
        }
    }
}
