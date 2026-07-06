import Foundation
import MediaPlayer

/// Publishes now-playing info to the watch and applies transport commands
/// received from the watch.
///
/// HARD LIMIT — see Software-Structure §9:
/// `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` apply to THIS app's own
/// audio session. Controlling OTHER apps' playback (Spotify/Apple Music)
/// requires the private `MediaRemote` framework → App Store rejection.
/// Scope = own-app media only.
@MainActor
@Observable
final class MusicController {
    private let ble: BLEManager

    init(ble: BLEManager) { self.ble = ble }

    func publishNowPlaying(title: String, artist: String, duration: Double, position: Double, playing: Bool) {
        // TODO: encode MusicNowPlaying proto, ble.gatt?.write(_, to: musicNowPlaying)
        _ = (title, artist, duration, position, playing)
    }

    /// Watch sent a transport command.
    func handleCommand(_ command: MusicCommand) {
        // TODO: dispatch to MPRemoteCommandCenter for this app's session.
    }
}

enum MusicCommand { case play, pause, next, previous, seek(Double), volume(Float) }