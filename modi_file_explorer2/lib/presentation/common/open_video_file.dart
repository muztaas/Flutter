import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/default_file_apps_provider.dart';
import '../../core/providers/file_type_categories_provider.dart';
import '../../core/providers/open_with_providers.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/providers/video_providers.dart';
import '../../core/tabs/tabs_manager.dart';
import '../../core/utils/file_name_comparator.dart';
import '../../core/constants/branding.dart';
import '../../domain/entities/default_file_app.dart';
import '../../domain/entities/open_with_app.dart';
import '../../domain/entities/video_file.dart';
import '../../domain/entities/video_player_item.dart';
import '../video_player/video_player_page.dart';

Future<bool> openVideoFile(
  BuildContext context,
  WidgetRef ref, {
  required String path,
  required String name,
  List<VideoPlayerItem>? playlist,
  int? currentIndex,
  Future<void> Function(VideoPlayerItem item)? onPlaybackBegan,
  Future<void> Function()? onExternalOpen,
  bool excludeBuiltIn = false,
  bool? useSavedDefaultApps,
}) async {
  final repository = ref.read(openWithRepositoryProvider);
  final extension = _extension(name);
  if (extension.isEmpty) {
    _showOpenError(context, 'Could not determine the video file type');
    return false;
  }

  if (!excludeBuiltIn &&
      (useSavedDefaultApps ??
          ref.read(appSettingsProvider).useSavedDefaultApps)) {
    try {
      final saved = await ref
          .read(defaultFileAppsProvider.notifier)
          .find(extension, category: 'Video');
      if (!context.mounted) return false;
      if (saved != null) {
        if (saved.isVideoPlayer) {
          await _openBuiltInPlayer(
            ref,
            context,
            path: path,
            name: name,
            playlist: playlist,
            currentIndex: currentIndex,
            onPlaybackBegan: onPlaybackBegan,
          );
          return true;
        }
        final apps = await repository.listApps(path: path, category: 'Video');
        final app = apps
            .where(
              (candidate) =>
                  candidate.packageName == saved.packageName &&
                  (saved.activityName == null ||
                      candidate.activityName == saved.activityName),
            )
            .firstOrNull;
        if (app != null) {
          await repository.openFile(
            path: path,
            category: 'Video',
            packageName: app.packageName,
            activityName: app.activityName,
            mimeType: app.mimeType,
          );
          if (!context.mounted) return false;
          await _notifyExternalOpen(context, ref, path, name, onExternalOpen);
          return true;
        }
        await ref
            .read(defaultFileAppsProvider.notifier)
            .delete(saved.extension);
        if (context.mounted) {
          _showOpenError(
            context,
            'The saved app for .$extension is unavailable; choose another app',
          );
        }
      }
    } catch (error) {
      if (context.mounted) {
        _showOpenError(context, 'Could not open the saved video app: $error');
      }
      return false;
    }
  }

  final List<OpenWithApp> apps;
  try {
    apps = await repository.listApps(path: path, category: 'Video');
  } catch (error) {
    if (context.mounted) {
      _showOpenError(context, 'Could not load video apps: $error');
    }
    return false;
  }
  if (!context.mounted) return false;

  final builtIn = const OpenWithApp(
    name: 'Video Player (built-in)',
    packageName: DefaultFileApp.videoPlayerHandlerId,
    mimeType: 'video/*',
  );
  final selection = await showDialog<_VideoAppSelection>(
    context: context,
    builder: (dialogContext) {
      var saveAsDefault = false;
      return StatefulBuilder(
        builder: (context, setDialogState) => SimpleDialog(
          title: Text('Open $name with'),
          children: [
            if (!excludeBuiltIn)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  _VideoAppSelection(
                    app: builtIn,
                    saveAsDefault: saveAsDefault,
                  ),
                ),
                child: Row(
                  children: [
                    Image.asset(
                      Branding.logoPng,
                      width: 28,
                      height: 28,
                      fit: BoxFit.contain,
                    ),
                    SizedBox(width: 12),
                    Text('Video Player (built-in)'),
                  ],
                ),
              ),
            for (final app in apps)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  _VideoAppSelection(app: app, saveAsDefault: saveAsDefault),
                ),
                child: Row(
                  children: [
                    _appIcon(app.iconBytes),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        app.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            CheckboxListTile(
              title: Text('Always use this app for .$extension files'),
              value: saveAsDefault,
              onChanged: (value) =>
                  setDialogState(() => saveAsDefault = value ?? false),
            ),
          ],
        ),
      );
    },
  );
  if (selection == null || !context.mounted) return false;

  if (selection.saveAsDefault) {
    try {
      await ref
          .read(defaultFileAppsProvider.notifier)
          .save(
            DefaultFileApp(
              extension: extension,
              handlerId:
                  selection.app.packageName ==
                      DefaultFileApp.videoPlayerHandlerId
                  ? DefaultFileApp.videoPlayerHandlerId
                  : 'external',
              category: 'Video',
              mimeType: selection.app.mimeType,
              packageName:
                  selection.app.packageName ==
                      DefaultFileApp.videoPlayerHandlerId
                  ? null
                  : selection.app.packageName,
              displayName:
                  selection.app.packageName ==
                      DefaultFileApp.videoPlayerHandlerId
                  ? null
                  : selection.app.name,
              activityName:
                  selection.app.packageName ==
                      DefaultFileApp.videoPlayerHandlerId
                  ? null
                  : selection.app.activityName,
              extensionSpecific: true,
              extensions: [extension],
            ),
          );
    } catch (error) {
      if (context.mounted) {
        _showOpenError(context, 'Could not save the default app: $error');
      }
    }
  }

  if (!context.mounted) return false;
  if (selection.app.packageName == DefaultFileApp.videoPlayerHandlerId) {
    await _openBuiltInPlayer(
      ref,
      context,
      path: path,
      name: name,
      playlist: playlist,
      currentIndex: currentIndex,
      onPlaybackBegan: onPlaybackBegan,
    );
    return true;
  }
  try {
    await repository.openFile(
      path: path,
      category: 'Video',
      packageName: selection.app.packageName,
      activityName: selection.app.activityName,
      mimeType: selection.app.mimeType,
    );
    if (!context.mounted) return false;
    await _notifyExternalOpen(context, ref, path, name, onExternalOpen);
    return true;
  } catch (error) {
    if (context.mounted) {
      _showOpenError(context, 'Could not open $name: $error');
    }
    return false;
  }
}

