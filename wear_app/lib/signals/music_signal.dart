import 'dart:typed_data';

import 'package:signals/signals.dart';
import 'package:wear_app/ble/gatt_central_client.dart';
import 'package:wear_app/gen/wearlink.pb.dart';

/// Data class representing the currently playing music track info.
class MusicInfo {
  final String title;
  final String artist;
  final String album;
  final Uint8List? artBytes;
  final double durationMs;
  final double positionMs;
  final bool playing;
  final double volume;

  const MusicInfo({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.artBytes,
    this.durationMs = 0,
    this.positionMs = 0,
    this.playing = false,
    this.volume = 0,
  });

  MusicInfo copyWith({
    String? title,
    String? artist,
    String? album,
    Uint8List? artBytes,
    double? durationMs,
    double? positionMs,
    bool? playing,
    double? volume,
  }) {
    return MusicInfo(
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      artBytes: artBytes ?? this.artBytes,
      durationMs: durationMs ?? this.durationMs,
      positionMs: positionMs ?? this.positionMs,
      playing: playing ?? this.playing,
      volume: volume ?? this.volume,
    );
  }
}

/// Music state store. Receives [MusicNowPlaying] frames from the BLE link
/// and exposes them as signals. Commands are sent back via [GattClient].
///
/// Usage:
/// ```dart
/// final music = MusicSignal()..gatt = gattClient;
/// ```
class MusicSignal {
  GattCentralClient? _gatt;

  /// Currently playing track info, or null if no track is active.
  final nowPlaying = signal<MusicInfo?>(null, options: SignalOptions(name: 'nowPlaying'));

  /// Current playback position in milliseconds.
  final position = signal<double>(0, options: SignalOptions(name: 'position'));

  MusicSignal();

  /// Inject the [GattClient] instance used for outbound commands.
  set gatt(GattCentralClient client) => _gatt = client;

  /// Process an inbound BLE frame.
  ///
  /// If [uuid] matches the [GattUuid.musicNowPlaying] characteristic, the
  /// payload is decoded as a [MusicNowPlaying] proto and the signals are
  /// updated. Frames for other UUIDs are silently ignored.
  void updateFromFrame(String uuid, Uint8List data) {
    if (uuid != GattCentralUuid.musicNowPlaying) return;

    final frame = MusicNowPlaying.fromBuffer(data);
    final info = MusicInfo(
      title: frame.title,
      artist: frame.artist,
      album: frame.album,
      artBytes: frame.hasArt() ? Uint8List.fromList(frame.art) : null,
      durationMs: frame.durationMs,
      positionMs: frame.positionMs,
      playing: frame.playing,
      volume: frame.volume,
    );
    nowPlaying.value = info;
    position.value = frame.positionMs;
  }

  /// Serialize and send a [MusicCommand] over BLE.
  Future<void> sendCommand(MusicCommand cmd) async {
    final gatt = _gatt;
    if (gatt == null) return;
    // Replay-protection nonce (W7). Matches CallAction's convention.
    cmd.nonce = DateTime.now().millisecondsSinceEpoch & 0xffff;
    final payload = cmd.writeToBuffer();
    await gatt.send(GattCentralUuid.musicCommand, payload);
  }

  /// Send a PLAY command.
  Future<void> play() async {
    await sendCommand(MusicCommand(
      command: MusicCommand_Command.PLAY,
    ));
  }

  /// Send a PAUSE command.
  Future<void> pause() async {
    await sendCommand(MusicCommand(
      command: MusicCommand_Command.PAUSE,
    ));
  }

  /// Send a NEXT command.
  Future<void> next() async {
    await sendCommand(MusicCommand(
      command: MusicCommand_Command.NEXT,
    ));
  }

  /// Send a PREVIOUS command.
  Future<void> previous() async {
    await sendCommand(MusicCommand(
      command: MusicCommand_Command.PREVIOUS,
    ));
  }

  /// Seek to [ms] (milliseconds) in the current track.
  Future<void> seek(double ms) async {
    await sendCommand(MusicCommand(
      command: MusicCommand_Command.SEEK,
      positionMs: ms,
    ));
  }

  /// Set volume to [v] in the range 0.0–1.0.
  Future<void> setVolume(double v) async {
    await sendCommand(MusicCommand(
      command: MusicCommand_Command.SET_VOLUME,
      volume: v,
    ));
  }


}
