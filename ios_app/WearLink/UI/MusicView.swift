import SwiftUI

// MARK: - MusicView

struct MusicView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        let nowPlaying = container.music.nowPlaying
        let hasContent = !nowPlaying.title.isEmpty || !nowPlaying.artist.isEmpty

        Group {
            if hasContent {
                musicContent(nowPlaying: nowPlaying)
            } else if container.ble.state == .connected {
                emptyContent
            } else {
                disconnectedContent
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("Music")
    }

    // MARK: - Music Content

    private func musicContent(nowPlaying: MusicNowPlaying) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                // Album art
                albumArtSection(nowPlaying: nowPlaying)

                // Track info
                trackInfoSection(nowPlaying: nowPlaying)

                // Progress
                progressSection(nowPlaying: nowPlaying)

                // Controls
                controlsSection(nowPlaying: nowPlaying)

                // Volume
                volumeSection(nowPlaying: nowPlaying)
            }
            .padding()
        }
    }

    // MARK: - Album Art

    private func albumArtSection(nowPlaying: MusicNowPlaying) -> some View {
        Group {
            if !nowPlaying.art.isEmpty, let uiImage = UIImage(data: nowPlaying.art) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 280, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [.purple.opacity(0.3), .blue.opacity(0.2)]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 240, height: 240)

                    Image(systemName: "music.note")
                        .font(.system(size: 60))
                        .foregroundStyle(.quaternary)
                }
                .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: - Track Info

    private func trackInfoSection(nowPlaying: MusicNowPlaying) -> some View {
        VStack(spacing: 4) {
            Text(nowPlaying.title)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
                .lineLimit(1)

            if !nowPlaying.artist.isEmpty {
                Text(nowPlaying.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !nowPlaying.album.isEmpty {
                Text(nowPlaying.album)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Progress

    private func progressSection(nowPlaying: MusicNowPlaying) -> some View {
        VStack(spacing: 6) {
            ProgressView(
                value: nowPlaying.durationMs > 0
                    ? min(nowPlaying.positionMs / nowPlaying.durationMs, 1.0)
                    : 0
            )
            .tint(teal)
            .animation(.linear(duration: 0.3), value: nowPlaying.positionMs)

            HStack {
                Text(formattedTime(nowPlaying.positionMs))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(formattedTime(nowPlaying.durationMs))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Controls

    private func controlsSection(nowPlaying: MusicNowPlaying) -> some View {
        HStack(spacing: 32) {
            // Previous
            controlButton(
                icon: "backward.fill",
                action: container.music.onPreviousTrack
            )

            // Play/Pause
            Button {
                if nowPlaying.playing {
                    container.music.onPause?()
                } else {
                    container.music.onPlay?()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(teal)
                        .frame(width: 64, height: 64)
                    Image(systemName: nowPlaying.playing ? "pause.fill" : "play.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                }
            }
            .disabled(container.music.onPlay == nil && container.music.onPause == nil)

            // Next
            controlButton(
                icon: "forward.fill",
                action: container.music.onNextTrack
            )
        }
        .padding(.vertical, 8)
    }

    private func controlButton(icon: String, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(action != nil ? .primary : .tertiary)
                .frame(width: 44, height: 44)
        }
        .disabled(action == nil)
    }

    // MARK: - Volume

    private func volumeSection(nowPlaying: MusicNowPlaying) -> some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Slider(
                    value: Binding(
                        get: { nowPlaying.volume },
                        set: { container.music.onChangeVolume?($0) }
                    ),
                    in: 0...1
                )
                .tint(teal)
                .disabled(container.music.onChangeVolume == nil)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Text("\(Int(nowPlaying.volume * 100))%")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Empty Content

    private var emptyContent: some View {
        ContentUnavailableView(
            "No Music Playing",
            systemImage: "music.note",
            description: Text("Play audio in WearLink to see now-playing info.\nMusic controls will appear here when a track is playing.")
        )
    }

    // MARK: - Disconnected Content

    private var disconnectedContent: some View {
        ContentUnavailableView(
            "Not Connected",
            systemImage: "applewatch.slash",
            description: Text("Connect to your watch to control music playback.")
        )
    }

    // MARK: - Helpers

    private func formattedTime(_ ms: Double) -> String {
        let totalSeconds = Int(ms / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Accent color

private let teal = Color(red: 0.2, green: 0.8, blue: 0.8)

#Preview {
    NavigationStack {
        MusicView()
            .environment(AppContainer())
    }
}
