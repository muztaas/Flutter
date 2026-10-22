import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../../domain/entities/storage_device.dart';
import '../../../domain/entities/video_file.dart';
import '../../../domain/entities/video_index_record.dart';
import '../../../domain/entities/video_information.dart';
import '../../../domain/entities/video_library_scan.dart';
import '../../../domain/entities/video_path_properties.dart';
import '../../../domain/entities/video_folder.dart';
import '../../../domain/entities/video_status_target.dart';
import '../../../domain/utils/shared_storage_scan_scope.dart';
import '../../../domain/utils/storage_display_name.dart';
import '../../../domain/repositories/video_repository.dart';

class AndroidVideoRepository implements VideoRepository {
  static const _channel = MethodChannel('modi_file_explorer2/video_media');
  static const _maximumConcurrentOperations = 3;
  static const _maximumMemoryCacheBytes = 20 * 1024 * 1024;
  static const _maximumDiskCacheBytes = 50 * 1024 * 1024;

  final Map<String, VideoIndexRecord> _index = {};
  final Map<String, Map<String, String>> _knownSnapshots = {};
  final Map<String, String> _driveRoots = {};
  final Map<String, Set<String>> _videoExtensionsByDrive = {};
  final Map<String, Uint8List> _memoryThumbnails = {};
  final Map<String, Future<VideoIndexRecord?>> _informationRequests = {};
  final Map<String, Future<Uint8List?>> _thumbnailRequests = {};
  final Map<String, Set<String>> _nativeRequestIds = {};
  final List<_QueuedVideoTask> _queue = [];
  Future<void> _indexReady = Future<void>.value();
  Future<void> _indexWrites = Future<void>.value();
  int _activeOperations = 0;
  int _memoryBytes = 0;
  int _requestSequence = 0;
  bool _indexLoaded = false;

  @override
  Future<VideoLibraryScan> scanVideos({
    required StorageDevice drive,
    required Set<String> extensions,
  }) async {
    _driveRoots[drive.id] = drive.path;
    _videoExtensionsByDrive[drive.id] = extensions;
    final result = await Isolate.run(
      () => _scanVideoFiles({
        'driveId': drive.id,
        'rootPath': drive.path,
        'extensions': extensions.toList(),
      }),
    );
    final videos = (result['videos']! as List)
        .map((item) => Map<String, Object?>.from(item as Map))
        .map(
          (item) => VideoFile(
            driveId: item['driveId']! as String,
            relativePath: item['relativePath']! as String,
            name: item['name']! as String,
            extension: item['extension']! as String,
            size: item['size']! as int,
            modified: DateTime.fromMillisecondsSinceEpoch(
              item['modified']! as int,
            ),
            isHidden: item['isHidden']! as bool,
            isInsideNomedia: item['isInsideNomedia']! as bool,
          ),
        )
        .toList(growable: false);
    final folders = (result['folders']! as List)
        .map((item) => Map<String, Object?>.from(item as Map))
        .map(
          (item) => VideoFolder(
            driveId: item['driveId']! as String,
            relativePath: item['relativePath']! as String,
            name: item['name']! as String,
            isHidden: item['isHidden']! as bool,
            isInsideNomedia: item['isInsideNomedia']! as bool,
            modified: (item['modified'] as int?) == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(item['modified']! as int),
          ),
        )
        .toList(growable: false);
    return VideoLibraryScan(drive: drive, videos: videos, folders: folders);
  }

  @override
  Future<VideoFile?> getVideoAtPath({
    required StorageDevice drive,
    required String path,
    required Set<String> extensions,
  }) async {
    _driveRoots[drive.id] = drive.path;
    _videoExtensionsByDrive[drive.id] = extensions;
    final root = _normalizePath(drive.path);
    final absolutePath = _normalizePath(path);
    if (!absolutePath.startsWith('$root/')) return null;

    final file = File(path);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) return null;
    final name = file.uri.pathSegments.last;
    final extension = '.${name.split('.').last.toLowerCase()}';
    if (!extensions.contains(extension)) return null;

    final relativePath = absolutePath.substring(root.length + 1);
    final parent = file.parent.path;
    var ancestor = _normalizePath(parent);
    var isInsideNomedia = false;
    while (ancestor != root && ancestor.startsWith('$root/')) {
      if (await File(_joinPath(ancestor, '.nomedia')).exists()) {
        isInsideNomedia = true;
        break;
      }
      final parentPath = _normalizePath(Directory(ancestor).parent.path);
      if (parentPath == ancestor) break;
      ancestor = parentPath;
    }

