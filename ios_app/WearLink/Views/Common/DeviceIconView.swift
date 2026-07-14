import SwiftUI

// MARK: - Accent color

private let teal = Color(red: 0.2, green: 0.8, blue: 0.8)

// MARK: - DeviceIconView

struct DeviceIconView: View {
    var size: CGFloat = 60
    var iconName: String = "applewatch"

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [teal, teal.opacity(0.6)]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
            Image(systemName: iconName)
                .foregroundStyle(.white)
                .font(.system(size: size * 0.45))
        }
    }
}

#Preview {
    DeviceIconView()
}
