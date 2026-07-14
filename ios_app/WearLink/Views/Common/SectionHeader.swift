import SwiftUI

// MARK: - Accent color

private let teal = Color(red: 0.2, green: 0.8, blue: 0.8)

// MARK: - SectionHeader

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.footnote)
            .fontWeight(.semibold)
            .foregroundStyle(teal)
            .textCase(.uppercase)
            .padding(.leading, 4)
    }
}

#Preview {
    SectionHeader(title: "General")
}
