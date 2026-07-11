import SwiftUI

struct DevicesListView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Device card section
                    VStack(spacing: 12) {
                        if let device = container.device {
                            // Connected device card
                            NavigationLink(destination: DeviceDetailsView()) {
                                DeviceCardView(
                                    deviceName: device.name,
                                    deviceVersion: "\(device.androidVersion) • Wear OS",
                                    batteryLevel: device.batteryLevel,
                                    isConnected: device.isConnected,
                                    isCharging: device.isCharging
                                )
                            }
                            .buttonStyle(.plain)

                            // Health data sync banner
                            if device.isConnected {
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
                        } else {
                            // No device placeholder
                            VStack(spacing: 12) {
                                DeviceIconView(size: 80)
                                Text("No Device Connected")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                Text("Open WearLink on your watch\nand wait for automatic connection")
                                    .font(.subheadline)
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                            .background(Color(.systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
                        }
                    }

                    // Quick feature cards
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        FeatureCard(icon: "heart.fill", title: "Health", color: .red) { HealthView() }
                        FeatureCard(icon: "phone.fill", title: "Calls", color: .green) { CallView() }
                        FeatureCard(icon: "bell.fill", title: "Notifications", color: .orange) { NotificationView() }
                        FeatureCard(icon: "music.note", title: "Music", color: .purple) { MusicView() }
                    }

                    // Setup tip card (only shown when no device is connected)
                    if container.device == nil {
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
                }
                .padding()
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Devices")
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
}

// MARK: - BLE status color (toolbar log icon)

private extension DevicesListView {
    /// Mirror of the BLE state for the toolbar log icon color: green=connected,
    /// orange=scanning/connecting, red=error, gray=off/no permission.
    var connColor: Color {
        switch container.ble.state {
        case .connected: return .green
        case .scanning, .connecting: return .orange
        case .disconnected(let err) where err != nil: return .red
        default: return .secondary
        }
    }
}

// MARK: - Feature Card

struct FeatureCard<Destination: View>: View {
    let icon: String
    let title: String
    let color: Color
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination()) {
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
        .accessibilityLabel("\(title) feature")
    }
}

#Preview {
    DevicesListView()
        .environment(AppContainer())
}