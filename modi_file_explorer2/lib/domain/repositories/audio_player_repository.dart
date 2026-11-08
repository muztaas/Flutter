import 'dart:typed_data';

import '../entities/audio_playback_state.dart';
import '../entities/audio_track.dart';
import '../entities/sort_rule.dart';

abstract class AudioPlayerRepository {
  Stream<AudioPlaybackState> get states;

  Future<AudioPlaybackState?> getPlaybackState();

  Future<Uint8List?> getArtwork(String path);

  Future<List<AudioTrack>> tracksInFolder(
    String path, {
    required Set<String> extensions,
    List<String>? orderedPaths,
    SortField sortField = SortField.name,
    SortOrder sortOrder = SortOrder.ascending,
  });

  Future<void> play(
    List<AudioTrack> tracks,
    int currentIndex, {
    required String mode,
    bool preservePlayback = false,
  });

  Future<void> togglePlayback();

  Future<void> seekTo(int positionMilliseconds);

  Future<void> skipPrevious();

  Future<void> skipNext();

  Future<void> renameQueuedTrack(AudioTrack track);

  Future<void> removeQueuedTrack(String path);

  Future<void> stop();
}
