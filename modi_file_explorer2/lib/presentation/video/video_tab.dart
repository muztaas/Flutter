import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/constants/selection_long_press_delay.dart';
import '../../core/providers/search_provider.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/providers/video_providers.dart';
import '../../core/utils/file_name_comparator.dart';
import '../../core/utils/font_scaled_spacing.dart';
import '../../core/utils/display_file_name.dart';
import '../../core/utils/file_type_colors.dart';
import '../../core/utils/format_bytes.dart';
import '../../core/utils/time_format.dart';
import '../../domain/entities/search_result.dart';
import '../../domain/entities/search_scope.dart';
import '../../domain/entities/video_file.dart';
import '../../domain/entities/video_folder.dart';
import '../../domain/entities/video_index_record.dart';
import '../../domain/entities/video_information.dart';
import '../../domain/entities/video_path_properties.dart';
import '../../domain/entities/video_status_target.dart';
import '../../domain/entities/video_player_item.dart';
import '../../domain/utils/shared_storage_scan_scope.dart';
import '../common/marquee_text.dart';
import '../common/name_entry_dialog.dart';
import '../common/open_video_file.dart';
import 'video_settings_page.dart';
import 'widgets/video_sort_picker.dart';

class VideoTab extends ConsumerStatefulWidget {
  const VideoTab({
    super.key,
    required this.sessionId,
    required this.initialDriveId,
    required this.initialRelativePath,
    required this.onLocationChanged,
    this.storagePermissionCheck,
    this.openStorageSettings,
  });

  final String sessionId;
  final String? initialDriveId;
  final String initialRelativePath;
  final ValueChanged<({String driveId, String relativePath})> onLocationChanged;
  final Future<bool> Function()? storagePermissionCheck;
  final Future<void> Function()? openStorageSettings;

  @override
  VideoTabState createState() => VideoTabState();
}

