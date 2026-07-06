import SwiftUI

struct ConnectionView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        List {
            Section("Link") {
                statusRow
            }
            Section("Health") {
                Label("Sync to Apple Health", systemImage: "heart.text.square")
                    .task { await container.health.requestAuthorization() }
            }
            Section("Features") {
                Label("Calls", systemImage: "phone")
                Label("Notifications", systemImage: "bell")
                Label("Music", systemImage: "music.note")
            }
        }
        .navigationTitle("WearLink")
    }

    @ViewBuilder private var statusRow: some View {
        switch container.ble.state {
        case .poweredOff:     Label("Powered off", systemImage: "circle.slash")
        case .scanning:        Label("Scanning for watch…", systemImage: "antenna.radiowaves.left.and.right")
        case .connecting:      Label("Connecting…", systemImage: "wifi")
        case .connected:      Label("Connected", systemImage: "checkmark.circle.fill")
        case .disconnected:   Label("Disconnected", systemImage: "exclamationmark.triangle")
        }
    }
}