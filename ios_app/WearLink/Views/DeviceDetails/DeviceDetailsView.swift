import SwiftUI

struct DeviceDetailsView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let device = container.device {
                detailsList(device: device)
            } else {
                ContentUnavailableView(
                    "No Device",
                    systemImage: "applewatch.slash",
                    description: Text("Connect to a watch to see device details.")
                )
            }
        }
        .navigationTitle("Device Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func detailsList(device: WearableDevice) -> some View {
        List {
            // Device header
            Section {
                VStack(spacing: 12) {
                    DeviceIconView(size: 80)

                    Text(device.name)
                        .font(.title2)
                        .fontWeight(.bold)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(device.isConnected ? Color.green : Color.secondary)
                            .frame(width: 10, height: 10)
                        Text(device.isConnected ? "Connected" : "Disconnected")
                            .font(.subheadline)
                            .foregroundStyle(device.isConnected ? .green : .secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            // General section
            Section {
                ToggleRow(title: "Auto-connect", subtitle: "Automatically connect when watch is nearby", icon: Image(systemName: "link"), isOn: Binding(get: { container.settings.autoConnect }, set: { container.settings.autoConnect = $0 }))
                ToggleRow(title: "Analytics", subtitle: "Share usage data to improve WearLink", icon: Image(systemName: "chart.bar"), isOn: Binding(get: { container.settings.analytics }, set: { container.settings.analytics = $0 }))
            } header: {
                SectionHeader(title: "General")
            }

            // Notifications section
            Section {
                ToggleRow(title: "Enable Notifications", subtitle: "Receive phone notifications on your watch", icon: Image(systemName: "bell"), isOn: Binding(get: { container.settings.enableNotifications }, set: { container.settings.enableNotifications = $0 }))

                ToggleRow(title: "Bidirectional Sync", subtitle: "Sync notification actions between devices", icon: Image(systemName: "arrow.triangle.2.circlepath"), isOn: Binding(get: { container.settings.bidirectionalSync }, set: { container.settings.bidirectionalSync = $0 }))

                NavigationLink {
                    // TODO: App notifications picker
                    Text("App Notifications")
                        .navigationTitle("App Notifications")
                } label: {
                    Label("App Notifications", systemImage: "square.grid.2x2")
                }

                NavigationLink {
                    // TODO: Notification history
                    Text("Notification History")
                        .navigationTitle("Notification History")
                } label: {
                    Label("Notification History", systemImage: "clock.arrow.circlepath")
                }
            } header: {
                SectionHeader(title: "Notifications")
            }

            // Health section
            Section {
                ToggleRow(title: "Collect Health Data", subtitle: "Sync heart rate, steps, and sleep data", icon: Image(systemName: "heart.text.square"), isOn: Binding(get: { container.settings.collectHealthData }, set: { container.settings.collectHealthData = $0 }))
            } header: {
                SectionHeader(title: "Health")
            }

            // Find Device section
            Section {
                Button {
                    // TODO: Send find-device signal to watch
                    print("[DeviceDetails] Find My Watch tapped")
                } label: {
                    HStack {
                        Image(systemName: "bell.fill")
                            .foregroundStyle(.blue)
                        Text("Find My Watch")
                            .foregroundStyle(.blue)
                        Spacer()
                    }
                }

                Text("Your watch will ring even if it's in silent mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SectionHeader(title: "Find Device")
            }

            // Device Management section
            Section {
                Button(role: .destructive) {
                    container.disconnectDevice()
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Forget Device")
                    }
                }
            } header: {
                SectionHeader(title: "Device Management")
            }

            // Device Info section
            Section {
                NavigationLink {
                    DeviceInfoSection()
                } label: {
                    Label("Device Information", systemImage: "info.circle")
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        DeviceDetailsView()
            .environment(AppContainer())
    }
}