    return VideoFile(
      driveId: drive.id,
      relativePath: relativePath,
      name: name,
      extension: extension,
      size: stat.size,
      modified: stat.modified,
      isHidden: relativePath.split('/').any((part) => part.startsWith('.')),
      isInsideNomedia: isInsideNomedia,
    );
  }

  @override
  Future<List<VideoFile>> listVideosInFolder({
    required StorageDevice drive,
    required String relativeFolderPath,
    required Set<String> extensions,
  }) async {
    _driveRoots[drive.id] = drive.path;
    final folderPath = relativeFolderPath.isEmpty
        ? drive.path
        : _absolutePathFor(drive.id, relativeFolderPath);
    final rawVideos = await Isolate.run(
      () => _scanVideoFolder({
        'driveId': drive.id,
        'rootPath': drive.path,
        'folderPath': folderPath,
        'relativeFolderPath': relativeFolderPath,
        'extensions': extensions.toList(),
      }),
    );
    return rawVideos
        .map(
          (item) => VideoFile(
            driveId: item['driveId']! as String,
            relativePath: item['relativePath']! as String,
            name: item['name']! as String,
            extension: item['extension']! as String,
            size: item['size']! as int,
            modified: DateTime.fromMillisecondsSinceEpoch(
              item['modified']! as int,
            ),
            isHidden: item['isHidden']! as bool,
            isInsideNomedia: item['isInsideNomedia']! as bool,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<VideoIndexRecord?> getInformation(VideoFile video) {
    final key = _cacheKey(video);
    return _informationRequests.putIfAbsent(key, () async {
      try {
        await _loadIndex();
        final cached = _index[key];
        if (cached?.information != null) return cached;
        final requestId = _nextRequestId();
        _registerNativeRequest(key, requestId);
        try {
          final raw = await _enqueue(
            key,
            () => _channel.invokeMapMethod<String, Object?>(
              'readVideoInformation',
              {'requestId': requestId, 'path': _absolutePath(video)},
            ),
          );
          if (raw == null) return null;
          final information = VideoInformation(
            durationMilliseconds: raw['durationMilliseconds'] as int?,
            width: raw['width'] as int?,
            height: raw['height'] as int?,
            rotationDegrees: raw['rotationDegrees'] as int? ?? 0,
            frameRate: (raw['frameRate'] as num?)?.toDouble(),
          );
          final record = (cached ?? const VideoIndexRecord()).copyWith(
            information: information,
          );
          _index[key] = record;
          await _persistIndex();
          return record;
        } finally {
          _unregisterNativeRequest(key, requestId);
        }
      } finally {
        _informationRequests.remove(key);
      }
    });
  }

  @override
  Future<VideoIndexRecord?> getCachedInformation(VideoFile video) async {
    await _loadIndex();
    return _index[_cacheKey(video)];
  }

  @override
  Future<Map<String, VideoIndexRecord>> getCachedRecords(
    List<VideoFile> videos,
  ) async {
    await _loadIndex();
    final records = <String, VideoIndexRecord>{};
    for (final video in videos) {
      final record = _index[_cacheKey(video)];
      if (record != null) records[video.relativePath] = record;
    }
    return records;
  }

  @override
  Future<void> synchronizeSnapshot(VideoLibraryScan library) async {
    await _loadIndex();
    final driveId = library.drive.id;
    final previous = _knownSnapshots[driveId];
    final current = {
      for (final video in library.videos)
        video.relativePath: _snapshotIdentity(video),
    };
    if (previous != null) {
      _index.removeWhere((key, _) {
        final owner = _keyOwner(key);
        if (owner == null || owner.$1 != driveId) return false;
        final oldIdentity = previous[owner.$2];
        return !current.containsKey(owner.$2) ||
            (oldIdentity != null && oldIdentity != current[owner.$2]);
      });
      for (final video in library.videos) {
        if (previous[video.relativePath] == current[video.relativePath]) {
          continue;
        }
        _index[_cacheKey(video)] = const VideoIndexRecord(
          status: VideoStatus.newVideo,
        );
      }
    }
    _knownSnapshots[driveId] = current;
    await _persistIndex();
  }

  @override
  Future<VideoStatusUpdateResult> setStatuses({
    required List<VideoStatusTarget> targets,
    required VideoStatus status,
  }) async {
    await _loadIndex();
    final foldersWithoutPlayedVideos = <String>[];
    for (final target in targets) {
      final snapshots = _knownSnapshots[target.driveId];
      if (snapshots == null) continue;
      final paths = target.isFolder
          ? snapshots.keys
                .where((path) => path.startsWith('${target.relativePath}/'))
                .toList()
          : <String>[target.relativePath];
      final keys = [
        for (final path in paths)
          if (snapshots[path] case final identity?)
            _cacheKeyFromSnapshot(target.driveId, path, identity),
      ];
      if (status == VideoStatus.lastPlayed && target.isFolder) {
        final playedKeys = keys.where((key) => _index[key]?.playedAt != null);
        final mostRecentKey = playedKeys.isEmpty
            ? null
            : playedKeys.reduce(
                (left, right) =>
                    _index[left]!.playedAt!.isAfter(_index[right]!.playedAt!)
                    ? left
                    : right,
              );
        if (mostRecentKey == null) {
          foldersWithoutPlayedVideos.add(target.relativePath);
          continue;
        }
        _promotePlayedRecord(mostRecentKey);
        continue;
      }
      for (final key in keys) {
        final existing = _index[key] ?? const VideoIndexRecord();
        if (status == VideoStatus.lastPlayed) {
          await _markLastPlayed(key);
        } else {
          _index[key] = existing.copyWith(
            status: status,
            clearPlayedAt:
                status == VideoStatus.none || status == VideoStatus.newVideo,
          );
        }
      }
    }
    await _persistIndex();
    return VideoStatusUpdateResult(
      foldersWithoutPlayedVideos: foldersWithoutPlayedVideos,
    );
  }

  Future<void> _markLastPlayed(String key) async {
    _promotePlayedRecord(key);
    final existing = _index[key] ?? const VideoIndexRecord();
    final currentMillis = DateTime.now().millisecondsSinceEpoch;
    final previousMillis = _index.values
        .map((record) => record.playedAt?.millisecondsSinceEpoch ?? 0)
        .fold<int>(
          0,
          (latest, timestamp) => timestamp > latest ? timestamp : latest,
        );
    final playedAt = DateTime.fromMillisecondsSinceEpoch(
      currentMillis > previousMillis ? currentMillis : previousMillis + 1,
    );
    _index[key] = existing.copyWith(
      status: VideoStatus.lastPlayed,
      playedAt: playedAt,
      playCount: existing.playCount + 1,
    );
  }

  void _promotePlayedRecord(String key) {
    for (final entry in _index.entries.toList()) {
      if (entry.value.status == VideoStatus.lastPlayed && entry.key != key) {
        _index[entry.key] = entry.value.copyWith(status: VideoStatus.finished);
      }
    }
    final existing = _index[key] ?? const VideoIndexRecord();
    _index[key] = existing.copyWith(status: VideoStatus.lastPlayed);
  }

  @override
  Future<void> markPlayed(VideoFile video) async {
    await _loadIndex();
    await _markLastPlayed(_cacheKey(video));
    await _persistIndex();
  }

  @override
  Future<Duration> getResumePosition(VideoFile video) async {
    await _loadIndex();
    return Duration(
      milliseconds: _index[_cacheKey(video)]?.resumePositionMilliseconds ?? 0,
    );
  }

  @override
  Future<void> saveResumePosition(VideoFile video, Duration position) async {
    await _loadIndex();
    final key = _cacheKey(video);
    final existing = _index[key] ?? const VideoIndexRecord();
    _index[key] = existing.copyWith(
      resumePositionMilliseconds: position.inMilliseconds
          .clamp(0, 1 << 62)
          .toInt(),
    );
    await _persistIndex();
  }

  @override
  Future<List<VideoFile>> recentlyPlayed(
    List<VideoFile> availableVideos,
  ) async {
    await _loadIndex();
    final videos = availableVideos.where((video) {
      final record = _index[_cacheKey(video)];
      return record?.playedAt != null;
    }).toList();
    videos.sort((left, right) {
      final leftTime = _index[_cacheKey(left)]!.playedAt!;
      final rightTime = _index[_cacheKey(right)]!.playedAt!;
      return rightTime.compareTo(leftTime);
    });
    return videos;
  }

  @override
  Future<void> moveRecord(VideoFile oldVideo, VideoFile newVideo) async {
    await _loadIndex();
    final oldKey = _cacheKey(oldVideo);
    final record = _index.remove(oldKey);
    if (record != null) _index[_cacheKey(newVideo)] = record;
    _knownSnapshots[oldVideo.driveId]?.remove(oldVideo.relativePath);
    _knownSnapshots.putIfAbsent(
      newVideo.driveId,
      () => <String, String>{},
    )[newVideo.relativePath] = _snapshotIdentity(
      newVideo,
    );
    await _persistIndex();
  }

  @override
  Future<VideoPathProperties> getPathProperties({
    required String driveId,
    required String relativePath,
  }) async {
    final entity = await _entityFor(driveId, relativePath);
    if (entity is! Directory) {
      final stat = await entity.stat();
      return VideoPathProperties(
        fileCount: 1,
        folderCount: 0,
        otherItemCount: 0,
        totalBytes: stat.size,
        modified: stat.modified,
      );
    }

    var fileCount = 0;
    var folderCount = 0;
    var otherItemCount = 0;
    var totalBytes = 0;
    DateTime? modified;
    Future<void> visit(Directory directory) async {
      final directoryStat = await directory.stat();
      if (modified == null || directoryStat.modified.isAfter(modified!)) {
        modified = directoryStat.modified;
      }
      await for (final child in directory.list(followLinks: false)) {
        if (child is Directory) {
          folderCount++;
          await visit(child);
        } else if (child is File) {
          fileCount++;
          final stat = await child.stat();
          totalBytes += stat.size;
          if (modified == null || stat.modified.isAfter(modified!)) {
            modified = stat.modified;
          }
          if (!_isVideoPath(driveId, child.path)) otherItemCount++;
        } else {
          otherItemCount++;
        }
      }
    }

    await visit(entity);
    return VideoPathProperties(
      fileCount: fileCount,
      folderCount: folderCount,
      otherItemCount: otherItemCount,
      totalBytes: totalBytes,
      modified: modified,
    );
  }

  @override
  Future<void> renamePath({
    required String driveId,
    required String relativePath,
    required String newName,
  }) async {
    if (newName.isEmpty ||
        newName.contains('/') ||
        newName.contains('\\') ||
        newName == '.' ||
        newName == '..') {
      throw ArgumentError.value(newName, 'newName', 'Invalid file name.');
    }
    await _loadIndex();
    final source = await _entityFor(driveId, relativePath);
    final parent = relativePath.contains('/')
        ? relativePath.substring(0, relativePath.lastIndexOf('/'))
        : '';
    final targetRelativePath = parent.isEmpty ? newName : '$parent/$newName';
    final targetPath = _absolutePathFor(driveId, targetRelativePath);
    if (await FileSystemEntity.type(targetPath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw FileSystemException(
        'A file with this name already exists',
        targetPath,
      );
    }
    if (source is File) {
      await source.rename(targetPath);
    } else if (source is Directory) {
      await source.rename(targetPath);
    } else {
      throw FileSystemException('Unsupported file type', source.path);
    }
    await _moveIndexedSubtree(driveId, relativePath, targetRelativePath);
  }

  @override
  Future<void> deletePath({
    required String driveId,
    required String relativePath,
  }) async {
    final entity = await _entityFor(driveId, relativePath);
    await entity.delete(recursive: entity is Directory);
  }

  @override
  Future<bool> pathExists({
    required String driveId,
    required String relativePath,
  }) async {
    final path = _absolutePathFor(driveId, relativePath);
    return await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.notFound;
  }

  @override
  Future<void> copyPath({
    required String sourceDriveId,
    required String sourceRelativePath,
    required String destinationDriveId,
    required String destinationRelativePath,
    required String targetName,
    required bool replaceExisting,
  }) async {
    if (targetName.isEmpty ||
        targetName.contains('/') ||
        targetName.contains('\\') ||
        targetName == '.' ||
        targetName == '..') {
      throw ArgumentError.value(targetName, 'targetName', 'Invalid file name.');
    }
    final source = await _entityFor(sourceDriveId, sourceRelativePath);
    final destination = await _entityFor(
      destinationDriveId,
      destinationRelativePath,
    );
    if (destination is! Directory) {
      throw FileSystemException(
        'The destination is not a folder',
        destination.path,
      );
    }
    final targetPath = _joinPath(destination.path, targetName);
    final normalizedSource = source.path.replaceAll('\\', '/');
    final normalizedTarget = targetPath.replaceAll('\\', '/');
    if (normalizedTarget == normalizedSource ||
        (source is Directory &&
            normalizedTarget.startsWith('$normalizedSource/'))) {
      throw FileSystemException(
        'Cannot copy a folder into itself or replace the source',
        source.path,
      );
    }
    final targetType = await FileSystemEntity.type(
      targetPath,
      followLinks: false,
    );
    if (targetType != FileSystemEntityType.notFound) {
      if (!replaceExisting) {
        throw FileSystemException(
          'A file with this name already exists',
          targetPath,
        );
      }
      switch (targetType) {
        case FileSystemEntityType.file:
          await File(targetPath).delete();
        case FileSystemEntityType.directory:
          await Directory(targetPath).delete(recursive: true);
        case FileSystemEntityType.link:
          await Link(targetPath).delete();
        case FileSystemEntityType.notFound:
          break;
        case FileSystemEntityType.pipe:
        case FileSystemEntityType.unixDomainSock:
          throw FileSystemException('Unsupported destination type', targetPath);
      }
      await _forgetIndexedSubtree(
        destinationDriveId,
        '$destinationRelativePath/$targetName',
      );
    }
    await _copyEntity(source, targetPath);
  }

  Future<void> _moveIndexedSubtree(
    String driveId,
    String oldRelativePath,
    String newRelativePath,
  ) async {
    final snapshot = _knownSnapshots[driveId];
    if (snapshot == null) return;
    final matches = snapshot.keys
        .where(
          (path) =>
              path == oldRelativePath || path.startsWith('$oldRelativePath/'),
        )
        .toList();
    final previousRecords = <String, VideoIndexRecord>{};
    for (final oldPath in matches) {
      final identity = snapshot[oldPath]!;
      final key = _cacheKeyFromSnapshot(driveId, oldPath, identity);
      final record = _index.remove(key);
      if (record != null) previousRecords[oldPath] = record;
      snapshot.remove(oldPath);
    }
    for (final oldPath in matches) {
      final newPath = oldPath == oldRelativePath
          ? newRelativePath
          : '$newRelativePath${oldPath.substring(oldRelativePath.length)}';
      final absolutePath = _absolutePathFor(driveId, newPath);
      final stat = await File(absolutePath).stat();
      final identity = '${stat.size}:${stat.modified.millisecondsSinceEpoch}';
      snapshot[newPath] = identity;
      final record = previousRecords[oldPath];
      if (record != null) {
        _index[_cacheKeyFromSnapshot(driveId, newPath, identity)] = record;
      }
    }
    await _persistIndex();
  }

  Future<void> _forgetIndexedSubtree(
    String driveId,
    String relativePath,
  ) async {
    final snapshot = _knownSnapshots[driveId];
    if (snapshot == null) return;
    final removedPaths = snapshot.keys
        .where(
          (path) => path == relativePath || path.startsWith('$relativePath/'),
        )
        .toList();
    for (final path in removedPaths) {
      final identity = snapshot.remove(path)!;
      _index.remove(_cacheKeyFromSnapshot(driveId, path, identity));
    }
    await _persistIndex();
  }

  Future<FileSystemEntity> _entityFor(
    String driveId,
    String relativePath,
  ) async {
    final path = _absolutePathFor(driveId, relativePath);
    final type = await FileSystemEntity.type(path, followLinks: false);
    return switch (type) {
      FileSystemEntityType.file => File(path),
      FileSystemEntityType.directory => Directory(path),
      _ => throw FileSystemException('Item is no longer available', path),
    };
  }

  String _absolutePathFor(String driveId, String relativePath) {
    final root = _driveRoots[driveId];
    if (root == null) {
      throw StateError('Storage drive $driveId is unavailable.');
    }
    final segments = relativePath.replaceAll('\\', '/').split('/');
    if (relativePath.isEmpty ||
        segments.any(
          (segment) => segment.isEmpty || segment == '.' || segment == '..',
        )) {
      throw ArgumentError.value(
        relativePath,
        'relativePath',
        'Invalid relative path.',
      );
    }
    final path = _joinPath(root, segments.join(Platform.pathSeparator));
    final normalizedRoot = root.replaceAll('/', '\\').toLowerCase();
    final normalizedPath = path.replaceAll('/', '\\').toLowerCase();
    if (!normalizedPath.startsWith('$normalizedRoot\\')) {
      throw ArgumentError.value(
        relativePath,
        'relativePath',
        'Path escapes the drive root.',
      );
    }
    return path;
  }

  String _joinPath(String parent, String name) =>
      '${parent.endsWith(Platform.pathSeparator) ? parent : '$parent${Platform.pathSeparator}'}$name';

  String _normalizePath(String path) =>
      path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');

  bool _isVideoPath(String driveId, String path) {
    final extension = path.split('.').last.toLowerCase();
    return _videoExtensionsByDrive[driveId]?.contains('.$extension') ?? false;
  }

  Future<void> _copyEntity(FileSystemEntity source, String targetPath) async {
    if (source is File) {
      await source.copy(targetPath);
      return;
    }
    if (source is! Directory) {
      throw FileSystemException('Unsupported file type', source.path);
    }
    final target = Directory(targetPath);
    await target.create(recursive: true);
    await for (final child in source.list(followLinks: false)) {
      await _copyEntity(
        child,
        _joinPath(targetPath, storageDisplayName(path: child.path)),
      );
    }
  }

  @override
  Future<List<int>?> getThumbnail(
    VideoFile video, {
    required int width,
    required int height,
  }) async {
    final key = '${_cacheKey(video)}-${width}x$height';
    final memoryHit = _memoryThumbnails.remove(key);
    if (memoryHit != null) {
      _memoryThumbnails[key] = memoryHit;
      return memoryHit;
    }
    final request = _thumbnailRequests.putIfAbsent(key, () async {
      try {
        final file = await _thumbnailFile(key);
        if (await file.exists()) {
          final cached = await file.readAsBytes();
          await file.setLastModified(DateTime.now());
          _rememberThumbnail(key, Uint8List.fromList(cached));
          await _trimDiskCache(file.parent);
          return _memoryThumbnails[key];
        }
        final requestId = _nextRequestId();
        _registerNativeRequest(key, requestId);
        try {
          final bytes = await _enqueue(
            key,
            () => _channel.invokeMethod<Uint8List>('generateVideoThumbnail', {
              'requestId': requestId,
              'path': _absolutePath(video),
              'width': width,
              'height': height,
            }),
          );
          if (bytes == null || bytes.isEmpty) return null;
          final thumbnail = Uint8List.fromList(bytes);
          await file.parent.create(recursive: true);
          await file.writeAsBytes(thumbnail, flush: true);
          await file.setLastModified(DateTime.now());
          _rememberThumbnail(key, thumbnail);
          await _trimDiskCache(file.parent);
          return thumbnail;
        } on PlatformException catch (error) {
          if (error.code == 'THUMBNAIL_UNAVAILABLE') return null;
          rethrow;
        } finally {
          _unregisterNativeRequest(key, requestId);
        }
      } finally {
        _thumbnailRequests.remove(key);
      }
    });
    return request;
  }

  @override
  void cancelPending(VideoFile video) {
    final key = _cacheKey(video);
    bool belongsToVideo(String requestKey) =>
        requestKey == key || requestKey.startsWith('$key-');
    for (final task
        in _queue.where((task) => belongsToVideo(task.key)).toList()) {
      _queue.remove(task);
      task.cancel();
    }
    for (final entry in _nativeRequestIds.entries.where(
      (entry) => belongsToVideo(entry.key),
    )) {
      for (final requestId in entry.value) {
        unawaited(
          _channel
              .invokeMethod<void>('cancelVideoRequest', {
                'requestId': requestId,
              })
              .catchError((Object error) {
                debugPrint('Could not cancel video media request: $error');
              }),
        );
      }
    }
  }

  Future<T?> _enqueue<T>(String key, Future<T?> Function() operation) {
    final completer = Completer<T?>();
    final task = _QueuedVideoTask(
      key: key,
      run: () async {
        try {
          completer.complete(await operation());
        } catch (error, stackTrace) {
          completer.completeError(error, stackTrace);
        }
      },
      cancel: () => completer.complete(null),
    );
    _queue.add(task);
    _pumpQueue();
    return completer.future;
  }

  void _pumpQueue() {
    while (_activeOperations < _maximumConcurrentOperations &&
        _queue.isNotEmpty) {
      final task = _queue.removeAt(0);
      _activeOperations++;
      unawaited(
        Future<void>.sync(task.run).whenComplete(() {
          _activeOperations--;
          _pumpQueue();
        }),
      );
    }
  }

  String _nextRequestId() => 'video-${_requestSequence++}';

  void _registerNativeRequest(String key, String requestId) {
    _nativeRequestIds.putIfAbsent(key, () => <String>{}).add(requestId);
  }

  void _unregisterNativeRequest(String key, String requestId) {
    final requests = _nativeRequestIds[key];
    requests?.remove(requestId);
    if (requests?.isEmpty ?? false) _nativeRequestIds.remove(key);
  }

  String _cacheKey(VideoFile video) => base64Url
      .encode(
        utf8.encode(
          '${video.driveId}|${video.relativePath}|${video.size}|'
          '${video.modified.millisecondsSinceEpoch}',
        ),
      )
      .replaceAll('=', '');

  String _snapshotIdentity(VideoFile video) =>
      '${video.size}:${video.modified.millisecondsSinceEpoch}';

  String _cacheKeyFromSnapshot(
    String driveId,
    String relativePath,
    String identity,
  ) {
    final parts = identity.split(':');
    if (parts.length != 2) {
      throw FormatException('Invalid video snapshot identity: $identity');
    }
    return base64Url
        .encode(utf8.encode('$driveId|$relativePath|${parts[0]}|${parts[1]}'))
        .replaceAll('=', '');
  }

  (String, String)? _keyOwner(String key) {
    try {
      final identity = utf8.decode(base64Url.decode(base64Url.normalize(key)));
      final parts = identity.split('|');
      if (parts.length < 4) return null;
      return (parts.first, parts.sublist(1, parts.length - 2).join('|'));
    } on FormatException {
      return null;
    }
  }

  String _absolutePath(VideoFile video) {
    final root = _driveRoots[video.driveId];
    if (root == null) {
      throw StateError('Storage drive ${video.driveId} is not available.');
    }
    return video.relativePath.isEmpty
        ? root
        : '$root${Platform.pathSeparator}'
              '${video.relativePath.replaceAll('/', Platform.pathSeparator)}';
  }

  Future<Directory> _thumbnailDirectory() async {
    final cache = await getTemporaryDirectory();
    return Directory('${cache.path}${Platform.pathSeparator}video-thumbnails');
  }

  Future<File> _thumbnailFile(String key) async {
    final directory = await _thumbnailDirectory();
    return File('${directory.path}${Platform.pathSeparator}$key.jpg');
  }

  void _rememberThumbnail(String key, Uint8List thumbnail) {
    final existing = _memoryThumbnails.remove(key);
    if (existing != null) _memoryBytes -= existing.length;
    _memoryThumbnails[key] = thumbnail;
    _memoryBytes += thumbnail.length;
    while (_memoryBytes > _maximumMemoryCacheBytes &&
        _memoryThumbnails.isNotEmpty) {
      final oldestKey = _memoryThumbnails.keys.first;
      _memoryBytes -= _memoryThumbnails.remove(oldestKey)!.length;
    }
  }

  Future<void> _trimDiskCache(Directory directory) async {
    final files = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.jpg')) files.add(entity);
    }
    final sizes = <File, int>{};
    var totalBytes = 0;
    for (final file in files) {
      final length = await file.length();
      sizes[file] = length;
      totalBytes += length;
    }
    if (totalBytes <= _maximumDiskCacheBytes) return;
    files.sort(
      (left, right) =>
          left.lastModifiedSync().compareTo(right.lastModifiedSync()),
    );
    for (final file in files) {
      if (totalBytes <= _maximumDiskCacheBytes) break;
      await file.delete();
      totalBytes -= sizes[file] ?? 0;
    }
  }

  Future<void> _loadIndex() async {
    if (_indexLoaded) return _indexReady;
    _indexLoaded = true;
    _indexReady = () async {
      final support = await getApplicationSupportDirectory();
      final file = File(
        '${support.path}${Platform.pathSeparator}video-index.json',
      );
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Saved video index is invalid.');
      }
      final records = decoded['records'] is Map<String, dynamic>
          ? decoded['records']! as Map<String, dynamic>
          : decoded;
      for (final entry in records.entries) {
        if (entry.key == 'snapshots' || entry.key == 'version') continue;
        final raw = entry.value;
        if (raw is! Map) {
          throw const FormatException('A saved video index record is invalid.');
        }
        _index[entry.key] = VideoIndexRecord.fromJson(
          Map<String, Object?>.from(raw),
        );
      }
      final snapshots = decoded['snapshots'];
      if (snapshots is Map) {
        for (final entry in snapshots.entries) {
          if (entry.value is! Map) {
            throw const FormatException('A saved video snapshot is invalid.');
          }
          _knownSnapshots[entry.key.toString()] = Map<String, String>.from(
            entry.value as Map,
          );
        }
      }
    }();
    return _indexReady;
  }

  Future<void> _persistIndex() async {
    final support = await getApplicationSupportDirectory();
    final file = File(
      '${support.path}${Platform.pathSeparator}video-index.json',
    );
    final temporary = File('${file.path}.tmp');
    final encoded = jsonEncode({
      'version': 2,
      'records': {
        for (final entry in _index.entries) entry.key: entry.value.toJson(),
      },
      'snapshots': _knownSnapshots,
    });
    _indexWrites = _indexWrites.then((_) async {
      await temporary.writeAsString(encoded, flush: true);
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
    });
    return _indexWrites;
  }
}

class _QueuedVideoTask {
  const _QueuedVideoTask({
    required this.key,
    required this.run,
    required this.cancel,
  });

  final String key;
  final Future<void> Function() run;
  final void Function() cancel;
}

Map<String, Object?> _scanVideoFiles(Map<String, Object?> arguments) {
  final driveId = arguments['driveId']! as String;
  final rootPath = arguments['rootPath']! as String;
  final extensions = (arguments['extensions']! as List).cast<String>().toSet();
  final root = Directory(rootPath);
  final pending =
      <
        ({
          Directory directory,
          String relativePath,
          bool hidden,
          bool insideNomedia,
        })
      >[
        (
          directory: root,
          relativePath: '',
          hidden: false,
          insideNomedia: false,
        ),
      ];
  final directoryMetadata =
      <
        String,
        ({bool hidden, bool insideNomedia, String name, int? modified})
      >{};
  final videos = <Map<String, Object?>>[];

  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    late final List<FileSystemEntity> entries;
    try {
      entries = current.directory.listSync(followLinks: false);
    } on FileSystemException catch (error) {
      if (current.relativePath.isEmpty) rethrow;
      debugPrint(
        'Could not scan video folder ${current.directory.path}: $error',
      );
      continue;
    }

    for (final entry in entries) {
      if (entry is Link) continue;
      final name = _entryName(entry.path);
      final relativePath = current.relativePath.isEmpty
          ? name
          : '${current.relativePath}/$name';
      final hidden = current.hidden || name.startsWith('.');
      if (entry is Directory) {
        if (!SharedStorageScanScope.shouldDescendIntoRelativePath(
          relativePath,
        )) {
          continue;
        }
        var insideNomedia = current.insideNomedia;
        if (relativePath.isNotEmpty &&
            File(
              '${entry.path}${Platform.pathSeparator}.nomedia',
            ).existsSync()) {
          insideNomedia = true;
        }
        int? modified;
        try {
          modified = entry.statSync().modified.millisecondsSinceEpoch;
        } on FileSystemException catch (error) {
          debugPrint(
            'Could not read video folder metadata for ${entry.path}: $error',
          );
        }
        directoryMetadata[relativePath] = (
          hidden: hidden,
          insideNomedia: insideNomedia,
          name: name,
          modified: modified,
        );
        pending.add((
          directory: entry,
          relativePath: relativePath,
          hidden: hidden,
          insideNomedia: insideNomedia,
        ));
        continue;
      }
      if (entry is! File) continue;
      if (!SharedStorageScanScope.shouldIncludeRelativePath(relativePath)) {
        continue;
      }
      final dot = name.lastIndexOf('.');
      final extension = dot < 0 ? '' : name.substring(dot).toLowerCase();
      if (!extensions.contains(extension)) continue;
      try {
        final stat = entry.statSync();
        videos.add({
          'driveId': driveId,
          'relativePath': relativePath,
          'name': name,
          'extension': extension,
          'size': stat.size,
          'modified': stat.modified.millisecondsSinceEpoch,
          'isHidden': hidden,
          'isInsideNomedia': current.insideNomedia,
        });
      } on FileSystemException catch (error) {
        debugPrint('Could not read video metadata for ${entry.path}: $error');
      }
    }
  }

  final containingFolders = <String>{};
  for (final video in videos) {
    var parent = video['relativePath']! as String;
    final separator = parent.lastIndexOf('/');
    parent = separator < 0 ? '' : parent.substring(0, separator);
    while (parent.isNotEmpty) {
      containingFolders.add(parent);
      final parentSeparator = parent.lastIndexOf('/');
      parent = parentSeparator < 0 ? '' : parent.substring(0, parentSeparator);
    }
  }
  final folders = containingFolders
      .map((relativePath) {
        final metadata = directoryMetadata[relativePath]!;
        return {
          'driveId': driveId,
          'relativePath': relativePath,
          'name': metadata.name,
          'isHidden': metadata.hidden,
          'isInsideNomedia': metadata.insideNomedia,
          'modified': metadata.modified,
        };
      })
      .toList(growable: false);
  return {'videos': videos, 'folders': folders};
}

