import SwiftUI

struct HealthView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header
                VStack(spacing: 4) {
                    Image(systemName: "heart.text.square")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text("Live Health Data")
                        .font(.title2).fontWeight(.semibold)
                    if let lastUpdate = container.health.lastUpdate {
                        Text("Updated \(relativeTime(lastUpdate))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Waiting for data from watch…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top)

                // Metric cards grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    MetricCard(
                        icon: "heart.fill",
                        label: "Heart Rate",
                        value: container.health.lastHeartRate.map { "\(Int($0))" },
                        unit: "bpm",
                        color: .red
                    )
                    MetricCard(
                        icon: "figure.walk",
                        label: "Steps",
                        value: container.health.lastSteps.map { "\($0)" },
                        unit: "steps",
                        color: .blue
                    )
                    MetricCard(
                        icon: "flame.fill",
                        label: "Calories",
                        value: container.health.lastCalories.map { String(format: "%.0f", $0) },
                        unit: "kcal",
                        color: .orange
                    )
                    MetricCard(
                        icon: "map.fill",
                        label: "Distance",
                        value: container.health.lastDistance.map { distanceStr($0) },
                        unit: container.health.lastDistance.map { $0 >= 1000 ? "km" : "m" } ?? "",
                        color: .green
                    )
                }
                .padding(.horizontal)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Health")
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if abs(interval) < 5 { return "just now" }
        if interval > -60 { return "\(Int(-interval))s ago" }
        if interval > -3600 { return "\(Int(-interval / 60))m ago" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func distanceStr(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.2f", meters / 1000)
        }
        return String(format: "%.0f", meters)
    }
}

// MARK: - Metric Card

private struct MetricCard: View {
    let icon: String
    let label: String
    let value: String?
    let unit: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let value {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.title2).fontWeight(.bold)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if !unit.isEmpty {
                        Text(unit)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text("--")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.03), radius: 4, x: 0, y: 1)
        .accessibilityLabel("\(label): \(value ?? "no data") \(unit)")
    }
}

#Preview {
    NavigationStack {
        HealthView()
            .environment(AppContainer())
    }
}