class VideoTabState extends ConsumerState<VideoTab>
    with AutomaticKeepAliveClientMixin<VideoTab> {
  static const _storageChannel = MethodChannel(
    'modi_file_explorer2/storage_volumes',
  );

  bool _initialLoadStarted = false;
  bool _isScrolling = false;
  bool _isMenuOpen = false;
  bool _selectionMode = false;
  bool _showVideoSettings = false;
  final ScrollController _itemsScrollController = ScrollController();
  final Set<String> _selectedPaths = {};
  List<VideoStatusTarget> _pendingCopyTargets = [];
  final GlobalKey _menuButtonKey = GlobalKey();
  final Map<String, GlobalKey> _folderRowKeys = {};
  List<Object>? _stableEntries;
  bool _permissionPromptVisible = false;
  bool _permissionPromptScheduled = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _itemsScrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialLoadStarted) return;
    _initialLoadStarted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadInitial();
    });
  }

  Future<bool> _hasStoragePermission() async {
    final permissionCheck = widget.storagePermissionCheck;
    if (permissionCheck != null) return permissionCheck();
    try {
      final sdkVersion = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
      if (sdkVersion >= 30) {
        return (await Permission.manageExternalStorage.status).isGranted;
      }
      final storage = await Permission.storage.status;
      return storage.isGranted || storage.isLimited;
    } on PlatformException catch (error) {
      debugPrint('Could not check Android storage access: $error');
      return false;
    } on MissingPluginException catch (error) {
      debugPrint('Android storage access checker is unavailable: $error');
      return false;
    }
  }

  Future<void> _loadInitial() async {
    final settingsController = ref.read(videoPageSettingsProvider.notifier);
    final controller = ref.read(videoTabProvider(widget.sessionId).notifier);
    try {
      await settingsController.ready;
      final permissionGranted = await _hasStoragePermission();
      await controller.load(
        permissionGranted: permissionGranted,
        initialDriveId: widget.initialDriveId,
        initialRelativePath: widget.initialRelativePath,
        settings: ref.read(videoPageSettingsProvider),
      );
      final loadedState = ref.read(videoTabProvider(widget.sessionId));
      if (ref.read(appSettingsProvider).hideAndroidFoldersInCategoryPages &&
          SharedStorageScanScope.isInsideAndroidFolder(
            loadedState.folderPath,
          )) {
        controller.returnToRoot();
      }
      _reportLocation();
      if (!permissionGranted) _showStoragePermissionPrompt();
    } catch (error) {
      controller.reportFailure(error);
    }
  }

  Future<void> _showStoragePermissionPrompt() async {
    if (!mounted || _permissionPromptVisible || _permissionPromptScheduled) {
      return;
    }
    _permissionPromptScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _permissionPromptScheduled = false;
      if (!mounted || _permissionPromptVisible) return;
      unawaited(_presentStoragePermissionPrompt());
    });
  }

  Future<void> _presentStoragePermissionPrompt() async {
    if (!mounted || _permissionPromptVisible) return;
    _permissionPromptVisible = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Storage access required'),
          content: const Text(
            'Allow storage access so the Videos page can scan and display '
            'video files on this device.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                await _openStorageSettings();
              },
              child: const Text('Open settings'),
            ),
          ],
        ),
      );
    } finally {
      _permissionPromptVisible = false;
    }
  }

  Future<void> _openStorageSettings() async {
    final settingsOpener = widget.openStorageSettings;
    if (settingsOpener != null) {
      await settingsOpener();
      return;
    }
    try {
      await _storageChannel.invokeMethod<bool>('openStorageAccessSettings');
    } on PlatformException {
      await openAppSettings();
    } on MissingPluginException {
      await openAppSettings();
    }
  }

  Future<void> _refresh() async {
    final controller = ref.read(videoTabProvider(widget.sessionId).notifier);
    try {
      final permissionGranted = await _hasStoragePermission();
      await controller.refresh(
        permissionGranted: permissionGranted,
        settings: ref.read(videoPageSettingsProvider),
      );
      _reportLocation();
      if (!permissionGranted) _showStoragePermissionPrompt();
    } catch (error) {
      controller.reportFailure(error);
    }
  }

  void _reportLocation() {
    final state = ref.read(videoTabProvider(widget.sessionId));
    final library = state.library;
    if (library == null) return;
    widget.onLocationChanged((
      driveId: library.drive.id,
      relativePath: state.folderPath,
    ));
  }

  Future<bool> handleWillPop() async {
    if (_showVideoSettings) {
      setState(() => _showVideoSettings = false);
      return true;
    }
    if (_selectionMode) {
      _exitSelection();
      return true;
    }
    if (ref.read(videoPageSettingsProvider).viewMode == 'files') return false;
    final state = ref.read(videoTabProvider(widget.sessionId));
    if (state.pathSegments.isEmpty) return false;
    _navigateUp();
    return true;
  }

  void _navigateUp() {
    final state = ref.read(videoTabProvider(widget.sessionId));
    if (state.pathSegments.isEmpty) return;
    final settings = ref.read(videoPageSettingsProvider);
    final controller = ref.read(videoTabProvider(widget.sessionId).notifier);
    final leftFolder = state.folderPath;
    if (settings.viewMode == 'allFolders') {
      controller.returnToRoot();
    } else {
      controller.goUp();
    }
    _stableEntries = null;
    _reportLocation();
    if (settings.viewMode == 'allFolders') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final itemContext = _folderRowKeys[leftFolder]?.currentContext;
        if (itemContext == null) return;
        unawaited(
          Scrollable.ensureVisible(
            itemContext,
            alignment: 0,
            duration: const Duration(milliseconds: 120),
          ),
        );
      });
    }
  }

  void setVideoMenuOpen(bool open) {
    if (_isMenuOpen == open) return;
    setState(() => _isMenuOpen = open);
  }

  void _beginSelection(String path) {
    setState(() {
      _selectionMode = true;
      _selectedPaths.add(path);
    });
    _showMessage('Selection mode enabled');
  }

  void _toggleSelection(String path) {
    setState(() {
      if (!_selectedPaths.add(path)) _selectedPaths.remove(path);
      if (_selectedPaths.isEmpty) _selectionMode = false;
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedPaths.clear();
    });
  }

  Future<void> _showAnchoredMenu(List<PopupMenuEntry<String>> items) async {
    final buttonContext = _menuButtonKey.currentContext;
    if (buttonContext == null) return;
    final renderObject = buttonContext.findRenderObject();
    if (renderObject is! RenderBox) return;
    final position = renderObject.localToGlobal(Offset.zero);
    final size = renderObject.size;
    setVideoMenuOpen(true);
    try {
      final selection = await showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(
          position.dx,
          position.dy + size.height,
          position.dx + size.width,
          0,
        ),
        items: items,
      );
      if (selection != null) await _handleMenuAction(selection);
    } finally {
      if (mounted) setVideoMenuOpen(false);
    }
  }

  List<PopupMenuEntry<String>> _mainMenuItems() {
    if (!_selectionMode || _selectedPaths.isEmpty) {
      return [
        const PopupMenuItem(value: 'select', child: Text('Select')),
        const PopupMenuItem(value: 'select_all', child: Text('Select All')),
        const PopupMenuItem(value: 'sort', child: Text('Sort by')),
      ];
    }
    return [
      const PopupMenuItem(value: 'rename', child: Text('Rename')),
      const PopupMenuItem(value: 'delete', child: Text('Delete')),
      const PopupMenuItem(value: 'copy', child: Text('Copy')),
      const PopupMenuItem(value: 'select_all', child: Text('Select All')),
      const PopupMenuItem(value: 'properties', child: Text('Properties')),
      const PopupMenuItem(value: 'label', child: Text('Label')),
    ];
  }

  Future<void> _handleMenuAction(String action) async {
    switch (action) {
      case 'select':
        setState(() => _selectionMode = true);
        _showMessage('Selection mode enabled');
        return;
      case 'select_all':
        final state = ref.read(videoTabProvider(widget.sessionId));
        final settings = ref.read(videoPageSettingsProvider);
        final entries = _currentSelectableEntries(state, settings);
        final paths = <String>{
          for (final entry in entries)
            entry is VideoFile
                ? 'file:${entry.relativePath}'
                : 'folder:${(entry as VideoFolder).relativePath}',
        };
        setState(() {
          _selectedPaths
            ..clear()
            ..addAll(paths);
          _selectionMode = paths.isNotEmpty;
        });
        _showMessage('${paths.length} items selected');
        return;
      case 'sort':
        await Future<void>.delayed(Duration.zero);
        final settings = ref.read(videoPageSettingsProvider);
        await _showAnchoredMenu([
          PopupMenuItem(
            value: 'sort_picker',
            enabled: false,
            padding: const EdgeInsets.all(8),
            child: SizedBox(
              width: 320,
              child: VideoSortPicker(
                field: settings.sortField,
                ascending: settings.sortAscending,
                applyFieldImmediately: false,
                onChanged: (field, ascending) {
                  unawaited(_saveSort(field, ascending));
                  Navigator.of(context).pop();
                },
              ),
            ),
          ),
        ]);
        return;
      case 'label':
        await Future<void>.delayed(Duration.zero);
        await _showAnchoredMenu([
          const PopupMenuItem(
            value: 'status:lastPlayed',
            child: Text('Last played'),
          ),
          const PopupMenuItem(value: 'status:newVideo', child: Text('NEW')),
          const PopupMenuItem(
            value: 'status:inProgress',
            child: Text('In Progress'),
          ),
          const PopupMenuItem(
            value: 'status:finished',
            child: Text('Finished'),
          ),
          const PopupMenuItem(value: 'status:none', child: Text('None')),
        ]);
        return;
      case 'status:lastPlayed':
      case 'status:newVideo':
      case 'status:inProgress':
      case 'status:finished':
      case 'status:none':
        await _applyStatusAction(action.substring('status:'.length));
        return;
      case 'rowStatus:lastPlayed':
      case 'rowStatus:newVideo':
      case 'rowStatus:inProgress':
      case 'rowStatus:finished':
      case 'rowStatus:none':
        final state = ref.read(videoTabProvider(widget.sessionId));
        final video = state.library?.videos
            .where(
              (item) =>
                  item.relativePath == _rowStatusVideoPath &&
                  item.driveId == state.library?.drive.id,
            )
            .firstOrNull;
        if (video != null) {
          await _applyStatusTargets([
            VideoStatusTarget(
              driveId: video.driveId,
              relativePath: video.relativePath,
            ),
          ], action.substring('rowStatus:'.length));
        } else {
          _showMessage('The selected video is no longer available');
        }
        return;
      case 'properties':
        await _showSelectedProperties();
        return;
      case 'rename':
        await _renameSelected();
        return;
      case 'delete':
        await _deleteSelected();
        return;
      case 'copy':
        _pendingCopyTargets = _selectedTargets();
        _exitSelection();
        _showMessage(
          '${_pendingCopyTargets.length} item(s) ready to copy; open a folder and tap Paste',
        );
        return;
    }
  }

  Future<void> _saveSort(String field, bool ascending) async {
    try {
      await ref
          .read(videoPageSettingsProvider.notifier)
          .update(
            ref
                .read(videoPageSettingsProvider)
                .copyWith(sortField: field, sortAscending: ascending),
          );
      if (mounted) _showMessage('Video sort updated');
    } catch (error) {
      if (mounted) _showMessage('Could not save Video sort: $error');
    }
  }

  List<VideoFile> _visibleVideos(VideoLibraryTabState state) {
    final settings = ref.read(videoPageSettingsProvider);
    return (state.library?.videos ?? const <VideoFile>[])
        .where((video) => _isVisibleFile(video, settings))
        .toList(growable: false);
  }

  Future<VideoFile?> _mostRecentAvailable() async {
    final state = ref.read(videoTabProvider(widget.sessionId));
    final videos = _visibleVideos(state);
    final recentlyPlayed = await ref
        .read(videoInformationProvider)
        .recentlyPlayed(videos);
    return recentlyPlayed.isEmpty ? null : recentlyPlayed.first;
  }

  Future<void> _playRecent() async {
    final state = ref.read(videoTabProvider(widget.sessionId));
    final VideoFile? video;
    try {
      video = await _mostRecentAvailable();
    } catch (error) {
      if (mounted) _showMessage('Could not load video history: $error');
      return;
    }
    if (!mounted) return;
    if (video == null) {
      _showMessage('No recently played video');
      return;
    }
    final selectedVideo = video;
    final root = state.library?.drive.path;
    if (root == null) return;
    final videoItems = _buildPlayerItems(
      _stableEntries?.whereType<VideoFile>().toList() ?? _visibleVideos(state),
      root,
    );
    await openVideoFile(
      context,
      ref,
      path: _absoluteVideoPath(root, selectedVideo.relativePath),
      name: selectedVideo.name,
      playlist: videoItems,
      currentIndex: videoItems.indexWhere(
        (item) => item.videoFile?.relativePath == selectedVideo.relativePath,
      ),
      onExternalOpen: () => _recordPlaybackStarted(selectedVideo),
    );
  }

  List<Object> _currentSelectableEntries(
    VideoLibraryTabState state,
    VideoPageSettings settings,
  ) {
    final library = state.library;
    if (library == null) return const [];
    final visibleVideos = library.videos
        .where((video) => _isVisibleFile(video, settings))
        .toList();
    final videos = switch (settings.viewMode) {
      'files' => visibleVideos,
      _ =>
        visibleVideos
            .where((video) => video.parentRelativePath == state.folderPath)
            .toList(),
    };
    if (settings.viewMode == 'files') return videos;
    final folders = library.folders.where((folder) {
      if (!_isVisibleFolder(folder, settings)) return false;
      if (!library.videos.any(
        (video) =>
            _isVisibleFile(video, settings) &&
            video.relativePath.startsWith('${folder.relativePath}/'),
      )) {
        return false;
      }
      if (settings.viewMode == 'allFolders' && state.folderPath.isEmpty) {
        return library.videos.any(
          (video) =>
              _isVisibleFile(video, settings) &&
              video.parentRelativePath == folder.relativePath,
        );
      }
      if (settings.viewMode == 'allFolders') return false;
      final separator = folder.relativePath.lastIndexOf('/');
      final parent = separator < 0
          ? ''
          : folder.relativePath.substring(0, separator);
      return parent == state.folderPath;
    }).toList();
    return [...folders, ...videos];
  }

  List<VideoStatusTarget> _selectedTargets() {
    final state = ref.read(videoTabProvider(widget.sessionId));
    final targets = <VideoStatusTarget>[];
    for (final selection in _selectedPaths) {
      final separator = selection.indexOf(':');
      if (separator < 0) continue;
      targets.add(
        VideoStatusTarget(
          driveId: state.library?.drive.id ?? '',
          relativePath: selection.substring(separator + 1),
          isFolder: selection.startsWith('folder:'),
        ),
      );
    }
    return targets;
  }

  Future<void> _applyStatusAction(String statusName) async {
    await _applyStatusTargets(_selectedTargets(), statusName);
  }

  String? _rowStatusVideoPath;

  Future<void> _showRowStatusMenu(VideoFile video) async {
    _rowStatusVideoPath = video.relativePath;
    await _showAnchoredMenu([
      const PopupMenuItem(
        value: 'rowStatus:lastPlayed',
        child: Text('Last played'),
      ),
      const PopupMenuItem(value: 'rowStatus:newVideo', child: Text('NEW')),
      const PopupMenuItem(
        value: 'rowStatus:inProgress',
        child: Text('In Progress'),
      ),
      const PopupMenuItem(value: 'rowStatus:finished', child: Text('Finished')),
      const PopupMenuItem(value: 'rowStatus:none', child: Text('None')),
    ]);
    _rowStatusVideoPath = null;
  }

  Future<void> _applyStatusTargets(
    List<VideoStatusTarget> targets,
    String statusName,
  ) async {
    final status = switch (statusName) {
      'lastPlayed' => VideoStatus.lastPlayed,
      'newVideo' => VideoStatus.newVideo,
      'inProgress' => VideoStatus.inProgress,
      'finished' => VideoStatus.finished,
      _ => VideoStatus.none,
    };
    try {
      final result = await ref
          .read(setVideoStatusProvider)
          .call(targets: targets, status: status);
      ref.read(videoStatusRefreshProvider.notifier).state++;
      if (_selectionMode) _exitSelection();
      if (result.foldersWithoutPlayedVideos.isNotEmpty) {
        _showMessage(
          'No video in ${result.foldersWithoutPlayedVideos.length} selected '
          'folder(s) has ever been played; those folders were unchanged',
        );
      } else {
        final label = switch (status) {
          VideoStatus.lastPlayed => 'Last played',
          VideoStatus.newVideo => 'NEW',
          VideoStatus.inProgress => 'In Progress',
          VideoStatus.finished => 'Finished',
          VideoStatus.none => 'None',
        };
        _showMessage('Marked ${targets.length} item(s) as $label');
      }
    } catch (error) {
      _showMessage('Could not update video status: $error');
    }
  }

  List<VideoPlayerItem> _buildPlayerItems(
    List<VideoFile> videos,
    String rootPath, [
    Map<String, VideoIndexRecord>? records,
  ]) => [
    for (final item in videos)
      VideoPlayerItem.fromVideoFile(
        item,
        absolutePath: _absoluteVideoPath(rootPath, item.relativePath),
        knownInformation: records?[item.relativePath]?.information,
      ),
  ];

  Future<void> _recordPlaybackStarted(VideoFile video) async {
    await ref.read(videoInformationProvider).markPlayed(video);
    ref.read(videoStatusRefreshProvider.notifier).state++;
  }

  Future<void> _openVideo(
    VideoFile video,
    List<VideoPlayerItem> playlist,
  ) async {
    final state = ref.read(videoTabProvider(widget.sessionId));
    final root = state.library?.drive.path;
    if (root == null) return;
    final path = _absoluteVideoPath(root, video.relativePath);
    final opened = await openVideoFile(
      context,
      ref,
      path: path,
      name: video.name,
      playlist: playlist,
      currentIndex: playlist.indexWhere((item) => item.path == path),
      onExternalOpen: () => _recordPlaybackStarted(video),
    );
    if (!opened) return;
  }

  Future<void> _showVideoAction(VideoFile video, String action) async {
    final selectionKey = 'file:${video.relativePath}';
    switch (action) {
      case 'properties':
        await _showPathProperties(
          video.driveId,
          video.relativePath,
          video: video,
        );
      case 'rename':
        setState(() {
          _selectedPaths
            ..clear()
            ..add(selectionKey);
          _selectionMode = true;
        });
        await _renameSelected();
      case 'delete':
        setState(() {
          _selectedPaths
            ..clear()
            ..add(selectionKey);
          _selectionMode = true;
        });
        await _deleteSelected();
      case 'label':
        await _showRowStatusMenu(video);
    }
  }

  Future<void> _showSelectedProperties() async {
    final targets = _selectedTargets();
    if (targets.isEmpty) {
      _showMessage('No selected items are available for properties');
      return;
    }
    for (final target in targets) {
      final video = target.isFolder
          ? null
          : ref
                .read(videoTabProvider(widget.sessionId))
                .library
                ?.videos
                .where((item) => item.relativePath == target.relativePath)
                .firstOrNull;
      await _showPathProperties(
        target.driveId,
        target.relativePath,
        video: video,
      );
      if (!mounted) return;
    }
  }

  Future<void> _showPathProperties(
    String driveId,
    String relativePath, {
    VideoFile? video,
  }) async {
    try {
      final repository = ref.read(videoInformationProvider);
      final values = await Future.wait([
        repository.getPathProperties(
          driveId: driveId,
          relativePath: relativePath,
        ),
        if (video != null) repository.getInformation(video),
      ]);
      if (!mounted) return;
      final properties = values.first as VideoPathProperties;
      final record = video == null ? null : values[1] as VideoIndexRecord?;
      final information = record?.information;
      final root = ref
          .read(videoTabProvider(widget.sessionId))
          .library
          ?.drive
          .name;
      final details = <String>[
        'Name: ${relativePath.split('/').last}',
        'Path: ${root ?? 'Storage'}/$relativePath',
        'Files: ${properties.fileCount}',
        'Folders: ${properties.folderCount}',
        'Total size: ${formatBytes(properties.totalBytes)}',
        if (properties.modified != null)
          'Modified: ${_playedTimeLabel(properties.modified!, ref.read(appSettingsProvider).use24HourTime)}',
        if (information?.durationMilliseconds != null)
          'Duration: ${_formatDuration(information!.durationMilliseconds)}',
        if (information?.resolutionLabel != null)
          'Resolution: ${information!.resolutionLabel}',
        if (information?.frameRate != null)
          'Frame rate: ${_formatFrameRate(information!.frameRate!)} fps',
        if (record != null) 'Status: ${record.status.storageValue}',
        if (record?.playedAt != null)
          'Played: ${_playedTimeLabel(record!.playedAt!, ref.read(appSettingsProvider).use24HourTime)}',
      ];
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Properties'),
          content: SingleChildScrollView(child: Text(details.join('\n'))),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      if (mounted) _showMessage('Properties shown');
    } catch (error) {
      if (mounted) _showMessage('Could not read properties: $error');
    }
  }

  Future<void> _renameSelected() async {
    final state = ref.read(videoTabProvider(widget.sessionId));
    final library = state.library;
    final targets = _selectedTargets();
    if (library == null || targets.isEmpty) {
      _showMessage('Rename is not available: no items are selected');
      return;
    }
    for (final target in targets.where((target) => target.isFolder)) {
      if (!await _confirmFolderAction(target, 'rename')) return;
    }
    if (!mounted) return;
    final input = await showNameEntryDialog(
      context,
      title: targets.length == 1 ? 'Rename' : 'Batch rename',
      extensionNote: targets.length == 1
          ? ''
          : 'The selected items will be named with an increasing number.',
      initialName: targets.length == 1
          ? targets.single.relativePath.split('/').last
          : '',
    );
    if (input == null) {
      _showMessage('Rename cancelled');
      return;
    }
    if (input.isEmpty) {
      _showMessage('Cannot rename: enter a name');
      return;
    }
    if (!mounted) return;
    var renamed = 0;
    Object? failure;
    for (var index = 0; index < targets.length; index++) {
      final target = targets[index];
      final sourceName = target.relativePath.split('/').last;
      final extension = target.isFolder || !sourceName.contains('.')
          ? ''
          : '.${sourceName.substring(sourceName.lastIndexOf('.') + 1)}';
      final newName = targets.length == 1
          ? input
          : '$input (${index + 1})$extension';
      try {
        await ref
            .read(videoInformationProvider)
            .renamePath(
              driveId: target.driveId,
              relativePath: target.relativePath,
              newName: newName,
            );
        renamed++;
      } catch (error) {
        failure ??= error;
      }
    }
    await _refresh();
    _exitSelection();
    _showMessage(
      renamed > 0
          ? '$renamed item(s) renamed${failure == null ? '' : '; some could not be renamed: $failure'}'
          : 'Rename failed: $failure',
    );
  }

  Future<bool> _confirmFolderAction(
    VideoStatusTarget folder,
    String action,
  ) async {
    try {
      final properties = await ref
          .read(videoInformationProvider)
          .getPathProperties(
            driveId: folder.driveId,
            relativePath: folder.relativePath,
          );
      if (!mounted) return false;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            '${action[0].toUpperCase()}${action.substring(1)} folder',
          ),
          content: Text(
            'This $action affects the entire folder, including hidden and '
            'non-video items that are not shown on this page. It contains '
            '${properties.folderCount} folders, ${properties.fileCount} files, '
            'including ${properties.otherItemCount} non-video items.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(action[0].toUpperCase() + action.substring(1)),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        _showMessage(
          '${action[0].toUpperCase()}${action.substring(1)} cancelled',
        );
        return false;
      }
      return true;
    } catch (error) {
      if (mounted) _showMessage('Could not inspect folder: $error');
      return false;
    }
  }

  Future<void> _deleteSelected() async {
    final targets = _selectedTargets();
    if (targets.isEmpty) {
      _showMessage('Delete is not available: no items are selected');
      return;
    }
    for (final target in targets.where((target) => target.isFolder)) {
      if (!await _confirmFolderAction(target, 'delete')) return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirm deletion'),
        content: Text('Delete ${targets.length} selected item(s)?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      _showMessage('Delete cancelled');
      return;
    }
    var deleted = 0;
    Object? failure;
    for (final target in targets) {
      try {
        await ref
            .read(videoInformationProvider)
            .deletePath(
              driveId: target.driveId,
              relativePath: target.relativePath,
            );
        deleted++;
      } catch (error) {
        failure ??= error;
      }
    }
    await _refresh();
    _exitSelection();
    _showMessage(
      deleted > 0
          ? '$deleted item(s) deleted${failure == null ? '' : '; some failed: $failure'}'
          : 'Delete failed: $failure',
    );
  }

  Future<void> _pastePending() async {
    final state = ref.read(videoTabProvider(widget.sessionId));
    final library = state.library;
    if (library == null) {
      _showMessage('Cannot paste: the video library is unavailable');
      return;
    }
    if (state.folderPath.isEmpty) {
      _showMessage('Open a folder first to choose a paste destination');
      return;
    }
    var copied = 0;
    Object? failure;
    String? applyToAll;
    for (final source in List<VideoStatusTarget>.of(_pendingCopyTargets)) {
      final sourceName = source.relativePath.split('/').last;
      final targetRelativePath = '${state.folderPath}/$sourceName';
      var targetName = sourceName;
      var replace = false;
      try {
        final exists = await ref
            .read(videoInformationProvider)
            .pathExists(
              driveId: library.drive.id,
              relativePath: targetRelativePath,
            );
        if (exists) {
          final decision = applyToAll ?? await _showPasteConflict(sourceName);
          if (decision == null || decision == 'cancel') break;
          if (decision == 'skip' || decision == 'skipAll') continue;
          if (decision == 'replaceAll' ||
              decision == 'renameAll' ||
              decision == 'skipAll') {
            applyToAll = decision;
          }
          if (decision == 'rename' || decision == 'renameAll') {
            final newName = await _promptPasteName(sourceName);
            if (newName == null || newName.isEmpty) continue;
            targetName = newName;
          } else {
            replace = decision == 'replace' || decision == 'replaceAll';
          }
        }
        if (source.isFolder && !await _confirmFolderAction(source, 'copy')) {
          continue;
        }
        await ref
            .read(videoInformationProvider)
            .copyPath(
              sourceDriveId: source.driveId,
              sourceRelativePath: source.relativePath,
              destinationDriveId: library.drive.id,
              destinationRelativePath: state.folderPath,
              targetName: targetName,
              replaceExisting: replace,
            );
        copied++;
      } catch (error) {
        failure ??= error;
      }
    }
    if (!mounted) return;
    await _refresh();
    setState(() => _pendingCopyTargets = []);
    _showMessage(
      copied > 0
          ? '$copied item(s) pasted${failure == null ? '' : '; some failed: $failure'}'
          : failure == null
          ? 'Paste cancelled or no items were copied'
          : 'Paste failed: $failure',
    );
  }

  Future<String?> _showPasteConflict(String name) => showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Item already exists'),
      content: Text('"$name" already exists in this folder.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, 'cancel'),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, 'skipAll'),
          child: const Text('Skip all'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, 'skip'),
          child: const Text('Skip'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, 'renameAll'),
          child: const Text('Rename all'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, 'rename'),
          child: const Text('Rename'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, 'replace'),
          child: const Text('Replace'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, 'replaceAll'),
          child: const Text('Replace all'),
        ),
      ],
    ),
  );

  Future<String?> _promptPasteName(String currentName) async {
    return showNameEntryDialog(
      context,
      title: 'Rename copied item',
      initialName: currentName,
    );
  }

  Future<void> _showPlayHint() async {
    try {
      final video = await _mostRecentAvailable();
      if (!mounted) return;
      _showMessage(
        video?.name ?? 'No recently played video',
        duration: const Duration(seconds: 2),
      );
    } catch (error) {
      if (mounted) _showMessage('Could not load video history: $error');
    }
  }

  void _showMessage(String message, {Duration? duration}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: duration ?? const Duration(seconds: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final settings = ref.watch(videoPageSettingsProvider);
    const iconSize = 24.0;
    final appBarHeight = (kToolbarHeight * 0.8)
        .clamp(40, kToolbarHeight)
        .toDouble();
    final state = ref.watch(videoTabProvider(widget.sessionId));
    final indexing = ref.watch(videoIndexingProvider(widget.sessionId));
    final statusRecords =
        ref.watch(videoStatusRecordsProvider(widget.sessionId)).valueOrNull ??
        const <String, VideoIndexRecord>{};
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = ref.read(
        videoIndexingProvider(widget.sessionId).notifier,
      );
      if (state.library == null ||
          !videoSortNeedsInformation(settings.sortField)) {
        controller.stop();
      } else {
        controller.start(state.library!.videos);
      }
    });
    ref.listen<VideoPageSettings>(videoPageSettingsProvider, (previous, next) {
      if (previous?.viewMode != next.viewMode) {
        ref.read(videoTabProvider(widget.sessionId).notifier).returnToRoot();
        _reportLocation();
      }
      if (previous?.showHiddenFilesAndFolders !=
              next.showHiddenFilesAndFolders ||
          previous?.recognizeNomedia != next.recognizeNomedia) {
        ref
            .read(videoTabProvider(widget.sessionId).notifier)
            .reconcileVisibility(next);
        _reportLocation();
      }
    });
    ref.listen<AppSettings>(appSettingsProvider, (previous, next) {
      if (previous?.hideAndroidFoldersInCategoryPages ==
          next.hideAndroidFoldersInCategoryPages) {
        return;
      }
      final currentState = ref.read(videoTabProvider(widget.sessionId));
      if (next.hideAndroidFoldersInCategoryPages &&
          SharedStorageScanScope.isInsideAndroidFolder(
            currentState.folderPath,
          )) {
        ref.read(videoTabProvider(widget.sessionId).notifier).returnToRoot();
        _reportLocation();
      }
      if (mounted) setState(() {});
    });

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(appBarHeight),
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          child: SizedBox(
            height: appBarHeight,
            child: Row(
              children: [
                _compactIconButton(
                  tooltip: _selectionMode
                      ? 'Exit selection mode'
                      : _showVideoSettings
                      ? 'Back to Videos'
                      : 'Open settings',
                  icon: _selectionMode || _showVideoSettings
                      ? Icons.arrow_back
                      : Icons.menu,
                  iconSize: iconSize,
                  onPressed: _selectionMode
                      ? _exitSelection
                      : _showVideoSettings
                      ? () => setState(() => _showVideoSettings = false)
                      : () => ref.read(settingsPanelProvider.notifier).toggle(),
                ),
                if (!_selectionMode &&
                    !_showVideoSettings &&
                    settings.viewMode != 'files' &&
                    state.pathSegments.isNotEmpty)
                  _compactIconButton(
                    tooltip: 'Go up one folder',
                    icon: Icons.arrow_back,
                    iconSize: iconSize,
                    onPressed: _navigateUp,
                  ),
                Expanded(
                  child: _selectionMode
                      ? Text(
                          '${_selectedPaths.length} selected',
                          style: const TextStyle(fontSize: 19),
                        )
                      : _showVideoSettings
                      ? const Text(
                          'Video settings',
                          style: TextStyle(fontSize: 19),
                        )
                      : _buildTitle(context, state),
                ),
                if (!_selectionMode && !_showVideoSettings)
                  _compactIconButton(
                    tooltip: 'Play',
                    icon: Icons.play_arrow,
                    iconSize: iconSize,
                    onPressed: _playRecent,
                    onLongPress: () => unawaited(_showPlayHint()),
                  ),
                if (!_selectionMode && !_showVideoSettings)
                  _compactIconButton(
                    tooltip: 'Refresh',
                    icon: Icons.refresh,
                    iconSize: iconSize,
                    onPressed: state.isLoading ? null : _refresh,
                  ),
                if (!_selectionMode && !_showVideoSettings)
                  _compactIconButton(
                    tooltip: 'Search videos',
                    icon: Icons.search,
                    iconSize: iconSize,
                    onPressed: () {
                      final scope = _searchScope(state);
                      if (scope == null) return;
                      ref
                          .read(fileSearchProvider(widget.sessionId).notifier)
                          .open(
                            scope,
                            onResultSelected: _onSearchResultSelected,
                          );
                    },
                  ),
                if (!_selectionMode && !_showVideoSettings)
                  _compactIconButton(
                    tooltip: 'Video page settings',
                    icon: Icons.tune,
                    iconSize: iconSize,
                    onPressed: () => setState(() => _showVideoSettings = true),
                  ),
                if (!_showVideoSettings)
                  _compactIconButton(
                    key: _menuButtonKey,
                    tooltip: 'More options',
                    onPressed: () => _showAnchoredMenu(_mainMenuItems()),
                    icon: Icons.more_vert,
                    iconSize: iconSize,
                  ),
              ],
            ),
          ),
        ),
      ),
      body: _showVideoSettings
          ? const VideoSettingsPage()
          : _buildBody(context, state, settings, indexing, statusRecords),
      bottomNavigationBar: _buildBottomBar(context, state, settings),
    );
  }

  Widget? _buildBottomBar(
    BuildContext context,
    VideoLibraryTabState state,
    VideoPageSettings settings,
  ) {
    if (_showVideoSettings) return null;
    final showPathBar =
        settings.showPathBar &&
        !_selectionMode &&
        state.pathSegments.isNotEmpty;
    if (_pendingCopyTargets.isEmpty && !showPathBar) return null;
    final color = Theme.of(context).colorScheme.surfaceContainer;
    return Material(
      color: color,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_pendingCopyTargets.isNotEmpty)
            SafeArea(
              bottom: !showPathBar,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_pendingCopyTargets.length} item(s) ready to copy',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    TextButton(
                      onPressed: _pastePending,
                      child: const Text('Paste'),
                    ),
                    TextButton(
                      onPressed: () => setState(() => _pendingCopyTargets = []),
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
            ),
          if (showPathBar)
            SafeArea(
              top: false,
              child: SizedBox(
                height: _folderRowHeight(context, settings) * 0.48,
                width: double.infinity,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: MarqueeText(
                      _videoPath(
                        state.library?.drive.name ?? 'Internal Storage',
                        state.folderPath,
                      ),
                      style: const TextStyle(fontSize: 14),
                      styleMode: MarqueeStyle.pauseAndLoop,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  double _folderRowHeight(BuildContext context, VideoPageSettings settings) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final width = (MediaQuery.sizeOf(context).width - 120)
        .clamp(120, 900)
        .toDouble();
    double measure(String text, TextStyle? style, {int? maxLines}) {
      if (style == null) return 0;
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: maxLines,
      )..layout(maxWidth: width);
      return painter.height;
    }

    final titleHeight = measure('Folder name', _videoNameStyle(theme));
    final details = [
      if (settings.showContents) '999 folders - 999 videos',
      if (settings.showSize) '999.9 GB',
      if (settings.showDate) '2026-10-19',
    ].join(' · ');
    final detailsHeight = details.isEmpty
        ? 0.0
        : measure(details, _detailStyle(theme));
    final pathHeight = settings.showPath
        ? measure('Storage drive/folder path', _pathStyle(theme), maxLines: 1)
        : 0.0;
    final contentHeight =
        titleHeight +
        detailsHeight +
        pathHeight +
        (details.isNotEmpty ? 2 : 0) +
        (settings.showPath ? 1 : 0);
    return (contentHeight > 48 ? contentHeight : 48) + 12;
  }

  Widget _buildTitle(BuildContext context, VideoLibraryTabState state) {
    final title = state.pathSegments.isEmpty
        ? 'Video'
        : state.pathSegments.last;
    return Align(
      alignment: Alignment.centerLeft,
      child: MarqueeText(
        title,
        style: const TextStyle(fontSize: 19),
        styleMode: MarqueeStyle.pauseAndLoop,
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    VideoLibraryTabState state,
    VideoPageSettings settings,
    VideoIndexingState indexing,
    Map<String, VideoIndexRecord> statusRecords,
  ) {
    if (state.library == null && (state.isLoading || !state.hasLoaded)) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.permissionDenied) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Storage access is required to scan videos'),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _showStoragePermissionPrompt,
              child: const Text('Open settings'),
            ),
          ],
        ),
      );
    }
    if (state.error != null && state.library == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Could not load videos: ${state.error}'),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh, size: 20),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }

    final library = state.library;
    if (library == null) return const Center(child: Text('No videos found'));
    final currentPath = state.folderPath;
    final visibleVideos = library.videos
        .where((video) => _isVisibleFile(video, settings))
        .toList(growable: false);
    final foldersContainingVisibleVideos = <String>{};
    final videoSizesByFolder = <String, int>{};
    final directVideoCountsByFolder = <String, int>{};
    final latestPlayedByFolder = <String, DateTime>{};
    for (final video in visibleVideos) {
      var parent = video.parentRelativePath;
      if (statusRecords[video.relativePath]?.status == VideoStatus.newVideo) {
        while (parent.isNotEmpty) {
          directVideoCountsByFolder.update(
            'new:$parent',
            (count) => count + 1,
            ifAbsent: () => 1,
          );
          final separator = parent.lastIndexOf('/');
          parent = separator < 0 ? '' : parent.substring(0, separator);
        }
        parent = video.parentRelativePath;
      }
      if (parent.isNotEmpty) {
        directVideoCountsByFolder.update(
          parent,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
      while (parent.isNotEmpty) {
        foldersContainingVisibleVideos.add(parent);
        videoSizesByFolder.update(
          parent,
          (size) => size + video.size,
          ifAbsent: () => video.size,
        );
        final playedAt = statusRecords[video.relativePath]?.playedAt;
        if (playedAt != null &&
            (latestPlayedByFolder[parent]?.isBefore(playedAt) ?? true)) {
          latestPlayedByFolder[parent] = playedAt;
        }
        final separator = parent.lastIndexOf('/');
        parent = separator < 0 ? '' : parent.substring(0, separator);
      }
    }
    final visibleFolders = library.folders
        .where((folder) {
          if (!_isVisibleFolder(folder, settings) ||
              !foldersContainingVisibleVideos.contains(folder.relativePath)) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
    final childFolderCountsByPath = <String, int>{};
    for (final folder in visibleFolders) {
      final separator = folder.relativePath.lastIndexOf('/');
      final parent = separator < 0
          ? ''
          : folder.relativePath.substring(0, separator);
      childFolderCountsByPath.update(
        parent,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final folders = switch (settings.viewMode) {
      'allFolders' when currentPath.isEmpty =>
        visibleFolders
            .where(
              (folder) =>
                  (directVideoCountsByFolder[folder.relativePath] ?? 0) > 0,
            )
            .toList(),
      'folders' => visibleFolders.where((folder) {
        final separator = folder.relativePath.lastIndexOf('/');
        final parent = separator < 0
            ? ''
            : folder.relativePath.substring(0, separator);
        return parent == currentPath;
      }).toList(),
      _ => <VideoFolder>[],
    };
    final videos = switch (settings.viewMode) {
      'files' => visibleVideos.toList(),
      'allFolders' =>
        visibleVideos
            .where((video) => video.parentRelativePath == currentPath)
            .toList(),
      'folders' =>
        visibleVideos
            .where((video) => video.parentRelativePath == currentPath)
            .toList(),
      _ => <VideoFile>[],
    };
    folders.sort(
      (left, right) => _compareFolders(
        left,
        right,
        settings.sortField,
        settings.sortAscending,
        directVideoCountsByFolder,
        videoSizesByFolder,
        latestPlayedByFolder,
      ),
    );
    videos.sort((left, right) {
      final leftInfo = indexing.records[left.relativePath]?.information;
      final rightInfo = indexing.records[right.relativePath]?.information;
      return _compareVideos(
        left,
        right,
        leftInfo,
        rightInfo,
        statusRecords[left.relativePath],
        statusRecords[right.relativePath],
        settings.sortField,
        settings.sortAscending,
      );
    });
    final computedEntries = <Object>[...folders, ...videos];
    final entries = (_isScrolling || _isMenuOpen) && _stableEntries != null
        ? _stableEntries!
        : computedEntries;
    if (!_isScrolling && !_isMenuOpen) {
      _stableEntries = List<Object>.of(computedEntries);
    }
    Widget buildEntry(
      BuildContext itemContext,
      int index, {
      double? gridCellWidth,
    }) {
      final entry = entries[index];
      if (entry is VideoFolder) {
        return _VideoFolderRow(
          key: _folderRowKeys.putIfAbsent(entry.relativePath, GlobalKey.new),
          folder: entry,
          driveName: library.drive.name,
          childFolderCount: childFolderCountsByPath[entry.relativePath] ?? 0,
          directVideoCount: directVideoCountsByFolder[entry.relativePath] ?? 0,
          size: videoSizesByFolder[entry.relativePath] ?? 0,
          newVideoCount:
              directVideoCountsByFolder['new:${entry.relativePath}'] ?? 0,
          settings: settings,
          selected: _selectedPaths.contains('folder:${entry.relativePath}'),
          selectionMode: _selectionMode,
          isGrid: settings.layout == 'grid',
          gridCellWidth: gridCellWidth,
          onTap: () {
            if (_selectionMode) {
              _toggleSelection('folder:${entry.relativePath}');
              return;
            }
            ref
                .read(videoTabProvider(widget.sessionId).notifier)
                .openFolder(entry.relativePath);
            _stableEntries = null;
            _reportLocation();
          },
          onLongPress: () => _beginSelection('folder:${entry.relativePath}'),
        );
      }
      final video = entry as VideoFile;
      return _VideoFileRow(
        key: ValueKey('video-file:${video.driveId}:${video.relativePath}'),
        video: video,
        driveName: library.drive.name,
        settings: settings,
        status: statusRecords[video.relativePath],
        selected: _selectedPaths.contains('file:${video.relativePath}'),
        selectionMode: _selectionMode,
        isGrid: settings.layout == 'grid',
        gridCellWidth: gridCellWidth,
        onTap: () {
          if (_selectionMode) {
            _toggleSelection('file:${video.relativePath}');
          } else {
            _openVideo(
              video,
              _buildPlayerItems(
                entries.whereType<VideoFile>().toList(),
                library.drive.path,
                indexing.records,
              ),
            );
          }
        },
        onLongPress: () => _beginSelection('file:${video.relativePath}'),
        onOptions: (action) => _showVideoAction(video, action),
        onMenuStateChanged: setVideoMenuOpen,
      );
    }

    if (entries.isEmpty) {
      return Column(
        children: [
          if (state.error != null) _VideoRefreshError(error: state.error!),
          if (indexing.isIndexing) _IndexingProgress(indexing: indexing),
          const Expanded(child: Center(child: Text('No videos found'))),
        ],
      );
    }
    return Column(
      children: [
        if (state.error != null) _VideoRefreshError(error: state.error!),
        if (indexing.isIndexing || indexing.error != null)
          _IndexingProgress(indexing: indexing),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              final scrolling = switch (notification) {
                ScrollStartNotification() => true,
                ScrollEndNotification() => false,
                _ => null,
              };
              if (scrolling != null && scrolling != _isScrolling) {
                setState(() => _isScrolling = scrolling);
              }
              return false;
            },
            child: Scrollbar(
              controller: _itemsScrollController,
              thumbVisibility: true,
              interactive: true,
              child: settings.layout == 'grid'
                  ? LayoutBuilder(
                      builder: (context, constraints) {
                        final usableWidth = constraints.maxWidth - 16;
                        final columns = (usableWidth / 220).floor().clamp(2, 6);
                        final spacing = fontScaledSpacing(context, 8);
                        final cellWidth =
                            (usableWidth - spacing * (columns - 1)) / columns;
                        return GridView.builder(
                          controller: _itemsScrollController,
                          padding: const EdgeInsets.all(8),
                          itemCount: entries.length,
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                crossAxisSpacing: spacing,
                                mainAxisSpacing: spacing,
                                mainAxisExtent:
                                    270 * fontScaledSpacing(context, 1),
                              ),
                          itemBuilder: (context, index) => buildEntry(
                            context,
                            index,
                            gridCellWidth: cellWidth,
                          ),
                        );
                      },
                    )
                  : ListView.builder(
                      controller: _itemsScrollController,
                      itemCount: entries.length,
                      itemBuilder: (context, index) =>
                          buildEntry(context, index),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  bool _isVisibleFile(VideoFile file, VideoPageSettings settings) =>
      (settings.showHiddenFilesAndFolders || !file.isHidden) &&
      (!settings.recognizeNomedia || !file.isInsideNomedia) &&
      (!ref.read(appSettingsProvider).hideAndroidFoldersInCategoryPages ||
          !SharedStorageScanScope.isInsideAndroidFolder(file.relativePath));

  bool _isVisibleFolder(VideoFolder folder, VideoPageSettings settings) =>
      (settings.showHiddenFilesAndFolders || !folder.isHidden) &&
      (!settings.recognizeNomedia || !folder.isInsideNomedia) &&
      (!ref.read(appSettingsProvider).hideAndroidFoldersInCategoryPages ||
          !SharedStorageScanScope.isInsideAndroidFolder(folder.relativePath));

  SearchScope? _searchScope(VideoLibraryTabState state) {
    final library = state.library;
    if (library == null) return null;
    return SearchScope.forLocation(
      driveId: library.drive.id,
      relativePath: state.folderPath,
      driveName: library.drive.name,
      folderName: state.pathSegments.isEmpty
          ? library.drive.name
          : state.pathSegments.last,
      category: SearchCategory.videos,
    );
  }

  Future<void> _onSearchResultSelected(SearchResult result) async {
    if (!result.isDirectory) return;
    if (ref.read(videoPageSettingsProvider).viewMode == 'files') return;
    final state = ref.read(videoTabProvider(widget.sessionId));
    final library = state.library;
    if (library == null) return;
    final root = _normalizePath(library.drive.path);
    final path = _normalizePath(result.path);
    if (!path.startsWith('$root/')) return;
    final relativePath = path.substring(root.length + 1);
    if (ref.read(appSettingsProvider).hideAndroidFoldersInCategoryPages &&
        SharedStorageScanScope.isInsideAndroidFolder(relativePath)) {
      return;
    }
    final folders = library.folders.where(
      (folder) => folder.relativePath == relativePath,
    );
    if (folders.isEmpty) return;
    ref
        .read(videoTabProvider(widget.sessionId).notifier)
        .openFolder(relativePath);
    _reportLocation();
  }

  String _normalizePath(String path) =>
      path.replaceAll('\\', '/').replaceFirst(RegExp(r'/+$'), '');

  Widget _compactIconButton({
    Key? key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    double iconSize = 20,
    VoidCallback? onLongPress,
  }) => SizedBox(
    width: 36,
    height: 36,
    child: IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      icon: onLongPress == null
          ? Icon(icon, size: iconSize)
          : RawGestureDetector(
              gestures: {
                LongPressGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      LongPressGestureRecognizer
                    >(
                      () => LongPressGestureRecognizer(
                        duration: selectionLongPressDelay,
                      ),
                      (recognizer) => recognizer.onLongPress = onLongPress,
                    ),
              },
              child: Icon(icon, size: iconSize),
            ),
    ),
  );
}

class _VideoFileRow extends ConsumerStatefulWidget {
  const _VideoFileRow({
    super.key,
    required this.video,
    required this.driveName,
    required this.settings,
    required this.selected,
    required this.selectionMode,
    required this.isGrid,
    required this.gridCellWidth,
    required this.onTap,
    required this.onLongPress,
    required this.onOptions,
    required this.onMenuStateChanged,
    this.status,
  });

  final VideoFile video;
  final String driveName;
  final VideoPageSettings settings;
  final bool selected;
  final bool selectionMode;
  final bool isGrid;
  final double? gridCellWidth;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final ValueChanged<String> onOptions;
  final ValueChanged<bool> onMenuStateChanged;
  final VideoIndexRecord? status;

  @override
  ConsumerState<_VideoFileRow> createState() => _VideoFileRowState();
}

class _VideoFileRowState extends ConsumerState<_VideoFileRow> {
  late final VideoInformationService _videoInformationService;
  VideoInformation? _information;
  VideoIndexRecord? _record;
  Uint8List? _thumbnail;
  bool _thumbnailFailed = false;
  int _thumbnailGeneration = 0;
  Timer? _selectionTimer;
  bool _longPressTriggered = false;
  bool _tapOnOptions = false;

  @override
  void initState() {
    super.initState();
    _videoInformationService = ref.read(videoInformationProvider);
    _record = widget.status;
    _loadInformation();
    if (widget.settings.showThumbnail) _loadThumbnail();
  }

  @override
  void didUpdateWidget(covariant _VideoFileRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final videoChanged =
        oldWidget.video.driveId != widget.video.driveId ||
        oldWidget.video.relativePath != widget.video.relativePath ||
        oldWidget.video.size != widget.video.size ||
        oldWidget.video.modified != widget.video.modified;
    final thumbnailSizeChanged =
        oldWidget.isGrid != widget.isGrid ||
        (widget.isGrid &&
            oldWidget.gridCellWidth?.round() != widget.gridCellWidth?.round());
    if (videoChanged || thumbnailSizeChanged) {
      ref.read(videoInformationProvider).cancelPending(oldWidget.video);
      if (videoChanged) {
        _information = null;
        _record = widget.status;
      }
      if (videoChanged || thumbnailSizeChanged) {
        _thumbnail = null;
        _thumbnailFailed = false;
        _loadInformation();
        if (widget.settings.showThumbnail) _loadThumbnail();
      }
    }
    if (!oldWidget.settings.showThumbnail &&
        widget.settings.showThumbnail &&
        _thumbnail == null &&
        !_thumbnailFailed) {
      _loadThumbnail();
    }
  }

  Future<void> _loadInformation() async {
    try {
      final record = await ref
          .read(videoInformationProvider)
          .getInformation(widget.video);
      if (mounted) {
        setState(() {
          _record = record;
          _information = record?.information;
        });
      }
    } catch (error) {
      debugPrint('Could not load video information: $error');
    }
  }

  Future<void> _loadThumbnail() async {
    final generation = ++_thumbnailGeneration;
    try {
      final width = widget.isGrid
          ? (((widget.gridCellWidth ?? 220) - 24).round() * 2)
          : 160;
      final thumbnail = await ref
          .read(videoInformationProvider)
          .getThumbnail(
            widget.video,
            width: width,
            height: (width * 9 / 16).round(),
          );
      if (!mounted || generation != _thumbnailGeneration) return;
      setState(() {
        _thumbnail = thumbnail == null ? null : Uint8List.fromList(thumbnail);
        _thumbnailFailed = thumbnail == null;
      });
    } catch (error) {
      if (generation != _thumbnailGeneration) return;
      debugPrint('Could not generate a video thumbnail: $error');
      if (mounted) setState(() => _thumbnailFailed = true);
    }
  }

  Widget _buildGridContent(
    BuildContext context,
    ThemeData theme,
    String name,
    Color nameColor,
    List<String> details,
    String path,
    String? duration,
  ) {
    final settings = widget.settings;
    final contentWidth = (widget.gridCellWidth ?? 220) - 24;
    final thumbnailHeight = contentWidth * 9 / 16;
    return SizedBox(
      height: 258,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: thumbnailHeight,
            child: Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: settings.showThumbnail && _thumbnail != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.memory(
                            _thumbnail!,
                            fit: BoxFit.cover,
                            cacheWidth: contentWidth.round() * 2,
                            cacheHeight: (thumbnailHeight * 2).round(),
                            errorBuilder: (_, _, _) => Icon(
                              Icons.play_arrow,
                              size: 56,
                              color: fileTypeColor(
                                context,
                                FileTypeColor.video,
                              ),
                            ),
                          ),
                        )
                      : Center(
                          child: Icon(
                            Icons.play_arrow,
                            size: 56,
                            color: fileTypeColor(context, FileTypeColor.video),
                          ),
                        ),
                ),
                if (duration != null && settings.displayLengthOverThumbnail)
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: _DurationBadge(duration: duration),
                  ),
                if (widget.selectionMode)
                  Positioned(
                    left: 0,
                    top: 0,
                    child: Checkbox(
                      value: widget.selected,
                      onChanged: (_) => widget.onTap(),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                if (!widget.selectionMode)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Material(
                      color: theme.colorScheme.surface.withValues(alpha: 0.8),
                      shape: const CircleBorder(),
                      child: SizedBox(
                        width: 36,
                        height: 36,
                        child: PopupMenuButton<String>(
                          tooltip: 'Video options',
                          padding: EdgeInsets.zero,
                          iconSize: 20,
                          onOpened: () => widget.onMenuStateChanged(true),
                          onCanceled: () => widget.onMenuStateChanged(false),
                          onSelected: (value) {
                            widget.onMenuStateChanged(false);
                            widget.onOptions(value);
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'properties',
                              child: Text('Properties'),
                            ),
                            PopupMenuItem(
                              value: 'rename',
                              child: Text('Rename'),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text('Delete'),
                            ),
                            PopupMenuItem(
                              value: 'label',
                              child: Text('Update tag'),
                            ),
                          ],
                          icon: const Icon(Icons.more_vert),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(height: fontScaledSpacing(context, 4)),
          _VideoNameText(name: name, settings: settings, color: nameColor),
          if (details.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: fontScaledSpacing(context, 2)),
              child: Text(details.join(' · '), style: _detailStyle(theme)),
            ),
          if (settings.showPath)
            Padding(
              padding: EdgeInsets.only(top: fontScaledSpacing(context, 1)),
              child: MarqueeText(
                path,
                style: _pathStyle(theme),
                styleMode: MarqueeStyle.pauseAndLoop,
              ),
            ),
          if (duration != null && !settings.displayLengthOverThumbnail)
            Align(
              alignment: Alignment.centerRight,
              child: Text(duration, style: _detailStyle(theme)),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _selectionTimer?.cancel();
    _videoInformationService.cancelPending(widget.video);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(videoStatusRefreshProvider, (_, _) => _loadInformation());
    final settings = widget.settings;
    final video = widget.video;
    final theme = Theme.of(context);
    final name = _videoDisplayName(
      displayFileName(
        video.name,
        showExtension: ref.watch(appSettingsProvider).showFileExtension,
        isDirectory: false,
      ),
      settings,
    );
    final details = <String>[];
    if (settings.showResolution) {
      final resolution = _information?.resolutionLabel;
      if (resolution != null) details.add(resolution);
    }
    final frameRate = _information?.frameRate;
    if (settings.showFrameRate && frameRate != null) {
      details.add('${_formatFrameRate(frameRate)} fps');
    }
    if (settings.showFileExtension && video.extension.isNotEmpty) {
      details.add(video.extension.substring(1).toUpperCase());
    }
    if (settings.showSize) details.add(formatBytes(video.size));
    if (settings.showDate) details.add(_dateLabel(video.modified));
    final path = _videoPath(widget.driveName, video.parentRelativePath);
    final playedAt = _record?.playedAt;
    if (settings.showPlayedTime && playedAt != null) {
      details.add(
        _playedTimeLabel(
          playedAt,
          ref.watch(appSettingsProvider).use24HourTime,
        ),
      );
    }
    final duration = settings.showLength
        ? _formatDuration(_information?.durationMilliseconds)
        : null;

    final nameColor = switch (_record?.status) {
      VideoStatus.lastPlayed => theme.colorScheme.error,
      VideoStatus.inProgress => theme.colorScheme.primary,
      VideoStatus.finished => theme.colorScheme.onSurfaceVariant,
      _ => theme.colorScheme.onSurface,
    };
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) {
        _longPressTriggered = false;
        _tapOnOptions =
            widget.isGrid &&
            details.localPosition.dx >= (widget.gridCellWidth ?? 0) - 48 &&
            details.localPosition.dy < 48;
        _selectionTimer?.cancel();
        _selectionTimer = Timer(selectionLongPressDelay, () {
          if (!mounted) return;
          _longPressTriggered = true;
          widget.onLongPress();
        });
      },
      onTapUp: (_) {
        _selectionTimer?.cancel();
        if (!_longPressTriggered && !_tapOnOptions) widget.onTap();
        _longPressTriggered = false;
        _tapOnOptions = false;
      },
      onTapCancel: () {
        _selectionTimer?.cancel();
        _longPressTriggered = false;
        _tapOnOptions = false;
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: widget.selected
              ? theme.colorScheme.secondaryContainer.withValues(alpha: 0.35)
              : null,
          border: _record?.status == VideoStatus.newVideo
              ? Border(
                  left: BorderSide(color: theme.colorScheme.error, width: 6),
                )
              : null,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(width: 3),
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: fontScaledSpacing(context, 6),
                ),
                child: widget.isGrid
                    ? _buildGridContent(
                        context,
                        theme,
                        name,
                        nameColor,
                        details,
                        path,
                        duration,
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.selectionMode)
                            SizedBox(
                              width: 36,
                              height: 48,
                              child: Checkbox(
                                value: widget.selected,
                                onChanged: (_) => widget.onTap(),
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                          if (settings.showThumbnail)
                            SizedBox(
                              width: 80,
                              height: 48,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  if (_thumbnail == null)
                                    Icon(
                                      Icons.play_arrow,
                                      size: 20,
                                      color: fileTypeColor(
                                        context,
                                        FileTypeColor.video,
                                      ),
                                    )
                                  else
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(4),
                                      child: Image.memory(
                                        _thumbnail!,
                                        width: 80,
                                        height: 48,
                                        fit: BoxFit.cover,
                                        cacheWidth: 160,
                                        cacheHeight: 96,
                                        errorBuilder: (_, _, _) => Icon(
                                          Icons.play_arrow,
                                          size: 20,
                                          color: fileTypeColor(
                                            context,
                                            FileTypeColor.video,
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (duration != null &&
                                      settings.displayLengthOverThumbnail)
                                    Positioned(
                                      right: 2,
                                      bottom: 2,
                                      child: _DurationBadge(duration: duration),
                                    ),
                                ],
                              ),
                            )
                          else
                            SizedBox(
                              width: 80,
                              height: 48,
                              child: Icon(
                                Icons.play_arrow,
                                size: 20,
                                color: fileTypeColor(
                                  context,
                                  FileTypeColor.video,
                                ),
                              ),
                            ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _VideoNameText(
                                  name: name,
                                  settings: settings,
                                  color: nameColor,
                                ),
                                if (details.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                      details.join(' · '),
                                      style: _detailStyle(theme),
                                    ),
                                  ),
                                if (settings.showPath)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 1),
                                    child: MarqueeText(
                                      path,
                                      style: _pathStyle(theme),
                                      styleMode: MarqueeStyle.pauseAndLoop,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (duration != null &&
                              !settings.displayLengthOverThumbnail) ...[
                            const SizedBox(width: 6),
                            Padding(
                              padding: const EdgeInsets.only(top: 30),
                              child: Text(duration, style: _detailStyle(theme)),
                            ),
                          ],
                          if (!widget.selectionMode)
                            SizedBox(
                              width: 32,
                              height: 48,
                              child: PopupMenuButton<String>(
                                tooltip: 'Video options',
                                padding: EdgeInsets.zero,
                                iconSize: 20,
                                onOpened: () => widget.onMenuStateChanged(true),
                                onCanceled: () =>
                                    widget.onMenuStateChanged(false),
                                onSelected: (value) {
                                  widget.onMenuStateChanged(false);
                                  widget.onOptions(value);
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'properties',
                                    child: Text('Properties'),
                                  ),
                                  PopupMenuItem(
                                    value: 'rename',
                                    child: Text('Rename'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Delete'),
                                  ),
                                  PopupMenuItem(
                                    value: 'label',
                                    child: Text('Update tag'),
                                  ),
                                ],
                                icon: const Icon(Icons.more_vert),
                              ),
                            ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoFolderRow extends StatelessWidget {
  const _VideoFolderRow({
    super.key,
    required this.folder,
    required this.driveName,
    required this.childFolderCount,
    required this.directVideoCount,
    required this.size,
    required this.newVideoCount,
    required this.settings,
    required this.selected,
    required this.selectionMode,
    required this.isGrid,
    required this.gridCellWidth,
    required this.onTap,
    required this.onLongPress,
  });

  final VideoFolder folder;
  final String driveName;
  final int childFolderCount;
  final int directVideoCount;
  final int size;
  final int newVideoCount;
  final VideoPageSettings settings;
  final bool selected;
  final bool selectionMode;
  final bool isGrid;
  final double? gridCellWidth;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = _videoDisplayName(folder.name, settings);
    final details = <String>[];
    if (settings.showContents) {
      details.add('$childFolderCount folders - $directVideoCount videos');
    }
    if (settings.showSize) details.add(formatBytes(size));
    if (settings.showDate && folder.modified != null) {
      details.add(_dateLabel(folder.modified!));
    }
    final path = _videoPath(driveName, folder.relativePath);
    return _VideoItemGesture(
      onTap: onTap,
      onLongPress: onLongPress,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.secondaryContainer.withValues(alpha: 0.35)
              : null,
        ),
        child: isGrid
            ? Padding(
                padding: const EdgeInsets.all(8),
                child: SizedBox(
                  height: 254,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: ((gridCellWidth ?? 220) - 16) * 9 / 16,
                        child: Stack(
                          children: [
                            Center(
                              child: Icon(
                                Icons.folder_outlined,
                                size: 64,
                                color: fileTypeColor(
                                  context,
                                  FileTypeColor.folder,
                                ),
                              ),
                            ),
                            if (newVideoCount > 0)
                              Positioned(
                                top: 4,
                                right: 4,
                                child: _NewVideosBadge(count: newVideoCount),
                              ),
                            if (selectionMode)
                              Positioned(
                                top: 0,
                                left: 0,
                                child: Checkbox(
                                  value: selected,
                                  onChanged: (_) => onTap(),
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      _VideoNameText(name: name, settings: settings),
                      if (details.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            details.join(' · '),
                            style: _detailStyle(theme),
                          ),
                        ),
                      if (settings.showPath)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: MarqueeText(
                            path,
                            style: _pathStyle(theme),
                            styleMode: MarqueeStyle.pauseAndLoop,
                          ),
                        ),
                    ],
                  ),
                ),
              )
            : Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (selectionMode)
                      SizedBox(
                        width: 32,
                        height: 48,
                        child: Checkbox(
                          value: selected,
                          onChanged: (_) {},
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    SizedBox(
                      width: 80,
                      height: 48,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Align(
                            alignment: Alignment.center,
                            child: Icon(
                              Icons.folder_outlined,
                              size: 20,
                              color: fileTypeColor(
                                context,
                                FileTypeColor.folder,
                              ),
                            ),
                          ),
                          if (newVideoCount > 0)
                            Positioned(
                              top: 4,
                              right: 12,
                              child: _NewVideosBadge(count: newVideoCount),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _VideoNameText(name: name, settings: settings),
                          if (details.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                details.join(' · '),
                                style: _detailStyle(theme),
                              ),
                            ),
                          if (settings.showPath)
                            Padding(
                              padding: const EdgeInsets.only(top: 1),
                              child: MarqueeText(
                                path,
                                style: _pathStyle(theme),
                                styleMode: MarqueeStyle.pauseAndLoop,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _VideoItemGesture extends StatefulWidget {
  const _VideoItemGesture({
    required this.onTap,
    required this.onLongPress,
    required this.child,
  });

  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final Widget child;

  @override
  State<_VideoItemGesture> createState() => _VideoItemGestureState();
}

class _VideoItemGestureState extends State<_VideoItemGesture> {
  Timer? _selectionTimer;
  bool _longPressTriggered = false;

  @override
  void dispose() {
    _selectionTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapDown: (_) {
      _longPressTriggered = false;
      _selectionTimer?.cancel();
      _selectionTimer = Timer(selectionLongPressDelay, () {
        if (!mounted) return;
        _longPressTriggered = true;
        widget.onLongPress();
      });
    },
    onTapUp: (_) {
      _selectionTimer?.cancel();
      if (!_longPressTriggered) widget.onTap();
      _longPressTriggered = false;
    },
    onTapCancel: () {
      _selectionTimer?.cancel();
      _longPressTriggered = false;
    },
    child: widget.child,
  );
}

class _VideoNameText extends StatelessWidget {
  const _VideoNameText({
    required this.name,
    required this.settings,
    this.color,
  });

  final String name;
  final VideoPageSettings settings;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final style = _videoNameStyle(
      Theme.of(context),
    )?.copyWith(color: color ?? Theme.of(context).colorScheme.onSurface);
    if (settings.scrollLongNames) {
      return MarqueeText(
        name,
        style: style,
        styleMode: MarqueeStyle.pauseAndLoop,
      );
    }
    return Text(name, style: style, softWrap: true);
  }
}

class _NewVideosBadge extends StatelessWidget {
  const _NewVideosBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.error,
      shape: BoxShape.circle,
    ),
    child: SizedBox(
      width: 18,
      height: 18,
      child: Center(
        child: Text(
          count > 99 ? '99+' : '$count',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onError,
            fontSize: 8,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    ),
  );
}

class _DurationBadge extends StatelessWidget {
  const _DurationBadge({required this.duration});

  final String duration;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.inverseSurface.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
        child: Text(
          duration,
          style: TextStyle(color: colors.onInverseSurface, fontSize: 9),
        ),
      ),
    );
  }
}

String _videoDisplayName(String name, VideoPageSettings settings) {
  final limit = settings.scrollLongNames ? 1000 : settings.nameCharacterLimit;
  if (name.length <= limit) return name;
  return '${name.substring(0, limit)}...';
}

String _videoPath(String driveName, String relativePath) {
  if (relativePath.isEmpty) return driveName;
  return '$driveName/$relativePath';
}

String _absoluteVideoPath(String root, String relativePath) {
  final normalizedRoot = root
      .replaceAll('\\', '/')
      .replaceFirst(RegExp(r'/+$'), '');
  return relativePath.isEmpty
      ? normalizedRoot
      : '$normalizedRoot/${relativePath.replaceAll('\\', '/')}';
}

String? _formatDuration(int? milliseconds) {
  if (milliseconds == null || milliseconds < 0) return null;
  final seconds = milliseconds ~/ 1000;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remainder = seconds % 60;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${remainder.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:'
      '${remainder.toString().padLeft(2, '0')}';
}

String _formatFrameRate(double frameRate) {
  if (frameRate == frameRate.roundToDouble()) {
    return frameRate.toInt().toString();
  }
  return frameRate.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
}

String _dateLabel(DateTime modified) =>
    '${modified.year.toString().padLeft(4, '0')}-'
    '${modified.month.toString().padLeft(2, '0')}-'
    '${modified.day.toString().padLeft(2, '0')}';

String _playedTimeLabel(DateTime playedAt, bool use24HourTime) =>
    '${_dateLabel(playedAt)} '
    '${formatClockTime(playedAt, use24HourTime: use24HourTime)}';

TextStyle? _videoNameStyle(ThemeData theme) => theme.textTheme.titleMedium
    ?.copyWith(fontSize: (theme.textTheme.titleMedium?.fontSize ?? 16) + 1);

TextStyle? _detailStyle(ThemeData theme) => theme.textTheme.bodySmall?.copyWith(
  fontSize: (theme.textTheme.titleMedium?.fontSize ?? 16) - 4,
  color: theme.colorScheme.onSurfaceVariant,
);

TextStyle? _pathStyle(ThemeData theme) => _detailStyle(theme);

int _compareOptional<T extends Comparable<T>>(
  T? left,
  T? right,
  bool ascending,
) {
  if (left == null) return right == null ? 0 : 1;
  if (right == null) return -1;
  final comparison = left.compareTo(right);
  return ascending ? comparison : -comparison;
}

int _compareFolders(
  VideoFolder left,
  VideoFolder right,
  String sortField,
  bool ascending,
  Map<String, int> directVideoCounts,
  Map<String, int> sizes,
  Map<String, DateTime> latestPlayed,
) {
  switch (sortField) {
    case 'date':
      return _compareFolderValue(
        left,
        right,
        left.modified,
        right.modified,
        ascending,
      );
    case 'size':
      return _compareOptional(
        sizes[left.relativePath],
        sizes[right.relativePath],
        ascending,
      );
    case 'path':
      final leftDirect = (directVideoCounts[left.relativePath] ?? 0) > 0;
      final rightDirect = (directVideoCounts[right.relativePath] ?? 0) > 0;
      final directOrder = leftDirect == rightDirect
          ? 0
          : leftDirect
          ? -1
          : 1;
      if (directOrder != 0) return ascending ? directOrder : -directOrder;
      final depthOrder = left.relativePath
          .split('/')
          .length
          .compareTo(right.relativePath.split('/').length);
      if (depthOrder != 0) return ascending ? depthOrder : -depthOrder;
      final pathOrder = compareStorageNames(
        left.relativePath,
        right.relativePath,
      );
      return ascending ? pathOrder : -pathOrder;
    case 'playedTime':
      return _compareFolderValue(
        left,
        right,
        latestPlayed[left.relativePath],
        latestPlayed[right.relativePath],
        ascending,
      );
    default:
      return compareStorageNames(left.name, right.name);
  }
}

int _compareVideos(
  VideoFile left,
  VideoFile right,
  VideoInformation? leftInfo,
  VideoInformation? rightInfo,
  VideoIndexRecord? leftRecord,
  VideoIndexRecord? rightRecord,
  String sortField,
  bool ascending,
) {
  switch (sortField) {
    case 'date':
      return _compareVideoValue(
        left,
        right,
        left.modified,
        right.modified,
        ascending,
      );
    case 'size':
      return _compareVideoValue(left, right, left.size, right.size, ascending);
    case 'length':
      return _compareVideoValue(
        left,
        right,
        leftInfo?.durationMilliseconds,
        rightInfo?.durationMilliseconds,
        ascending,
      );
    case 'resolution':
      return _compareVideoValue(
        left,
        right,
        leftInfo?.shorterDisplayedSide,
        rightInfo?.shorterDisplayedSide,
        ascending,
      );
    case 'frameRate':
      return _compareVideoValue(
        left,
        right,
        leftInfo?.frameRate,
        rightInfo?.frameRate,
        ascending,
      );
    case 'type':
      final comparison = compareStorageNames(left.extension, right.extension);
      return comparison == 0
          ? compareStorageNames(left.name, right.name)
          : ascending
          ? comparison
          : -comparison;
    case 'path':
      final depthOrder = left.relativePath
          .split('/')
          .length
          .compareTo(right.relativePath.split('/').length);
      if (depthOrder != 0) return ascending ? depthOrder : -depthOrder;
      final pathOrder = compareStorageNames(
        left.relativePath,
        right.relativePath,
      );
      return ascending ? pathOrder : -pathOrder;
    case 'playedTime':
      return _compareVideoValue(
        left,
        right,
        leftRecord?.playedAt,
        rightRecord?.playedAt,
        ascending,
      );
    case 'status':
      const statusOrder = {
        VideoStatus.newVideo: 0,
        VideoStatus.inProgress: 1,
        VideoStatus.none: 2,
        VideoStatus.lastPlayed: 3,
        VideoStatus.finished: 4,
      };
      final comparison = statusOrder[leftRecord?.status ?? VideoStatus.none]!
          .compareTo(statusOrder[rightRecord?.status ?? VideoStatus.none]!);
      if (comparison == 0) return compareStorageNames(left.name, right.name);
      return ascending ? comparison : -comparison;
    default:
      final comparison = compareStorageNames(left.name, right.name);
      return ascending ? comparison : -comparison;
  }
}

int _compareVideoValue<T extends Comparable<T>>(
  VideoFile left,
  VideoFile right,
  T? leftValue,
  T? rightValue,
  bool ascending,
) {
  if (leftValue == null) {
    return rightValue == null ? compareStorageNames(left.name, right.name) : 1;
  }
  if (rightValue == null) return -1;
  final comparison = leftValue.compareTo(rightValue);
  if (comparison == 0) return compareStorageNames(left.name, right.name);
  return ascending ? comparison : -comparison;
}

int _compareFolderValue<T extends Comparable<T>>(
  VideoFolder left,
  VideoFolder right,
  T? leftValue,
  T? rightValue,
  bool ascending,
) {
  if (leftValue == null) {
    return rightValue == null ? compareStorageNames(left.name, right.name) : 1;
  }
  if (rightValue == null) return -1;
  final comparison = leftValue.compareTo(rightValue);
  if (comparison == 0) return compareStorageNames(left.name, right.name);
  return ascending ? comparison : -comparison;
}

class _VideoRefreshError extends StatelessWidget {
  const _VideoRefreshError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    child: Text(
      'Could not refresh videos: $error',
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: Theme.of(context).colorScheme.error,
      ),
    ),
  );
}

class _IndexingProgress extends StatelessWidget {
  const _IndexingProgress({required this.indexing});

  final VideoIndexingState indexing;

  @override
  Widget build(BuildContext context) {
    final error = indexing.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (indexing.isIndexing)
          LinearProgressIndicator(
            value: indexing.total == 0
                ? null
                : indexing.completed / indexing.total,
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Text(
            error == null
                ? 'Indexing ${_formatCount(indexing.completed)} / '
                      '${_formatCount(indexing.total)}'
                : 'Indexing ${_formatCount(indexing.completed)} / '
                      '${_formatCount(indexing.total)}; some video details '
                      'could not be read: $error',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      ],
    );
  }
}

String _formatCount(int value) {
  final digits = value.toString();
  final grouped = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) grouped.write(',');
    grouped.write(digits[index]);
  }
  return grouped.toString();
}
