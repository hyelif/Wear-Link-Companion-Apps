import SwiftUI

// MARK: - ConnectionView

struct ConnectionView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Status icon
                statusIcon
                    .padding(.top, 32)

                // Status text
                VStack(spacing: 8) {
                    Text(statusTitle)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)

                    Text(statusDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal)

                // Status details
                statusDetailsCard

                // Action button
                if container.ble.state == .disconnected(nil) || container.ble.state == .poweredOff {
                    Button {
                        container.ble.startScanning()
                    } label: {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text("Start Advertising")
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(teal)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal)
                }
            }
            .padding()
        }
        .background(Color(.systemBackground))
        .navigationTitle("Connection")
    }

    // MARK: - Status Icon

    @ViewBuilder
    private var statusIcon: some View {
        switch container.ble.state {
        case .poweredOff:
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.12))
                    .frame(width: 100, height: 100)
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 40))
                    .foregroundStyle(.red)
            }

        case .scanning:
            ZStack {
                Circle()
                    .fill(teal.opacity(0.12))
                    .frame(width: 100, height: 100)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 40))
                    .foregroundStyle(teal)
            }
            .overlay(
                Circle()
                    .stroke(teal.opacity(0.3), lineWidth: 2)
                    .scaleEffect(1.15)
            )

        case .connecting:
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 100, height: 100)
                ProgressView()
                    .scaleEffect(1.5)
            }

        case .connected:
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 100, height: 100)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
            }

        case .disconnected(let error):
            ZStack {
                Circle()
                    .fill(error != nil ? Color.red.opacity(0.12) : Color(.systemGray5))
                    .frame(width: 100, height: 100)
                Image(systemName: error != nil ? "exclamationmark.triangle.fill" : "wifi.slash")
                    .font(.system(size: 40))
                    .foregroundStyle(error != nil ? .red : .secondary)
            }
        }
    }

    // MARK: - Status Text

    private var statusTitle: String {
        switch container.ble.state {
        case .poweredOff: return "Bluetooth is Off"
        case .scanning: return "Advertising"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .disconnected(let error):
            return error != nil ? "Connection Error" : "Disconnected"
        }
    }

    private var statusDescription: String {
        switch container.ble.state {
        case .poweredOff:
            return "Enable Bluetooth in Settings to use WearLink.\nThe app needs Bluetooth to communicate with your watch."
        case .scanning:
            return "Your iPhone is advertising as WearLink.\nOpen WearLink on your watch to connect."
        case .connecting:
            return "Establishing connection with your watch..."
        case .connected:
            return "Your iPhone is connected to your watch.\nHealth data, calls, and notifications are syncing."
        case .disconnected(let error):
            if let error {
                return "Connection failed: \(error.localizedDescription)\nTap below to try again."
            }
            return "Not connected to any watch.\nTap below to start advertising."
        }
    }

    // MARK: - Status Details Card

    @ViewBuilder
    private var statusDetailsCard: some View {
        VStack(spacing: 0) {
            detailRow(label: "Bluetooth", value: container.ble.state == .poweredOff ? "Off" : "On")
            Divider().padding(.leading)
            detailRow(label: "Advertising", value: container.ble.state == .scanning ? "Yes" : "No")
            Divider().padding(.leading)
            detailRow(label: "Connected", value: container.ble.state == .connected ? "Yes" : "No")
            Divider().padding(.leading)
            detailRow(label: "Device", value: container.device?.name ?? "—")
        }
        .background(cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.separator).opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal)
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Accent color

private let teal = Color(red: 0.2, green: 0.8, blue: 0.8)
private let cardBg = Color(.systemGray6)

#Preview {
    NavigationStack {
        ConnectionView()
            .environment(AppContainer())
    }
}
