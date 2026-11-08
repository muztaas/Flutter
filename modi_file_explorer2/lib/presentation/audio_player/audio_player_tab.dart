import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/filesystem/file_change_notifier.dart';
import '../../core/providers/audio_player_provider.dart';
import '../../core/providers/sort_rules_provider.dart';
import '../../core/providers/storage_providers.dart';
import '../../core/tabs/tabs_manager.dart';
import '../../core/utils/file_type_colors.dart';
import '../../domain/entities/audio_play_mode.dart';
import '../../domain/entities/audio_playback_state.dart';
import '../../domain/entities/audio_track.dart';
import '../common/detected_content_recovery.dart';
import '../../domain/entities/sort_rule.dart';
import '../../domain/entities/storage_device.dart';
import '../../domain/repositories/audio_player_repository.dart';
import '../../domain/usecases/resolve_effective_sort_rule.dart';
import '../common/animated_bar_visibility.dart';

class AudioPlayerTab extends ConsumerStatefulWidget {
  const AudioPlayerTab({
    super.key,
    required this.path,
    required this.extensions,
    required this.onTitleChanged,
    required this.onBack,
    this.queuePaths,
  });

  final String path;
  final Set<String> extensions;
  final List<String>? queuePaths;
  final ValueChanged<String> onTitleChanged;
  final VoidCallback onBack;

  @override
  ConsumerState<AudioPlayerTab> createState() => _AudioPlayerTabState();
}

class _AudioPlayerTabState extends ConsumerState<AudioPlayerTab> {
  StreamSubscription<AudioPlaybackState>? _subscription;
  StreamSubscription<FileChangeEvent>? _fileChangeSubscription;
  AudioPlaybackState _state = const AudioPlaybackState();
  List<AudioTrack> _folderTracks = const [];
  AudioPlayMode? _mode;
  String? _currentPath;
  String? _loadError;
  double? _seekPreviewMilliseconds;
  Uint8List? _artworkBytes;
  String? _artworkPath;
  int _artworkRequestId = 0;
  bool _nameLayerVisible = true;
  bool _isClosing = false;
  int _loadRequestId = 0;
  int _playbackEventRevision = 0;

  List<AudioTrack> get _activeQueue => _mode == AudioPlayMode.singleTrack
      ? _folderTracks.where((track) => track.path == _currentPath).toList()
      : _folderTracks;

