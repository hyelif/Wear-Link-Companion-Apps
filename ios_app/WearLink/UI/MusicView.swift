import SwiftUI

struct MusicView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        let nowPlaying = container.music.nowPlaying

        return List {
            if nowPlaying.title.isEmpty && nowPlaying.artist.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Music Playing",
                        systemImage: "music.note",
                        description: Text("Play audio in WearLink to see now-playing info.")
                    )
                }
            } else {
                Section("Now Playing") {
                    HStack {
                        if !nowPlaying.art.isEmpty,
                           let uiImage = UIImage(data: nowPlaying.art) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .frame(width: 60, height: 60)
                                .cornerRadius(8)
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.quaternary)
                                .frame(width: 60, height: 60)
                                .overlay {
                                    Image(systemName: "music.note")
                                        .foregroundStyle(.secondary)
                                }
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(nowPlaying.title)
                                .font(.headline)
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
                        .padding(.leading, 8)
                    }
                }

                Section("Progress") {
                    VStack(spacing: 8) {
                        ProgressView(
                            value: nowPlaying.durationMs > 0
                                ? nowPlaying.positionMs / nowPlaying.durationMs
                                : 0
                        )
                        .tint(.accentColor)

                        HStack {
                            Text(formattedTime(nowPlaying.positionMs))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(formattedTime(nowPlaying.durationMs))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Controls") {
                    HStack {
                        Spacer()
                        Button { container.music.onPreviousTrack?() } label: {
                            Image(systemName: "backward.fill")
                                .font(.title2)
                        }
                        .disabled(container.music.onPreviousTrack == nil)

                        Spacer()

                        Button {
                            if nowPlaying.playing {
                                container.music.onPause?()
                            } else {
                                container.music.onPlay?()
                            }
                        } label: {
                            Image(
                                systemName: nowPlaying.playing
                                    ? "pause.circle.fill"
                                    : "play.circle.fill"
                            )
                            .font(.system(size: 44))
                        }
                        .disabled(
                            container.music.onPlay == nil
                            && container.music.onPause == nil
                        )

                        Spacer()

                        Button { container.music.onNextTrack?() } label: {
                            Image(systemName: "forward.fill")
                                .font(.title2)
                        }
                        .disabled(container.music.onNextTrack == nil)

                        Spacer()
                    }
                    .padding(.vertical, 8)
                }

                Section("Volume") {
                    VStack(spacing: 4) {
                        Slider(
                            value: Binding(
                                get: { nowPlaying.volume },
                                set: { container.music.onChangeVolume?($0) }
                            ),
                            in: 0...1
                        )
                        .disabled(container.music.onChangeVolume == nil)

                        HStack {
                            Image(systemName: "speaker.fill")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(nowPlaying.volume * 100))%")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "speaker.wave.3.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Music")
    }

    private func formattedTime(_ ms: Double) -> String {
        let totalSeconds = Int(ms / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
