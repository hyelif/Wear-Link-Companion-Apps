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

    init(ble: BLEManager) { self.ble = ble }

    // TODO Phase 2: subscribe to BLE health-stream frames, decode proto,
    // build HKQuantitySample / HKCategorySample, enqueue, flush on timer.
    func requestAuthorization() async {
        // Request write for: heart rate, steps, SpO2, HRV, sleep.
        let types: Set<HKSampleType> = {
            var s: Set<HKSampleType> = []
            [.heartRate, .stepCount, .oxygenSaturation, .heartRateVariabilitySDNN]
                .compactMap { HKQuantityType.quantityType(forIdentifier: $0) }
                .forEach { s.insert($0) }
            if let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sleep) }
            return s
        }()
        try? await store.requestAuthorization(toShare: types, read: [])
    }
}