Future<void> _notifyExternalOpen(
  BuildContext context,
  WidgetRef ref,
  String path,
  String name,
  Future<void> Function()? callback,
) async {
  try {
    if (callback != null) {
      await callback();
    } else {
      await _markVideoPlayed(ref)(VideoPlayerItem(path: path, name: name));
    }
  } catch (error) {
    if (context.mounted) {
      _showOpenError(
        context,
        'The video opened, but its history failed: $error',
      );
    }
  }
}

Future<void> Function(VideoPlayerItem item) _markVideoPlayed(WidgetRef ref) {
  final resolver = ref.read(resolveVideoFileProvider);
  final information = ref.read(videoInformationProvider);
  final statusRefresh = ref.read(videoStatusRefreshProvider.notifier);
  final extensions = ref
      .read(fileTypeCategoriesProvider)
      .where((category) => category.name == 'Video')
      .expand((category) => category.extensions)
      .toSet();
  return (item) async {
    final video =
        item.videoFile ??
        await resolver(path: item.path, extensions: extensions);
    if (video == null) {
      throw StateError('Could not locate ${item.name} in storage.');
    }
    await information.markPlayed(video);
    statusRefresh.state++;
  };
}

class _VideoAppSelection {
  const _VideoAppSelection({required this.app, required this.saveAsDefault});

  final OpenWithApp app;
  final bool saveAsDefault;
}

Future<void> _openBuiltInPlayer(
  WidgetRef ref,
  BuildContext context, {
  required String path,
  required String name,
  List<VideoPlayerItem>? playlist,
  int? currentIndex,
  Future<void> Function(VideoPlayerItem item)? onPlaybackBegan,
}) {
  return _openBuiltInPlayerAsync(
    ref,
    context,
    path: path,
    name: name,
    playlist: playlist,
    currentIndex: currentIndex,
    onPlaybackBegan: onPlaybackBegan,
  );
}

