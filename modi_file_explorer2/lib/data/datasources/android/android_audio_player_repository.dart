import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../domain/entities/audio_playback_state.dart';
import '../../../domain/entities/audio_track.dart';
import '../../../domain/entities/sort_rule.dart';
import '../../../domain/repositories/audio_player_repository.dart';
import '../../../core/utils/file_name_comparator.dart';

class AndroidAudioPlayerRepository implements AudioPlayerRepository {
  AndroidAudioPlayerRepository() {
    _subscription = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: _onStreamError,
    );
  }

  static const _methods = MethodChannel('modi_file_explorer2/audio_player');
  static const _events = EventChannel(
    'modi_file_explorer2/audio_player/events',
  );

  final StreamController<AudioPlaybackState> _states =
      StreamController<AudioPlaybackState>.broadcast();
  late final StreamSubscription<Object?> _subscription;

  @override
  Stream<AudioPlaybackState> get states => _states.stream;

  @override
  Future<AudioPlaybackState?> getPlaybackState() async {
    final payload = await _methods.invokeMapMethod<String, Object?>(
      'getPlaybackState',
    );
    return payload == null
        ? null
        : _parseState(Map<Object?, Object?>.from(payload));
  }

  @override
  Future<Uint8List?> getArtwork(String path) =>
      _methods.invokeMethod<Uint8List>('getArtwork', path);

  @override
  Future<List<AudioTrack>> tracksInFolder(
    String path, {
    required Set<String> extensions,
    List<String>? orderedPaths,
    SortField sortField = SortField.name,
    SortOrder sortOrder = SortOrder.ascending,
  }) async {
    final folderPath = File(path).parent.path;
    final paths = orderedPaths;
    final source = <String>[];
    if (paths != null) {
      source.addAll(paths);
    } else {
      await for (final entity in Directory(
        folderPath,
      ).list(followLinks: false)) {
        if (entity is File) source.add(entity.path);
      }
    }
    if (!source.contains(path)) source.add(path);

    final tracks = <AudioTrack>[];
    for (final trackPath in source) {
      final name = _basename(trackPath);
      if (!extensions.contains(_extension(name))) continue;
      final file = File(trackPath);
      try {
        final stat = await file.stat();
        if (stat.type != FileSystemEntityType.file) continue;
        tracks.add(
          AudioTrack(
            path: trackPath,
            title: name,
            folder: _basename(File(trackPath).parent.path),
            size: stat.size,
            modifiedMilliseconds: stat.modified.millisecondsSinceEpoch,
          ),
        );
      } on FileSystemException catch (error) {
        if (trackPath == path) rethrow;
        debugPrint('Skipping unavailable audio file $trackPath: $error');
      }
    }
    if (paths == null) {
      int compare(AudioTrack left, AudioTrack right) {
        final comparison = switch (sortField) {
          SortField.name => compareStorageNames(left.title, right.title),
          SortField.dateModified => left.modifiedMilliseconds.compareTo(
            right.modifiedMilliseconds,
          ),
          SortField.size => left.size.compareTo(right.size),
        };
        final ordered = comparison == 0
            ? compareStorageNames(left.title, right.title)
            : comparison;
        return (sortOrder == SortOrder.ascending ? ordered : -ordered);
      }

      tracks.sort(compare);
    }
    return tracks;
  }

  @override
  Future<void> play(
    List<AudioTrack> tracks,
    int currentIndex, {
    required String mode,
    bool preservePlayback = false,
  }) async {
    if (tracks.isEmpty || currentIndex < 0 || currentIndex >= tracks.length) {
      throw ArgumentError('The audio playlist or selected track is invalid');
    }
    await _methods.invokeMethod<void>('playQueue', {
      'tracks': tracks
          .map(
            (track) => {
              'path': track.path,
              'title': track.title,
              'folder': track.folder,
            },
          )
          .toList(growable: false),
      'currentIndex': currentIndex,
      'mode': mode,
      'preservePlayback': preservePlayback,
    });
  }

  @override
  Future<void> togglePlayback() =>
      _methods.invokeMethod<void>('togglePlayback');

  @override
  Future<void> seekTo(int positionMilliseconds) =>
      _methods.invokeMethod<void>('seekTo', positionMilliseconds);

  @override
  Future<void> skipPrevious() => _methods.invokeMethod<void>('skipPrevious');

  @override
  Future<void> skipNext() => _methods.invokeMethod<void>('skipNext');

  @override
  Future<void> renameQueuedTrack(AudioTrack track) =>
      _methods.invokeMethod<void>('renameQueuedTrack', {
        'path': track.path,
        'title': track.title,
        'folder': track.folder,
      });

  @override
  Future<void> removeQueuedTrack(String path) =>
      _methods.invokeMethod<void>('removeQueuedTrack', path);

  @override
  Future<void> stop() => _methods.invokeMethod<void>('stopPlayback');

  void dispose() {
    unawaited(_subscription.cancel());
    unawaited(_states.close());
  }

  void _onEvent(Object? event) {
    if (event is! Map) return;
    final payload = Map<Object?, Object?>.from(event);
    _states.add(_parseState(payload));
  }

  AudioPlaybackState _parseState(Map<Object?, Object?> payload) =>
      AudioPlaybackState(
        isPlaying: payload['isPlaying'] as bool? ?? false,
        isLoading: payload['isLoading'] as bool? ?? false,
        path: payload['path'] as String?,
        title: payload['title'] as String?,
        folder: payload['folder'] as String?,
        positionMilliseconds:
            (payload['positionMilliseconds'] as num?)?.toInt() ?? 0,
        durationMilliseconds:
            (payload['durationMilliseconds'] as num?)?.toInt() ?? 0,
        queueIndex: (payload['queueIndex'] as num?)?.toInt() ?? 0,
        queueLength: (payload['queueLength'] as num?)?.toInt() ?? 0,
        mode: payload['mode'] as String? ?? 'folder',
        error: payload['error'] as String?,
        isStopped: payload['isStopped'] as bool? ?? false,
        notificationTapped: payload['notificationTapped'] as bool? ?? false,
      );

  void _onStreamError(Object error, StackTrace stackTrace) {
    debugPrint('Audio player event stream failed: $error');
    _states.add(
      AudioPlaybackState(error: 'The audio player connection was interrupted'),
    );
  }

  String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.split('/').where((part) => part.isNotEmpty).lastOrNull ??
        path;
  }

  String _extension(String name) {
    final separator = name.lastIndexOf('.');
    return separator <= 0 ? '' : name.substring(separator).toLowerCase();
  }
}
