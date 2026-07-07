import Foundation
import MediaPlayer
import UIKit

// MARK: - Reconnection notification

extension Notification.Name {
    /// Posted when BLE establishes a new GATT connection, so feature
    /// controllers can re-register their inbound payload handlers.
    static let bleDidReconnect = Notification.Name("com.wearlink.ble.didReconnect")
}

/// Publishes now-playing info to the watch and dispatches transport commands
/// received from the watch to `MPRemoteCommandCenter`.
///
/// FLOW:
/// 1. App plays audio, calls `publishNowPlaying(...)`.
/// 2. MusicController updates `MPNowPlayingInfoCenter` and encodes a
///    `MusicNowPlaying` proto, writing it to `WearLinkUUID.musicNowPlaying`
///    via BLE (notify characteristic).
/// 3. Watch receives the now-playing info and shows its UI.
/// 4. User taps play/pause/next/prev on the watch.
/// 5. Watch sends a `MusicCommand` proto over BLE.
/// 6. MusicController receives it via `GattClient.onPayload[.musicCommand]`,
///    decodes it, and dispatches to the corresponding `MPRemoteCommandCenter`
///    handler (which the app's audio player responds to).
///
/// HARD LIMIT — see Software-Structure §9:
/// `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` apply to THIS app's own
/// audio session. Controlling OTHER apps' playback (Spotify/Apple Music)
/// requires the private `MediaRemote` framework -> App Store rejection.
/// Scope = own-app media only.
@MainActor
@Observable
final class MusicController: NSObject {
    private let ble: BLEManager
    private var updateTimer: Timer?
    private var lastPositionUpdate: Date?

    /// Weak reference to the `GattClient` we last registered the command
    /// handler on. Used to detect reconnections and avoid redundant or
    /// orphaned registrations.
    private weak var registeredGatt: AnyObject?

    /// Opaque handler references returned by `MPRemoteCommand.addTarget(handler:)`,
    /// retained so they can be removed in `deinit`.
    private var remoteCommandHandlers: [Any] = []

    private(set) var nowPlaying = MusicNowPlaying(
        title: "", artist: "", album: "", art: Data(),
        durationMs: 0, positionMs: 0, playing: false, volume: 0
    )

    // MARK: - Command callbacks

    /// Called when the user (or watch) requests play.
    var onPlay: (() -> Void)?
    /// Called when the user (or watch) requests pause.
    var onPause: (() -> Void)?
    /// Called when the user (or watch) requests next track.
    var onNextTrack: (() -> Void)?
    /// Called when the user (or watch) requests previous track.
    var onPreviousTrack: (() -> Void)?
    /// Called when the user (or watch) seeks to a position (seconds).
    var onSeek: ((TimeInterval) -> Void)?
    /// Called when the watch sets volume (0.0 - 1.0).
    var onChangeVolume: ((Float) -> Void)?

    // MARK: - Init

    init(ble: BLEManager) {
        self.ble = ble
        super.init()
        setupRemoteCommands()
        registerCommandHandler()
        observeReconnection()
    }

    deinit {
        updateTimer?.invalidate()
        removeRemoteCommands()
    }

    // MARK: - MPRemoteCommandCenter setup

