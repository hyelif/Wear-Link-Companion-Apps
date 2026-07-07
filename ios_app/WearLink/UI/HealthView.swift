import SwiftUI

/// Placeholder health data view. HealthKit integration removed for SideStore
/// free-account compatibility. Health data display (heart rate, steps, etc.)
/// will be added here from the BLE health-stream once the in-app display
/// layer is implemented (no Apple Health write).
struct HealthView: View {
    var body: some View {
        ContentUnavailableView(
            "Health Data",
            systemImage: "heart.text.square",
            description: Text("Health data display coming soon. Your watch syncs health data over BLE — the in-app view will show it here.")
        )
    }
}
