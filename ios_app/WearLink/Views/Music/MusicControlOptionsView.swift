import SwiftUI

// MARK: - Accent color

private let teal = Color(red: 0.2, green: 0.8, blue: 0.8)

// MARK: - MusicControlOptionsView

struct MusicControlOptionsView: View {
    @State private var selectedColor: BackgroundColor = .random
    @State private var showAlbumArt = false
    @State private var watchFaceAlwaysOn = true

    enum BackgroundColor: String, CaseIterable {
        case random = "Random"
        case black = "Black"
        case white = "White"
        case blue = "Blue"
        case red = "Red"
        case green = "Green"

        var color: Color {
            switch self {
            case .random: return .purple
            case .black: return .black
            case .white: return .white
            case .blue: return .blue
            case .red: return .red
            case .green: return .green
            }
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Background Color", selection: $selectedColor) {
                    ForEach(BackgroundColor.allCases, id: \.self) { color in
                        HStack {
                            Circle()
                                .fill(color.color)
                                .frame(width: 20, height: 20)
                            Text(color.rawValue)
                        }
                        .tag(color)
                    }
                }

                Text("Choose the background color for the music control screen on your watch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SectionHeader(title: "Background Color")
            }

            Section {
                ToggleRow(title: "Show Album Art", subtitle: "Display album artwork on the watch face", icon: Image(systemName: "photo"), isOn: $showAlbumArt)

                Text("Album art will appear as the background when music is playing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ToggleRow(title: "Watch Face Always On", subtitle: "Keep watch face visible during music playback", icon: Image(systemName: "eye"), isOn: $watchFaceAlwaysOn)

                Text("When enabled, the watch face stays on while music controls are active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SectionHeader(title: "Display Options")
            }

        }
        .navigationTitle("Music Control Options")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        MusicControlOptionsView()
    }
}