Future<void> _openBuiltInPlayerAsync(
  WidgetRef ref,
  BuildContext context, {
  required String path,
  required String name,
  List<VideoPlayerItem>? playlist,
  int? currentIndex,
  Future<void> Function(VideoPlayerItem item)? onPlaybackBegan,
}) async {
  var items = playlist == null || playlist.isEmpty
      ? <VideoPlayerItem>[]
      : List<VideoPlayerItem>.of(playlist);
  if (items.isEmpty) {
    try {
      final categories = ref.read(fileTypeCategoriesProvider);
      final extensions = categories
          .where((category) => category.name == 'Video')
          .expand((category) => category.extensions)
          .toSet();
      final resolved = await ref
          .read(resolveVideoFileProvider)
          .playlist(path: path, extensions: extensions);
      final settings = ref.read(appSettingsProvider);
      items = resolved
          .where(
            (item) =>
                (settings.showHiddenFiles || !item.videoFile!.isHidden) &&
                (settings.showNomediaFiles || !item.videoFile!.isInsideNomedia),
          )
          .toList();
      items.sort((a, b) => compareStorageNames(a.name, b.name));
    } catch (error) {
      if (context.mounted) {
        _showOpenError(context, 'Could not build the video playlist: $error');
      }
    }
  }
  if (items.isEmpty) items = [VideoPlayerItem(path: path, name: name)];
  if (!context.mounted) return;

  final categories = ref.read(fileTypeCategoriesProvider);
  final extensions = categories
      .where((category) => category.name == 'Video')
      .expand((category) => category.extensions)
      .toSet();
  final resolver = ref.read(resolveVideoFileProvider);
  final information = ref.read(videoInformationProvider);
  final statusRefresh = ref.read(videoStatusRefreshProvider.notifier);
  for (var index = 0; index < items.length; index++) {
    final item = items[index];
    if (item.videoFile != null) continue;
    final video = await resolver(path: item.path, extensions: extensions);
    if (video != null) {
      items[index] = VideoPlayerItem(
        path: item.path,
        name: item.name,
        videoFile: video,
        knownInformation: item.knownInformation,
      );
    }
    if (!context.mounted) return;
  }

  Future<VideoFile> resolveItem(VideoPlayerItem item) async {
    final video =
        item.videoFile ??
        await resolver(path: item.path, extensions: extensions);
    if (video == null) {
      throw StateError('Could not locate ${item.name} in storage.');
    }
    return video;
  }

  Future<void> markPlayed(VideoPlayerItem item) async {
    await information.markPlayed(await resolveItem(item));
    statusRefresh.state++;
  }

  Future<Duration> loadResumePosition(VideoPlayerItem item) async =>
      information.getResumePosition(await resolveItem(item));

  Future<void> saveResumePosition(
    VideoPlayerItem item,
    Duration position,
  ) async {
    await information.saveResumePosition(await resolveItem(item), position);
  }

  Future<void> resetResumePosition(VideoPlayerItem item) async {
    await information.saveResumePosition(
      await resolveItem(item),
      Duration.zero,
    );
  }

  var startIndex = currentIndex;
  if (startIndex == null ||
      startIndex < 0 ||
      startIndex >= items.length ||
      items[startIndex].path != path) {
    startIndex = items.indexWhere((item) => item.path == path);
  }
  if (startIndex < 0) {
    items.add(VideoPlayerItem(path: path, name: name));
    startIndex = items.length - 1;
  }
  await ref.read(videoPageSettingsProvider.notifier).ready;
  if (!context.mounted) return;
  final returnToVideos = ref
      .read(videoPageSettingsProvider)
      .returnToVideosAfterPlaying;
  await Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => VideoPlayerPage(
        sessionId: DateTime.now().microsecondsSinceEpoch.toString(),
        items: items,
        initialIndex: startIndex!,
        onPlaybackBegan: onPlaybackBegan ?? markPlayed,
        onResumePosition: loadResumePosition,
        onSaveResumePosition: saveResumePosition,
        onResetResumePosition: resetResumePosition,
      ),
    ),
  );
  if (returnToVideos && context.mounted) {
    TabsManager.instance.openVideoTab();
  }
}

String _extension(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 || dot == name.length - 1
      ? ''
      : name.substring(dot + 1).toLowerCase();
}

Widget _appIcon(Uint8List? bytes) => SizedBox(
  width: 28,
  height: 28,
  child: bytes == null
      ? const Icon(Icons.video_library_outlined)
      : Image.memory(bytes, fit: BoxFit.contain),
);

void _showOpenError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
