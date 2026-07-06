import SwiftUI

struct DeviceCardView: View {
    let deviceName: String
    let deviceVersion: String
    let batteryLevel: Int
    let isConnected: Bool
    let isCharging: Bool

    var body: some View {
        HStack(spacing: 16) {
            DeviceIconView(size: 60)

            VStack(alignment: .leading, spacing: 4) {
                Text(deviceName)
                    .font(.headline)
                    .lineLimit(1)
                Text(deviceVersion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: isCharging ? "battery.100.bolt" : "battery.75")
                        .font(.caption)
                        .foregroundStyle(batteryLevel > 20 ? .green : .red)
                    Text("\(batteryLevel)%")
                        .font(.caption)
                        .foregroundStyle(batteryLevel > 20 ? .green : .red)
                        .monospacedDigit()
                }

                if isConnected {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("Connected")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                } else {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.secondary)
                            .frame(width: 8, height: 8)
                        Text("Disconnected")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
    }
}

#Preview {
    VStack {
        DeviceCardView(deviceName: "Galaxy Watch7 (A64Y)", deviceVersion: "Android 14 • One UI 6", batteryLevel: 85, isConnected: true, isCharging: false)
        DeviceCardView(deviceName: "Galaxy Watch7 (A64Y)", deviceVersion: "Android 14 • One UI 6", batteryLevel: 12, isConnected: false, isCharging: true)
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
