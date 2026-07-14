import SwiftUI

// MARK: - Accent color

private let teal = Color(red: 0.2, green: 0.8, blue: 0.8)

// MARK: - BLELogView

struct BLELogView: View {
    @Environment(AppContainer.self) private var container
    @State private var autoScroll = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if container.ble.logEntries.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.largeTitle)
                                .foregroundStyle(.tertiary)
                            Text("No BLE events yet.")
                                .foregroundStyle(.secondary)
                            Text("Make sure Bluetooth is on and the app has Bluetooth permission.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    }
                    ForEach(container.ble.logEntries) { entry in
                        logRow(entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .onChange(of: container.ble.logEntries.count) { _, _ in
                guard autoScroll,
                      let last = container.ble.logEntries.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("BLE Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("Clear logs") { container.ble.clearLogs() }
                    Button(autoScroll ? "Pause auto-scroll" : "Resume auto-scroll") {
                        autoScroll.toggle()
                    }
                    Button("Rescan now") { container.ble.startScanning() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(teal)
                }
            }
        }
    }

    @ViewBuilder
    private func logRow(_ entry: BLELogEntry) -> some View {
        let time = entry.date.formatted(date: .omitted, time: .standard)
        HStack(alignment: .top, spacing: 8) {
            Text(time)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 84, alignment: .leading)
            Text(levelTag(entry.level))
                .font(.caption2.bold())
                .foregroundStyle(levelColor(entry.level))
                .frame(width: 44, alignment: .leading)
            Text(entry.text)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func levelTag(_ l: BLELogLevel) -> String {
        switch l { case .info: "INFO"; case .warning: "WARN"; case .error: "ERR" }
    }

    private func levelColor(_ l: BLELogLevel) -> Color {
        switch l { case .info: .secondary; case .warning: .orange; case .error: .red }
    }
}

#Preview {
    NavigationStack { BLELogView() }
        .environment(AppContainer())
}
