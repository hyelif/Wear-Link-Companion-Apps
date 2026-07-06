import SwiftUI

struct DevicesListView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Device card section
                    VStack(spacing: 12) {
                        // Connected device card
                        NavigationLink(destination: DeviceDetailsView()) {
                            DeviceCardView(
                                deviceName: "Galaxy Watch7 (A64Y)",
                                deviceVersion: "Android 14 • One UI 6 Watch",
                                batteryLevel: batteryLevel,
                                isConnected: isConnected,
                                isCharging: false
                            )
                        }
                        .buttonStyle(.plain)

                        // Health data sync banner
                        if isConnected {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .foregroundStyle(.green)
                                Text("Health data sync completed")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 4)
                        }
                    }

                    // Quick feature cards
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        FeatureCard(icon: "heart.fill", title: "Health", color: .red, destination: AnyView(HealthView()))
                        FeatureCard(icon: "phone.fill", title: "Calls", color: .green, destination: AnyView(CallView()))
                        FeatureCard(icon: "bell.fill", title: "Notifications", color: .orange, destination: AnyView(NotificationView()))
                        FeatureCard(icon: "music.note", title: "Music", color: .purple, destination: AnyView(MusicView()))
                    }

                    // Setup tip card
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "lightbulb.fill")
                                .foregroundStyle(.yellow)
                            Text("Quick Tip")
                                .font(.headline)
                        }
                        Text("Follow these steps to set up your watch:\n1. Enable Bluetooth on your watch\n2. Open WearLink on your watch\n3. Wait for automatic connection")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineSpacing(4)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.03), radius: 4, x: 0, y: 1)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Devices")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: DeviceDetailsView()) {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var isConnected: Bool {
        if case .connected = container.ble.state { return true }
        return false
    }

    private var batteryLevel: Int {
        // TODO: read from BLE device info when available
        85
    }
}

// MARK: - Feature Card

struct FeatureCard: View {
    let icon: String
    let title: String
    let color: Color
    let destination: AnyView

    var body: some View {
        NavigationLink(destination: destination) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                    .frame(width: 44, height: 44)
                    .background(color.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.03), radius: 4, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    DevicesListView()
        .environment(AppContainer())
}
