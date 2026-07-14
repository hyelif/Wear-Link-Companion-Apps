import SwiftUI

// MARK: - HealthView

struct HealthView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        Group {
            if container.health.hasData {
                healthContent
            } else if container.ble.state == .connected {
                waitingContent
            } else {
                disconnectedContent
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("Health")
    }

    // MARK: - Data Content

    private var healthContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .fill(Color.red.opacity(0.12))
                            .frame(width: 64, height: 64)
                        Image(systemName: "heart.text.square")
                            .font(.title)
                            .foregroundStyle(.red)
                    }
                    Text("Live Health Data")
                        .font(.title2).fontWeight(.semibold)
                    if let lastUpdate = container.health.lastUpdate {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.green)
                                .frame(width: 6, height: 6)
                            Text("Updated \(relativeTime(lastUpdate))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 8)

                // Heart rate - prominent
                heartRateCard

                // Metric grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    MetricCard(
                        icon: "figure.walk",
                        label: "Steps",
                        value: container.health.lastSteps.map { formatNumber($0) },
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
                    MetricCard(
                        icon: "moon.stars.fill",
                        label: "Sleep",
                        value: nil,
                        unit: "",
                        color: .indigo
                    )
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 24)
        }
    }

    // MARK: - Heart Rate Card

    private var heartRateCard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "heart.fill")
                    .font(.title)
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating)

                if let hr = container.health.lastHeartRate {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(Int(hr))")
                            .font(.system(size: 56, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(.primary)
                        Text("bpm")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("--")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }

            Text("Heart Rate")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(.separator).opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal)
    }

    // MARK: - Waiting Content

    private var waitingContent: some View {
        ContentUnavailableView(
            "Waiting for Health Data",
            systemImage: "heart.text.square",
            description: Text("Health data will appear here once the watch sends it.\nMake sure health tracking is enabled on your watch.")
        )
    }

    // MARK: - Disconnected Content

    private var disconnectedContent: some View {
        ContentUnavailableView(
            "Not Connected",
            systemImage: "applewatch.slash",
            description: Text("Connect to your watch to view health data.")
        )
    }

    // MARK: - Helpers

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

    private func formatNumber(_ n: Int) -> String {
        if n >= 1000 {
            let k = Double(n) / 1000.0
            return String(format: "%.1fK", k)
        }
        return "\(n)"
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
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(color.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(color)
            }

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let value {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.title2).fontWeight(.bold)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(.primary)
                    if !unit.isEmpty {
                        Text(unit)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text("--")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.separator).opacity(0.3), lineWidth: 1)
        )
        .accessibilityLabel("\(label): \(value ?? "no data") \(unit)")
    }
}

// MARK: - Card background

private let cardBg = Color(.systemGray6)

#Preview {
    NavigationStack {
        HealthView()
            .environment(AppContainer())
    }
}
