import SwiftUI

// MARK: - NotificationView

struct NotificationView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        Group {
            if container.notification.forwardedNotifications.isEmpty {
                if container.ble.state == .connected {
                    emptyContent
                } else {
                    disconnectedContent
                }
            } else {
                notificationList
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("Notifications")
    }

    // MARK: - Notification List

    private var notificationList: some View {
        List {
            ForEach(container.notification.forwardedNotifications) { item in
                NotificationRow(item: item)
                    .listRowBackground(cardBg)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            dismissNotification(item)
                        } label: {
                            Label("Dismiss", systemImage: "bell.slash")
                        }
                    }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    let item = container.notification.forwardedNotifications[index]
                    dismissNotification(item)
                }
            }
        }
        .listStyle(.plain)
    }

    private func dismissNotification(_ item: ForwardedNotificationItem) {
        let action = NotifAction(
            notifId: item.notifId,
            action: .dismiss,
            replyText: "",
            nonce: 0
        )
        container.notification.handleAction(action)
    }

    // MARK: - Empty Content

    private var emptyContent: some View {
        ContentUnavailableView(
            "No Notifications",
            systemImage: "bell.slash",
            description: Text("Forwarded notifications from your watch will appear here.\nMake sure notification forwarding is enabled.")
        )
    }

    // MARK: - Disconnected Content

    private var disconnectedContent: some View {
        ContentUnavailableView(
            "Not Connected",
            systemImage: "applewatch.slash",
            description: Text("Connect to your watch to receive notifications.")
        )
    }
}

// MARK: - Notification Row

private struct NotificationRow: View {
    let item: ForwardedNotificationItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack {
                // App icon placeholder
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(appColor(for: item.appName).opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: appIcon(for: item.appName))
                        .font(.caption2)
                        .foregroundStyle(appColor(for: item.appName))
                }

                Text(item.appName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(formattedTimestamp(item.timestampMs))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Title
            Text(item.title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(2)

            // Body
            if !item.body.isEmpty {
                Text(item.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.appName): \(item.title)")
    }

    private func formattedTimestamp(_ ms: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func appIcon(for appName: String) -> String {
        let lower = appName.lowercased()
        if lower.contains("message") || lower.contains("sms") { return "message.fill" }
        if lower.contains("mail") || lower.contains("email") { return "envelope.fill" }
        if lower.contains("phone") || lower.contains("call") { return "phone.fill" }
        if lower.contains("calendar") { return "calendar" }
        if lower.contains("reminder") { return "checklist" }
        if lower.contains("music") || lower.contains("spotify") { return "music.note" }
        if lower.contains("whatsapp") || lower.contains("telegram") || lower.contains("signal") { return "bubble.left.fill" }
        if lower.contains("instagram") || lower.contains("facebook") || lower.contains("twitter") || lower.contains("social") { return "square.and.pencil" }
        return "app.badge.fill"
    }

    private func appColor(for appName: String) -> Color {
        let lower = appName.lowercased()
        if lower.contains("message") || lower.contains("sms") { return .green }
        if lower.contains("mail") || lower.contains("email") { return .blue }
        if lower.contains("phone") || lower.contains("call") { return .green }
        if lower.contains("calendar") { return .red }
        if lower.contains("whatsapp") || lower.contains("telegram") { return .green }
        if lower.contains("instagram") { return .purple }
        if lower.contains("facebook") { return .blue }
        if lower.contains("twitter") { return .cyan }
        return .orange
    }
}

// MARK: - Card background

private let cardBg = Color(.systemGray6)

#Preview {
    NavigationStack {
        NotificationView()
            .environment(AppContainer())
    }
}
