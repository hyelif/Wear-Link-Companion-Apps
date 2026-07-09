import SwiftUI

struct DeviceIconView: View {
    var size: CGFloat = 60
    var iconName: String = "applewatch"

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [.blue, .cyan]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
            Image(systemName: iconName)
                .foregroundStyle(.white)
                .font(.title)
                .imageScale(.large)
        }
    }
}

#Preview {
    DeviceIconView()
}
