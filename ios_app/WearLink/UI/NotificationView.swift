import SwiftUI

struct NotificationView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        List {
            if container.notification.forwardedNotifications.isEmpty {
                ContentUnavailableView(
                    "No Notifications",
                    systemImage: "bell.slash",
                    description: Text("Forwarded notifications from your watch will appear here.")
                )
            } else {
                ForEach(container.notification.forwardedNotifications) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.appName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(formattedTimestamp(item.timestampMs))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(item.title)
                            .font(.headline)
                        Text(item.body)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Notifications")
    }

    private func formattedTimestamp(_ ms: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
