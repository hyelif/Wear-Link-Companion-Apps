import SwiftUI

// MARK: - DeviceInfoSection

struct DeviceInfoSection: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        Group {
            if let device = container.device {
                List {
                    infoRow(label: "Device Name", value: device.name)
                    infoRow(label: "Device ID", value: device.id)
                    infoRow(label: "Model Name", value: orDash(device.model))
                    infoRow(label: "Android Version", value: orDash(device.androidVersion))
                    infoRow(label: "App Version", value: orDash(device.appVersion))
                    infoRow(label: "Battery Level", value: device.batteryLevel > 0 ? "\(device.batteryLevel)%" : "—")
                    infoRow(label: "Is Charging", value: device.isCharging ? "Yes" : "No")
                    infoRow(label: "Connection State", value: device.isConnected ? "Connected" : "Disconnected")
                    infoRow(label: "Last Seen", value: device.lastSeen.formatted(date: .abbreviated, time: .shortened))
                }
            } else if container.ble.state == .connected {
                ContentUnavailableView(
                    "Waiting for Device Information",
                    systemImage: "info.circle",
                    description: Text("Device information will appear once the watch sends its details.")
                )
            } else {
                ContentUnavailableView(
                    "No Device Data",
                    systemImage: "info.circle",
                    description: Text("Device information will appear here when connected.")
                )
            }
        }
        .navigationTitle("Device Information")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(value == "—" ? .tertiary : .primary)
        }
    }

    private func orDash(_ s: String) -> String {
        s.isEmpty ? "—" : s
    }
}

#Preview {
    NavigationStack {
        DeviceInfoSection()
            .environment(AppContainer())
    }
}
