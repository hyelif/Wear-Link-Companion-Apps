import SwiftUI

struct HealthView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        List {
            Section("Authorization") {
                HStack {
                    Label("HealthKit", systemImage: "heart.text.square")
                    Spacer()
                    if container.health.isAuthorized {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Live Data") {
                if let hr = container.health.lastHeartRate {
                    HStack {
                        Label("Heart Rate", systemImage: "heart.fill")
                            .foregroundStyle(.red)
                        Spacer()
                        Text("\(Int(hr)) bpm")
                            .monospacedDigit()
                    }
                } else {
                    HStack {
                        Label("Heart Rate", systemImage: "heart.fill")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("--")
                            .foregroundStyle(.tertiary)
                    }
                }

                if let steps = container.health.lastSteps {
                    HStack {
                        Label("Steps", systemImage: "figure.walk")
                        Spacer()
                        Text("\(steps)")
                            .monospacedDigit()
                    }
                } else {
                    HStack {
                        Label("Steps", systemImage: "figure.walk")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("--")
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Section {
                Button {
                    Task { await container.health.requestAuthorization() }
                } label: {
                    Label("Request Authorization", systemImage: "shield")
                }
                .disabled(container.health.isAuthorized)
            } footer: {
                if !container.health.isAuthorized {
                    Text("Authorize HealthKit access to receive health data from your watch.")
                }
            }
        }
        .navigationTitle("Health")
    }
}