List<Map<String, Object?>> _scanVideoFolder(Map<String, Object?> arguments) {
  final driveId = arguments['driveId']! as String;
  final rootPath = arguments['rootPath']! as String;
  final folderPath = arguments['folderPath']! as String;
  final relativeFolderPath = arguments['relativeFolderPath']! as String;
  final extensions = (arguments['extensions']! as List).cast<String>().toSet();
  final root = _normalizeVideoPath(rootPath);
  final folder = Directory(folderPath);
  final hiddenFolder = relativeFolderPath
      .split('/')
      .any((part) => part.startsWith('.'));
  var insideNomedia = false;
  var ancestor = _normalizeVideoPath(folderPath);
  while (ancestor != root && ancestor.startsWith('$root/')) {
    if (File('$ancestor/.nomedia').existsSync()) {
      insideNomedia = true;
      break;
    }
    final parent = _normalizeVideoPath(Directory(ancestor).parent.path);
    if (parent == ancestor) break;
    ancestor = parent;
  }
  return folder
      .listSync(followLinks: false)
      .whereType<File>()
      .map((file) {
        final name = _entryName(file.path);
        final dot = name.lastIndexOf('.');
        final extension = dot < 0 ? '' : name.substring(dot).toLowerCase();
        if (!extensions.contains(extension)) return null;
        try {
          final stat = file.statSync();
          final relativePath = relativeFolderPath.isEmpty
              ? name
              : '$relativeFolderPath/$name';
          return {
            'driveId': driveId,
            'relativePath': relativePath,
            'name': name,
            'extension': extension,
            'size': stat.size,
            'modified': stat.modified.millisecondsSinceEpoch,
            'isHidden': hiddenFolder || name.startsWith('.'),
            'isInsideNomedia': insideNomedia,
          };
        } on FileSystemException {
          rethrow;
        }
      })
      .whereType<Map<String, Object?>>()
      .toList(growable: false);
}

String _normalizeVideoPath(String path) =>
    path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');

String _entryName(String path) {
  final segments = path.split(Platform.pathSeparator);
  return segments.isEmpty ? path : segments.last;
}
