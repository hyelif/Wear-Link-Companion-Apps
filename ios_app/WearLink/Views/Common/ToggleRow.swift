import SwiftUI

struct ToggleRow: View {
    let title: String
    let subtitle: String?
    let icon: Image?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                icon
                    .foregroundStyle(.blue)
                    .font(.body)
                    .frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.green)
                .accessibilityLabel(title)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ToggleRow(title: "Auto-connect", subtitle: "Automatically connect when nearby", icon: Image(systemName: "link"), isOn: .constant(true))
}
