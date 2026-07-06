import SwiftUI

struct CallView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        List {
            Section("Status") {
                if container.call.hasIncomingCall {
                    HStack {
                        Label("Incoming Call", systemImage: "phone.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Image(systemName: "phone.and.waveform.fill")
                            .foregroundStyle(.green)
                    }
                } else if !container.call.activeCallIDs.isEmpty {
                    HStack {
                        Label("Active Call", systemImage: "phone.fill")
                        Spacer()
                        Text("\(container.call.activeCallIDs.count) call(s)")
                            .monospacedDigit()
                    }
                } else {
                    Label("No Active Calls", systemImage: "phone.slash")
                        .foregroundStyle(.secondary)
                }
            }

            if let caller = container.call.incomingCallerName {
                Section("Incoming") {
                    Label(caller, systemImage: "person.crop.circle")
                        .font(.headline)

                    HStack(spacing: 20) {
                        Button {
                            container.call.applyAction(CallAction(
                                callId: "", action: .accept, nonce: 0
                            ))
                        } label: {
                            Label("Accept", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)

                        Button {
                            container.call.applyAction(CallAction(
                                callId: "", action: .reject, nonce: 0
                            ))
                        } label: {
                            Label("Reject", systemImage: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)

                        Button {
                            container.call.applyAction(CallAction(
                                callId: "", action: .mute, nonce: 0
                            ))
                        } label: {
                            Label("Mute", systemImage: "mic.slash.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if !container.call.activeCallIDs.isEmpty {
                Section("Active Calls") {
                    ForEach(Array(container.call.activeCallIDs), id: \.self) { callId in
                        HStack {
                            Text(callId)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Button("End") {
                                container.call.applyAction(CallAction(
                                    callId: callId, action: .end, nonce: 0
                                ))
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                    }
                }
            }
        }
        .navigationTitle("Calls")
    }
}
