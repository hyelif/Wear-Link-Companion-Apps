import SwiftUI

// MARK: - Accent color palette

private let teal = Color(red: 0.2, green: 0.8, blue: 0.8)
private let tealDark = Color(red: 0.1, green: 0.5, blue: 0.5)
private let cardBg = Color(.systemGray6)
private let cardBgDark = Color(.systemGray5)

// MARK: - DevicesListView

struct DevicesListView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    connectionStatusCard
                    if container.device?.isConnected == true || container.ble.state == .connected {
                        healthSummaryCard
                    }
                    featureGrid
                    if container.device?.isConnected != true && container.ble.state != .connected {
                        setupTipCard
                    }
                }
                .padding()
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(.systemBackground))
            .navigationTitle("WearLink")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink(destination: BLELogView()) {
                        Label("BLE Logs", systemImage: "doc.text.magnifyingglass")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(connColor)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: DeviceDetailsView()) {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Connection Status Card

    @ViewBuilder
    private var connectionStatusCard: some View {
        let isConnected = container.device?.isConnected == true || container.ble.state == .connected
        let deviceName = container.device?.name ?? "Wear OS Watch"

        VStack(spacing: 0) {
            // Top gradient bar
            Rectangle()
                .fill(isConnected ? teal : Color(.separator))
                .frame(height: 3)

            HStack(spacing: 16) {
                // Status icon
                ZStack {
                    Circle()
                        .fill(isConnected ? teal.opacity(0.15) : Color(.systemGray5))
                        .frame(width: 52, height: 52)
                    Image(systemName: isConnected ? "applewatch.radiowaves.left.and.right" : "applewatch.slash")
                        .font(.title3)
                        .foregroundStyle(isConnected ? teal : .secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(isConnected ? deviceName : "Not Connected")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(isConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(isConnected ? "Connected" : "Disconnected")
                            .font(.caption)
                            .foregroundStyle(isConnected ? .green : .red)
                    }

                    if isConnected, let lastSeen = container.device?.lastSeen {
                        Text("Last sync: \(relativeTime(lastSeen))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else if !isConnected {
                        Text("Open WearLink on your watch to connect")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                if isConnected {
                    batteryBadge
                }
            }
            .padding()
        }
        .background(cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(.separator).opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var batteryBadge: some View {
        if let device = container.device {
            VStack(spacing: 2) {
                Image(systemName: batteryIconName(level: device.batteryLevel, charging: device.isCharging))
                    .font(.caption)
                    .foregroundStyle(device.batteryLevel < 20 ? .red : teal)
                Text("\(device.batteryLevel)%")
                    .font(.caption2)
                    .foregroundStyle(device.batteryLevel < 20 ? .red : .secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Health Summary Card

    @ViewBuilder
    private var healthSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "heart.text.square")
                    .foregroundStyle(.red)
                Text("Health Summary")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                if let lastUpdate = container.health.lastUpdate {
                    Text(relativeTime(lastUpdate))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                healthMetric(
                    icon: "heart.fill",
                    value: container.health.lastHeartRate.map { "\(Int($0))" } ?? "--",
                    unit: "bpm",
                    color: .red
                )
                healthMetric(
                    icon: "figure.walk",
                    value: container.health.lastSteps.map { formatNumber($0) } ?? "--",
                    unit: "steps",
                    color: .blue
                )
                healthMetric(
                    icon: "flame.fill",
                    value: container.health.lastCalories.map { String(format: "%.0f", $0) } ?? "--",
                    unit: "kcal",
                    color: .orange
                )
            }
        }
        .padding()
        .background(cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(.separator).opacity(0.3), lineWidth: 1)
        )
    }

    private func healthMetric(icon: String, value: String, unit: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            Text(value)
                .font(.system(.title3, design: .rounded))
                .fontWeight(.bold)
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.primary)
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Feature Grid

    private var featureGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            FeatureCard(icon: "heart.fill", title: "Health", color: .red, systemImage: "heart.text.square") { HealthView() }
            FeatureCard(icon: "phone.fill", title: "Calls", color: .green, systemImage: "phone") { CallView() }
            FeatureCard(icon: "bell.fill", title: "Notifications", color: .orange, systemImage: "bell.badge") { NotificationView() }
            FeatureCard(icon: "music.note", title: "Music", color: .purple, systemImage: "music.note.list") { MusicView() }
        }
    }

    // MARK: - Setup Tip Card

    private var setupTipCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(.yellow)
                Text("Getting Started")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            VStack(alignment: .leading, spacing: 8) {
                setupStep(number: 1, text: "Enable Bluetooth on your watch")
                setupStep(number: 2, text: "Open WearLink on your watch")
                setupStep(number: 3, text: "Wait for automatic connection")
            }

            Divider()
                .padding(.vertical, 4)

            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(teal)
                Text("iPhone is advertising as WearLink")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(.separator).opacity(0.3), lineWidth: 1)
        )
    }

    private func setupStep(number: Int, text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(teal)
                .clipShape(Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private var connColor: Color {
        switch container.ble.state {
        case .connected: return .green
        case .scanning, .connecting: return .orange
        case .disconnected(let err) where err != nil: return .red
        default: return .secondary
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if abs(interval) < 5 { return "just now" }
        if interval > -60 { return "\(Int(-interval))s ago" }
        if interval > -3600 { return "\(Int(-interval / 60))m ago" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func batteryIconName(level: Int, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch level {
        case 76...100: return "battery.100"
        case 51...75:  return "battery.75"
        case 26...50:  return "battery.50"
        case 1...25:   return "battery.25"
        default:       return "battery.0"
        }
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1000 {
            let k = Double(n) / 1000.0
            return String(format: "%.1fK", k)
        }
        return "\(n)"
    }
}

// MARK: - Feature Card

private struct FeatureCard<Destination: View>: View {
    let icon: String
    let title: String
    let color: Color
    let systemImage: String
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination()) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(color.opacity(0.12))
                        .frame(width: 48, height: 48)
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(color)
                }

                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(cardBg)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color(.separator).opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) feature")
    }
}

#Preview {
    DevicesListView()
        .environment(AppContainer())
}