  @override
  void initState() {
    super.initState();
    _subscription = ref
        .read(audioPlayerRepositoryProvider)
        .states
        .listen(_onPlaybackState);
    _fileChangeSubscription = FileChangeNotifier.instance.changes.listen(
      _onFileChanges,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_restorePlaybackOrOpenInitialTrack());
    });
  }

  @override
  void didUpdateWidget(covariant AudioPlayerTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      unawaited(_openTrack(widget.path));
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_fileChangeSubscription?.cancel());
    super.dispose();
  }

  Future<void> _restorePlaybackOrOpenInitialTrack() async {
    final repository = ref.read(audioPlayerRepositoryProvider);
    try {
      final revision = _playbackEventRevision;
      final fetchedPlayback = await repository.getPlaybackState();
      final playback = revision == _playbackEventRevision
          ? fetchedPlayback
          : _state;
      final activePath = playback?.path;
      if (!mounted || _isClosing) return;
      if (playback == null || activePath == null || playback.queueLength == 0) {
        await _openTrack(widget.path);
        return;
      }

      _currentPath = activePath;
      _mode = playback.mode == AudioPlayMode.singleTrack.name
          ? AudioPlayMode.singleTrack
          : AudioPlayMode.folder;
      setState(() {
        _state = playback;
        _loadError = null;
      });
      widget.onTitleChanged(playback.title ?? _fileName(activePath));
      unawaited(_loadArtwork(activePath));
      _folderTracks = await _createFolderSnapshot(activePath, repository);
    } catch (error) {
      if (!mounted || _isClosing) return;
      debugPrint('Could not restore active audio playback state: $error');
      setState(() {
        _loadError = 'Could not reconnect to audio playback: $error';
      });
    }
  }

  Future<void> _openTrack(String path) async {
    final requestId = ++_loadRequestId;
    _currentPath = path;
    if (mounted) {
      setState(() {
        _loadError = null;
        _state = const AudioPlaybackState(isLoading: true);
      });
    }
    try {
      await _requestNotificationPermissionIfNeeded();
      if (!mounted || _isClosing || requestId != _loadRequestId) return;
      final repository = ref.read(audioPlayerRepositoryProvider);
      _folderTracks = await _createFolderSnapshot(path, repository);
      if (!mounted || _isClosing || requestId != _loadRequestId) return;
      _mode ??= await _loadPlayMode();
      if (!mounted || _isClosing || requestId != _loadRequestId) return;
      final queue = _activeQueue;
      final index = queue.indexWhere((track) => track.path == path);
      if (index < 0) {
        throw FileSystemException(
          'The selected audio file is unavailable',
          path,
        );
      }
      await repository.play(
        queue,
        index,
        mode: _mode!.name,
        preservePlayback: true,
      );
    } catch (error) {
      if (!mounted || requestId != _loadRequestId) return;
      setState(() {
        _loadError = 'Could not play ${_fileName(path)}: $error';
        _state = AudioPlaybackState(
          title: _fileName(path),
          folder: _folderName(path),
          path: path,
          error: _loadError,
        );
      });
    }
  }

  Future<List<AudioTrack>> _createFolderSnapshot(
    String path,
    AudioPlayerRepository repository,
  ) async {
    await ref.read(sortRulesProvider.notifier).ready;
    final devices =
        ref.read(availableStorageDevicesProvider).asData?.value ??
        const <StorageDevice>[];
    final folderPath = File(path).parent.path;
    final normalizedFolder = normalizeSortPath(folderPath);
    final roots =
        devices.map((device) => device).where((device) {
          final root = normalizeSortPath(device.path);
          return normalizedFolder == root ||
              normalizedFolder.startsWith('$root/');
        }).toList()..sort(
          (left, right) => normalizeSortPath(
            right.path,
          ).length.compareTo(normalizeSortPath(left.path).length),
        );
    final drivePath = roots.isEmpty ? folderPath : roots.first.path;
    final driveId = roots.isEmpty ? null : roots.first.id;
    final rules =
        ref.read(sortRulesProvider).asData?.value ?? const <SortRule>[];
    final rule = resolveEffectiveSortRule(
      rules: rules,
      drivePath: drivePath,
      driveId: driveId,
      folderPath: folderPath,
    );
    return repository.tracksInFolder(
      path,
      extensions: widget.extensions,
      orderedPaths: widget.queuePaths,
      sortField: rule?.field ?? SortField.name,
      sortOrder: rule?.order ?? SortOrder.ascending,
    );
  }

  Future<AudioPlayMode> _loadPlayMode() async {
    final preferences = await SharedPreferences.getInstance();
    return AudioPlayMode.values
            .where(
              (mode) => mode.name == preferences.getString('audio.playMode'),
            )
            .firstOrNull ??
        AudioPlayMode.folder;
  }

  Future<void> _requestNotificationPermissionIfNeeded() async {
    if (!Platform.isAndroid) return;
    final permissionStatus = await Permission.notification.status;
    if (permissionStatus.isGranted) return;
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getBool('audio.notificationPermissionAsked') ?? false) {
      return;
    }
    await preferences.setBool('audio.notificationPermissionAsked', true);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Allow audio notifications?'),
        content: const Text(
          'Notifications show the current track and let you control audio '
          'while the app is in the background.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    await Permission.notification.request();
  }

  void _onPlaybackState(AudioPlaybackState state) {
    if (!mounted || _isClosing) return;
    _playbackEventRevision++;
    setState(() => _state = state);
    _mode = state.mode == AudioPlayMode.singleTrack.name
        ? AudioPlayMode.singleTrack
        : AudioPlayMode.folder;
    if (state.path != null) {
      _currentPath = state.path;
      if (_artworkPath != state.path) {
        unawaited(_loadArtwork(state.path!));
      }
    }
    if (state.notificationTapped) {
      final tab = TabsManager.instance.audioPlayerTab;
      if (tab != null) TabsManager.instance.focusTabById(tab.id);
    }

    final title = state.title;
    if (title != null && title.isNotEmpty) {
      widget.onTitleChanged(title);
    }
    if (state.error != null && state.error!.isNotEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(state.error!)));
    }
    if (state.isStopped) {
      _isClosing = true;
      final tab = TabsManager.instance.audioPlayerTab;
      if (tab != null) TabsManager.instance.closeTab(tab);
    }
  }

  Future<void> _loadArtwork(String path) async {
    final requestId = ++_artworkRequestId;
    _artworkPath = path;
    if (mounted) setState(() => _artworkBytes = null);
    try {
      final artwork = await ref
          .read(audioPlayerRepositoryProvider)
          .getArtwork(path);
      if (!mounted || requestId != _artworkRequestId || _artworkPath != path) {
        return;
      }
      setState(() => _artworkBytes = artwork);
    } catch (error) {
      if (!mounted || requestId != _artworkRequestId) return;
      debugPrint('Could not load audio artwork for $path: $error');
    }
  }

  Future<void> _changeMode(AudioPlayMode mode) async {
    if (_mode == mode || _folderTracks.isEmpty) return;
    final currentPath = _currentPath;
    if (currentPath == null) return;
    final previousMode = _mode;
    if (previousMode == null) return;
    try {
      final queue = mode == AudioPlayMode.singleTrack
          ? _folderTracks.where((track) => track.path == currentPath).toList()
          : _folderTracks;
      final index = queue.indexWhere((track) => track.path == currentPath);
      if (index < 0) {
        throw StateError('The current audio is no longer in the queue');
      }
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('audio.playMode', mode.name);
      try {
        await ref
            .read(audioPlayerRepositoryProvider)
            .play(queue, index, mode: mode.name, preservePlayback: true);
      } catch (_) {
        await preferences.setString('audio.playMode', previousMode.name);
        rethrow;
      }
      if (!mounted) return;
      setState(() => _mode = mode);
    } catch (error) {
      if (!mounted) return;
      _showPlaybackError('Could not change the play mode: $error');
    }
  }

  void _onFileChanges(FileChangeEvent event) {
    if (_folderTracks.isEmpty || _isClosing) return;
    unawaited(_reconcileFileChanges(event));
  }

  Future<void> _reconcileFileChanges(FileChangeEvent event) async {
    final oldTracks = _folderTracks;
    final currentPath = _currentPath;
    if (currentPath == null) return;
    final oldIndex = oldTracks.indexWhere((track) => track.path == currentPath);
    final renames = <AudioTrack>[];
    final renamedTracksByOldPath = <String, AudioTrack>{};
    final removedPaths = <String>[];
    var changed = false;
    final updated = <AudioTrack>[];
    for (final track in oldTracks) {
      final rename = event.changes
          .where(
            (change) => change.oldPath == track.path && change.newPath != null,
          )
          .firstOrNull;
      if (rename != null) {
        final newPath = rename.newPath!;
        if (widget.extensions.contains(_extension(newPath))) {
          final renamedTrack = track.copyWith(
            path: newPath,
            title: _fileName(newPath),
            folder: _folderName(newPath),
          );
          updated.add(renamedTrack);
          renames.add(renamedTrack);
          renamedTracksByOldPath[track.path] = renamedTrack;
        } else {
          removedPaths.add(track.path);
        }
        changed = true;
        continue;
      }
      final isRelevantFolder = event.affectedFolders.contains(
        File(track.path).parent.path,
      );
      if (isRelevantFolder && !await File(track.path).exists()) {
        removedPaths.add(track.path);
        changed = true;
        continue;
      }
      updated.add(track);
    }
    if (!changed || !mounted || _isClosing) return;
    _folderTracks = updated;
    var nextCurrentPath =
        renamedTracksByOldPath[currentPath]?.path ?? currentPath;
    if (!updated.any((track) => track.path == nextCurrentPath)) {
      final currentWasRemoved = oldIndex >= 0;
      final nextTrack = oldTracks
          .skip(oldIndex + 1)
          .map((track) => renamedTracksByOldPath[track.path] ?? track)
          .firstWhere(
            (track) => updated.any((candidate) => candidate.path == track.path),
            orElse: () => const AudioTrack(path: '', title: '', folder: ''),
          );
      if (_mode != AudioPlayMode.folder ||
          !currentWasRemoved ||
          nextTrack.path.isEmpty) {
        _showPlaybackError('The current audio file was removed.');
        await ref.read(audioPlayerRepositoryProvider).stop();
        return;
      }
      nextCurrentPath = nextTrack.path;
    }
    _currentPath = nextCurrentPath;
    try {
      final repository = ref.read(audioPlayerRepositoryProvider);
      if (_mode == AudioPlayMode.folder) {
        for (final track in renames) {
          await repository.renameQueuedTrack(track);
        }
        for (final path in removedPaths) {
          await repository.removeQueuedTrack(path);
        }
      } else if (currentPath != nextCurrentPath) {
        final renamedCurrent = renames
            .where((track) => track.path == nextCurrentPath)
            .firstOrNull;
        if (renamedCurrent != null) {
          await repository.renameQueuedTrack(renamedCurrent);
        } else {
          await repository.removeQueuedTrack(currentPath);
        }
      }
    } catch (error) {
      if (mounted) {
        _showPlaybackError('Could not update the audio queue: $error');
      }
    }
  }

  Future<void> _togglePlayback() => _runPlayerAction(
    () => ref.read(audioPlayerRepositoryProvider).togglePlayback(),
    'Could not control audio playback',
  );

  Future<void> _skipPrevious() => _runPlayerAction(
    () => ref.read(audioPlayerRepositoryProvider).skipPrevious(),
    'Could not go to the previous track',
  );

  Future<void> _skipNext() => _runPlayerAction(
    () => ref.read(audioPlayerRepositoryProvider).skipNext(),
    'Could not go to the next track',
  );

  Future<void> _seekTo(double milliseconds) => _runPlayerAction(
    () => ref.read(audioPlayerRepositoryProvider).seekTo(milliseconds.round()),
    'Could not seek in the current track',
  );

  Future<void> _runPlayerAction(
    Future<void> Function() action,
    String message,
  ) async {
    try {
      await action();
    } catch (error) {
      if (mounted) _showPlaybackError('$message: $error');
    }
  }

  void _showPlaybackError(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _fileName(String path) =>
      path
          .split(RegExp(r'[/\\]'))
          .where((part) => part.isNotEmpty)
          .lastOrNull ??
      path;

  String _folderName(String path) {
    final parent = File(path).parent.path;
    return parent
            .split(RegExp(r'[/\\]'))
            .where((part) => part.isNotEmpty)
            .lastOrNull ??
        parent;
  }

  String _extension(String path) {
    final name = _fileName(path);
    final separator = name.lastIndexOf('.');
    return separator <= 0 ? '' : name.substring(separator).toLowerCase();
  }

  String _formatTime(int milliseconds) {
    final seconds = milliseconds ~/ 1000;
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final remainingSeconds = seconds % 60;
    final twoDigits = remainingSeconds.toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:${minutes.toString().padLeft(2, '0')}:$twoDigits'
        : '$minutes:$twoDigits';
  }

  @override
  Widget build(BuildContext context) {
    final title = _state.title ?? _fileName(widget.path);
    final folder = _state.folder ?? _folderName(_state.path ?? widget.path);
    final duration = _state.durationMilliseconds;
    final position =
        _seekPreviewMilliseconds ?? _state.positionMilliseconds.toDouble();
    final total = _mode == AudioPlayMode.singleTrack
        ? 1
        : _state.queueLength > 0
        ? _state.queueLength
        : _folderTracks.length;
    final index = _mode == AudioPlayMode.singleTrack
        ? 1
        : (_state.queueIndex + 1).clamp(1, total == 0 ? 1 : total);
    final singleMode = _mode == AudioPlayMode.singleTrack;
    final canSkipNext = !singleMode && _state.queueIndex + 1 < total;
    final canSkipPrevious = !singleMode;
    final accent = fileTypeColor(context, FileTypeColor.audio);

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              top: 48,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 240,
                      height: 240,
                      child: _artworkBytes == null
                          ? Icon(
                              Icons.music_note_rounded,
                              size: 132,
                              color: accent,
                            )
                          : ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.memory(
                                _artworkBytes!,
                                cacheWidth:
                                    (240 *
                                            MediaQuery.devicePixelRatioOf(
                                              context,
                                            ))
                                        .round(),
                                cacheHeight:
                                    (240 *
                                            MediaQuery.devicePixelRatioOf(
                                              context,
                                            ))
                                        .round(),
                                fit: BoxFit.contain,
                                errorBuilder: (_, _, _) => Icon(
                                  Icons.music_note_rounded,
                                  size: 132,
                                  color: accent,
                                ),
                              ),
                            ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '$index / $total',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 20),
                    SegmentedButton<AudioPlayMode>(
                      segments: const [
                        ButtonSegment(
                          value: AudioPlayMode.singleTrack,
                          label: Text('This audio'),
                        ),
                        ButtonSegment(
                          value: AudioPlayMode.folder,
                          label: Text('All in folder'),
                        ),
                      ],
                      selected: {_mode ?? AudioPlayMode.folder},
                      onSelectionChanged: _state.isLoading
                          ? null
                          : (selection) =>
                                unawaited(_changeMode(selection.first)),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Text(_formatTime(position.round())),
                        const Spacer(),
                        Text(_formatTime(duration)),
                      ],
                    ),
                    Slider(
                      min: 0,
                      max: duration > 0 ? duration.toDouble() : 1,
                      value: duration > 0
                          ? position.clamp(0, duration.toDouble())
                          : 0,
                      onChangeStart: duration > 0
                          ? (_) => setState(
                              () => _seekPreviewMilliseconds = _state
                                  .positionMilliseconds
                                  .toDouble(),
                            )
                          : null,
                      onChanged: duration > 0
                          ? (value) =>
                                setState(() => _seekPreviewMilliseconds = value)
                          : null,
                      onChangeEnd: duration > 0
                          ? (value) {
                              setState(() => _seekPreviewMilliseconds = null);
                              unawaited(_seekTo(value));
                            }
                          : null,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          tooltip: 'Previous',
                          onPressed: canSkipPrevious ? _skipPrevious : null,
                          icon: const Icon(Icons.skip_previous_rounded),
                          iconSize: 38,
                        ),
                        const SizedBox(width: 20),
                        IconButton.filled(
                          tooltip: _state.isPlaying ? 'Pause' : 'Play',
                          onPressed: _state.isLoading ? null : _togglePlayback,
                          icon: Icon(
                            _state.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
                          iconSize: 42,
                        ),
                        const SizedBox(width: 20),
                        IconButton(
                          tooltip: 'Next',
                          onPressed: canSkipNext ? _skipNext : null,
                          icon: const Icon(Icons.skip_next_rounded),
                          iconSize: 38,
                        ),
                      ],
                    ),
                    if (_state.isLoading)
                      const Padding(
                        padding: EdgeInsets.only(top: 16),
                        child: CircularProgressIndicator(),
                      ),
                    if (_loadError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _loadError!,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                            DetectedContentRecoveryAction(
                              path: _currentPath ?? widget.path,
                              currentCategory: 'Audio',
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () =>
                    setState(() => _nameLayerVisible = !_nameLayerVisible),
                child: AnimatedBarVisibility(
                  visible: _nameLayerVisible,
                  height: 48,
                  child: ColoredBox(
                    color: Colors.grey.withValues(alpha: 0.72),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                                Text(
                                  folder,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Back',
                            onPressed: widget.onBack,
                            icon: const Icon(Icons.arrow_back),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
