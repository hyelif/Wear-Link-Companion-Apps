import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:wear_app/signals/music_signal.dart';

/// Watch music now-playing screen with circular card design for Galaxy Watch 7.
///
/// States:
/// - Idle: "No music playing" message
/// - Playing: Full now-playing UI with animated progress
/// - Paused: Same as playing but play icon shows, progress static
class MusicScreen extends StatelessWidget {
  final MusicSignal music;

  const MusicScreen({super.key, required this.music});

  @override
  Widget build(BuildContext context) {
    final info = watchSignal(context, music.nowPlaying);

    if (info == null) {
      return const _IdleState();
    }

    return _NowPlaying(
      info: info,
      position: watchSignal(context, music.position),
      music: music,
    );
  }
}

/// Shown when no track is active.
class _IdleState extends StatelessWidget {
  const _IdleState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.music_note,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              'No music playing',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Full now-playing layout with album art, metadata, progress, transport
/// controls, and volume slider.
class _NowPlaying extends StatelessWidget {
  final MusicInfo info;
  final double position;
  final MusicSignal music;

  const _NowPlaying({
    required this.info,
    required this.position,
    required this.music,
  });

  @override
  Widget build(BuildContext context) {
    final progress = info.durationMs > 0
        ? (position / info.durationMs).clamp(0.0, 1.0)
        : 0.0;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Album art (circular, large, center)
              _AlbumArt(artBytes: info.artBytes, size: 120),
              const SizedBox(height: 8),

              // Title (bold, below art)
              Text(
                info.title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 2),

              // Artist (smaller, below title)
              Text(
                info.artist,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),

              // Playback progress bar (linear)
              _ProgressBar(progress: progress),
              const SizedBox(height: 2),

              // Position + duration labels
              _TimeLabels(
                position: position,
                duration: info.durationMs,
              ),
              const SizedBox(height: 8),

              // Transport row: prev | play/pause | next (large touch targets)
              _TransportControls(
                playing: info.playing,
                onPrev: () => music.previous(),
                onPlayPause: () {
                  if (info.playing) {
                    music.pause();
                  } else {
                    music.play();
                  }
                },
                onNext: () => music.next(),
              ),
              const SizedBox(height: 8),

              // Volume slider (bottom)
              _VolumeSlider(
                volume: info.volume,
                onChanged: (v) => music.setVolume(v),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Circular album art with shadow, or a placeholder icon when no art is
/// available.
class _AlbumArt extends StatelessWidget {
  final Uint8List? artBytes;
  final double size;

  const _AlbumArt({required this.artBytes, required this.size});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget artWidget;
    if (artBytes != null && artBytes!.isNotEmpty) {
      artWidget = ClipOval(
        child: Image.memory(
          artBytes!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _PlaceholderIcon(size: size),
        ),
      );
    } else {
      artWidget = _PlaceholderIcon(size: size);
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.shadow.withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: artWidget,
    );
  }
}

/// Fallback circular icon when album art bytes are unavailable.
class _PlaceholderIcon extends StatelessWidget {
  final double size;

  const _PlaceholderIcon({required this.size});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.colorScheme.surfaceContainerHighest,
      ),
      child: Icon(
        Icons.music_note,
        size: size * 0.45,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Linear playback progress bar.
class _ProgressBar extends StatelessWidget {
  final double progress;

  const _ProgressBar({required this.progress});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value: progress,
          minHeight: 4,
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
          valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
        ),
      ),
    );
  }
}

/// Position and duration time labels on either side of the progress bar.
class _TimeLabels extends StatelessWidget {
  final double position;
  final double duration;

  const _TimeLabels({required this.position, required this.duration});

  String _formatMs(double ms) {
    if (ms <= 0) return '0:00';
    final totalSeconds = (ms / 1000).round();
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(_formatMs(position), style: style),
          Text(_formatMs(duration), style: style),
        ],
      ),
    );
  }
}

/// Transport row: previous, play/pause (prominent), next.
class _TransportControls extends StatelessWidget {
  final bool playing;
  final VoidCallback onPrev;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;

  const _TransportControls({
    required this.playing,
    required this.onPrev,
    required this.onNext,
    required this.onPlayPause,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _TransportButton(
          icon: Icons.skip_previous,
          onTap: onPrev,
        ),
        _PlayPauseButton(
          playing: playing,
          onTap: onPlayPause,
        ),
        _TransportButton(
          icon: Icons.skip_next,
          onTap: onNext,
        ),
      ],
    );
  }
}

/// A single transport button (prev / next) with a large touch target.
class _TransportButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _TransportButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      height: 48,
      child: IconButton(
        icon: Icon(icon),
        iconSize: 28,
        onPressed: onTap,
        splashRadius: 24,
      ),
    );
  }
}

/// Prominent circular play/pause button filled with the primary color.
class _PlayPauseButton extends StatelessWidget {
  final bool playing;
  final VoidCallback onTap;

  const _PlayPauseButton({required this.playing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.colorScheme.primary,
      ),
      child: IconButton(
        icon: Icon(playing ? Icons.pause : Icons.play_arrow),
        iconSize: 32,
        color: theme.colorScheme.onPrimary,
        onPressed: onTap,
        splashRadius: 28,
      ),
    );
  }
}

/// Volume slider with a mute/volume icon on the left.
class _VolumeSlider extends StatelessWidget {
  final double volume;
  final ValueChanged<double> onChanged;

  const _VolumeSlider({required this.volume, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Icon(
          volume > 0.5
              ? Icons.volume_up
              : volume > 0.0
                  ? Icons.volume_down
                  : Icons.volume_mute,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: theme.colorScheme.primary,
              inactiveTrackColor: theme.colorScheme.surfaceContainerHighest,
              thumbColor: theme.colorScheme.primary,
            ),
            child: Slider(
              value: volume.clamp(0.0, 1.0),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}
