import SwiftUI

// MARK: - CallView

struct CallView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        Group {
            if container.call.hasIncomingCall {
                incomingCallContent
            } else if !container.call.activeCallIDs.isEmpty {
                activeCallContent
            } else if container.ble.state == .connected {
                noCallsContent
            } else {
                disconnectedContent
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("Calls")
    }

    // MARK: - Incoming Call

    private var incomingCallContent: some View {
        VStack(spacing: 24) {
            Spacer()

            // Caller info
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.12))
                        .frame(width: 80, height: 80)
                    Image(systemName: "phone.fill")
                        .font(.title)
                        .foregroundStyle(.green)
                }

                Text(container.call.incomingCallerName ?? "Unknown Caller")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Incoming Call")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Action buttons
            HStack(spacing: 40) {
                // Reject
                Button {
                    if let callId = container.call.activeCallIDs.first {
                        container.call.applyAction(CallAction(
                            callId: callId, action: .reject, nonce: 0
                        ))
                    }
                } label: {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 60, height: 60)
                            Image(systemName: "phone.down.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                        }
                        Text("Decline")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Accept
                Button {
                    if let callId = container.call.activeCallIDs.first {
                        container.call.applyAction(CallAction(
                            callId: callId, action: .accept, nonce: 0
                        ))
                    }
                } label: {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 60, height: 60)
                            Image(systemName: "phone.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                        }
                        Text("Accept")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Active Call

    private var activeCallContent: some View {
        VStack(spacing: 24) {
            Spacer()

            // Call status
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.12))
                        .frame(width: 80, height: 80)
                    Image(systemName: "phone.fill")
                        .font(.title)
                        .foregroundStyle(.green)
                }

                Text("Active Call")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("\(container.call.activeCallIDs.count) call(s) active")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Controls
            HStack(spacing: 40) {
                // Mute
                Button {
                    if let callId = container.call.activeCallIDs.first {
                        container.call.applyAction(CallAction(
                            callId: callId, action: .mute, nonce: 0
                        ))
                    }
                } label: {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 60, height: 60)
                            Image(systemName: "mic.slash.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                        }
                        Text("Mute")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // End
                Button {
                    if let callId = container.call.activeCallIDs.first {
                        container.call.applyAction(CallAction(
                            callId: callId, action: .end, nonce: 0
                        ))
                    }
                } label: {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 60, height: 60)
                            Image(systemName: "phone.down.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                        }
                        Text("End")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - No Calls

    private var noCallsContent: some View {
        ContentUnavailableView(
            "No Active Calls",
            systemImage: "phone.slash",
            description: Text("Incoming calls from your iPhone will appear here.\nYou can accept, reject, or mute calls from your watch.")
        )
    }

    // MARK: - Disconnected

    private var disconnectedContent: some View {
        ContentUnavailableView(
            "Not Connected",
            systemImage: "applewatch.slash",
            description: Text("Connect to your watch to manage calls.")
        )
    }
}

#Preview {
    NavigationStack {
        CallView()
            .environment(AppContainer())
    }
}