    /// Registers handlers on `MPRemoteCommandCenter` so that lock-screen /
    /// control-center / CarPlay events are forwarded to the app's audio player
    /// via the command callbacks.
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        let playHandler = center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .noSuchAction }
            self.onPlay?()
            return .success
        }
        remoteCommandHandlers.append(playHandler)

        let pauseHandler = center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .noSuchAction }
            self.onPause?()
            return .success
        }
        remoteCommandHandlers.append(pauseHandler)

        let toggleHandler = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .noSuchAction }
            if self.nowPlaying.playing {
                self.onPause?()
            } else {
                self.onPlay?()
            }
            return .success
        }
        remoteCommandHandlers.append(toggleHandler)

        let nextHandler = center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .noSuchAction }
            self.onNextTrack?()
            return .success
        }
        remoteCommandHandlers.append(nextHandler)

        let prevHandler = center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .noSuchAction }
            self.onPreviousTrack?()
            return .success
        }
        remoteCommandHandlers.append(prevHandler)

        let seekHandler = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            self.onSeek?(positionEvent.positionTime)
            return .success
        }
        remoteCommandHandlers.append(seekHandler)
    }

    /// Removes all registered `MPRemoteCommandCenter` handlers.
    /// Called from `deinit` to prevent orphaned handler references.
    private func removeRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        for handler in remoteCommandHandlers {
            // Each handler is an opaque MPRemoteCommandHandler object returned
            // by addTarget(handler:). Passing it to removeTarget(_:) unregisters
            // only that specific block-based handler.
            center.playCommand.removeTarget(handler)
            center.pauseCommand.removeTarget(handler)
            center.togglePlayPauseCommand.removeTarget(handler)
            center.nextTrackCommand.removeTarget(handler)
            center.previousTrackCommand.removeTarget(handler)
            center.changePlaybackPositionCommand.removeTarget(handler)
        }
        remoteCommandHandlers.removeAll()
    }

    // MARK: - Reconnection observation

    /// Registers for `Notification.Name.bleDidReconnect` so the BLE command
    /// handler is re-registered on the new `GattClient` after a reconnect.
    private func observeReconnection() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleReconnection),
            name: .bleDidReconnect,
            object: nil
        )
    }

    @objc private func handleReconnection() {
        registerCommandHandler()
    }

    // MARK: - BLE command handler

    /// Registers the inbound `MusicCommand` handler on the current `GattClient`.
    ///
    /// If the `GattClient` instance has changed since the last call (e.g. after
    /// a disconnect-reconnect cycle), the old handler is effectively orphaned
    /// and a new one is registered on the current client. If `gatt` is `nil`
    /// the call is a no-op — the handler will be set when `handleReconnection()`
    /// fires or when `registerCommandHandler()` is called again.
    private func registerCommandHandler() {
        guard let gatt = ble.gatt else { return }
        // Avoid redundant registration on the same GattClient instance.
        guard registeredGatt !== gatt else { return }

        gatt.onPayload[WearLinkUUID.musicCommand] = { [weak self] data in
            guard let self,
                  let command = ProtoCodec.decodeMusicCommand(from: data)
            else { return }
            Task { @MainActor in
                self.dispatchCommand(command)
            }
        }
        registeredGatt = gatt
    }

    /// Maps a decoded `MusicCommand` from the watch to the appropriate
    /// command callback.
    func dispatchCommand(_ command: MusicCommand) {
        switch command.command {
        case .play:
            onPlay?()
        case .pause:
            onPause?()
        case .next:
            onNextTrack?()
        case .previous:
            onPreviousTrack?()
        case .seek:
            // Watch sends position in milliseconds; convert to seconds.
            onSeek?(command.positionMs / 1000.0)
        case .setVolume:
            // Clamp volume to valid range [0, 1].
            onChangeVolume?(min(max(command.volume, 0), 1))
        case .cmdUnspecified:
            break
        }
    }

    // MARK: - Publishing now-playing info

    /// Called by the app's audio player whenever playback state or metadata
    /// changes.
    ///
    /// - Parameters:
    ///   - title: Track title.
    ///   - artist: Track artist.
    ///   - album: Album name (optional).
    ///   - art: Cover art image data (JPEG/PNG, optional).
    ///   - duration: Total track duration in seconds.
    ///   - position: Current playback position in seconds.
    ///   - playing: Whether the track is currently playing.
    ///   - volume: Current volume level (0.0 - 1.0). When `nil`, falls back to
    ///     the system output volume from `AVAudioSession`.
    func publishNowPlaying(
        title: String,
        artist: String,
        album: String = "",
        art: Data = Data(),
        duration: TimeInterval,
        position: TimeInterval,
        playing: Bool,
        volume: Float? = nil
    ) {
        let effectiveVolume = volume ?? AVAudioSession.sharedInstance().outputVolume

        let info = MusicNowPlaying(
            title: title,
            artist: artist,
            album: album,
            art: art,
            durationMs: duration * 1000,
            positionMs: position * 1000,
            playing: playing,
            volume: effectiveVolume
        )

        nowPlaying = info
        lastPositionUpdate = playing ? Date() : nil

        updateNowPlayingInfoCenter(info)
        sendToWatch(info)

        if playing {
            startPositionUpdates()
        } else {
            stopPositionUpdates()
        }
    }

    /// Writes the current now-playing metadata to `MPNowPlayingInfoCenter`
    /// so the system lock screen / control center displays it.
    private func updateNowPlayingInfoCenter(_ info: MusicNowPlaying) {
        var mpInfo: [String: Any] = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyArtist: info.artist,
            MPMediaItemPropertyAlbumTitle: info.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.positionMs / 1000.0,
            MPMediaItemPropertyPlaybackDuration: info.durationMs / 1000.0,
            MPNowPlayingInfoPropertyPlaybackRate: info.playing ? 1.0 : 0.0,
        ]

        if !info.art.isEmpty, let image = UIImage(data: info.art) {
            let artwork = MPMediaItemArtwork(
                boundsSize: image.size,
                requestHandler: { _ in image }
            )
            mpInfo[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = mpInfo
    }

    /// Encodes the now-playing info as a `MusicNowPlaying` proto and writes
    /// it to the watch via the `musicNowPlaying` notify characteristic.
    private func sendToWatch(_ info: MusicNowPlaying) {
        let payload = ProtoCodec.encodeMusicNowPlaying(info)
        ble.gatt?.write(payload, to: WearLinkUUID.musicNowPlaying)
    }

    // MARK: - Periodic position updates

    /// Starts a 1-second timer that advances the playback position and pushes
    /// updates to both `MPNowPlayingInfoCenter` and the watch.
    private func startPositionUpdates() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.nowPlaying.playing else { return }

            let now = Date()
            if let lastUpdate = self.lastPositionUpdate {
                let elapsedMs = now.timeIntervalSince(lastUpdate) * 1000
                self.nowPlaying.positionMs += elapsedMs
            }
            self.lastPositionUpdate = now

            // Update MPNowPlayingInfoCenter with the new position.
            var mpInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            mpInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = self.nowPlaying.positionMs / 1000.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = mpInfo

            // Push the updated position to the watch.
            let payload = ProtoCodec.encodeMusicNowPlaying(self.nowPlaying)
            self.ble.gatt?.write(payload, to: WearLinkUUID.musicNowPlaying)
        }
    }

    /// Stops the periodic position update timer.
    private func stopPositionUpdates() {
        updateTimer?.invalidate()
        updateTimer = nil
        lastPositionUpdate = nil
    }
}
