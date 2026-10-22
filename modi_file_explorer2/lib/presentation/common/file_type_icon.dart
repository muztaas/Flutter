import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/installed_apps_providers.dart';
import '../../core/providers/file_type_categories_provider.dart';
import '../../core/providers/storage_providers.dart';
import '../../core/providers/video_providers.dart';
import '../../core/utils/file_type_colors.dart';
import '../../domain/entities/file_type_category.dart';
import '../../domain/entities/storage_device.dart';
import '../../domain/entities/video_file.dart';

class FileTypeIcon extends ConsumerStatefulWidget {
  const FileTypeIcon({
    super.key,
    required this.extension,
    this.isFolder = false,
    this.path,
    this.driveId,
    this.relativePath,
    this.video,
    this.size = 24,
    this.thumbnailSize = 36,
  });

  final String extension;
  final bool isFolder;
  final String? path;
  final String? driveId;
  final String? relativePath;
  final VideoFile? video;
  final double size;
  final double thumbnailSize;

  @override
  ConsumerState<FileTypeIcon> createState() => _FileTypeIconState();
}

class _FileTypeIconState extends ConsumerState<FileTypeIcon> {
  static Future<List<StorageDevice>>? _storageDevices;
  Uint8List? _thumbnail;
  Uint8List? _applicationIcon;
  int _requestGeneration = 0;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  @override
  void didUpdateWidget(covariant FileTypeIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.driveId != widget.driveId ||
        oldWidget.relativePath != widget.relativePath ||
        oldWidget.video != widget.video ||
        oldWidget.extension != widget.extension ||
        oldWidget.isFolder != widget.isFolder) {
      _requestGeneration++;
      _thumbnail = null;
      _applicationIcon = null;
      _loadThumbnail();
    }
  }

  Future<void> _loadThumbnail() async {
    if (widget.isFolder) {
      return;
    }
    final colorType = fileTypeColorForExtension(
      widget.extension,
      categories: ref.read(fileTypeCategoriesProvider),
    );
    if (colorType == FileTypeColor.package && widget.path != null) {
      final generation = ++_requestGeneration;
      try {
        final icon = await getInstalledAppsRepository().getApkIcon(
          widget.path!,
          size: 64,
        );
        if (!mounted || generation != _requestGeneration || icon == null) {
          return;
        }
        setState(() => _applicationIcon = Uint8List.fromList(icon));
      } catch (error) {
        debugPrint('Could not load an APK icon: $error');
      }
      return;
    }
    if (colorType != FileTypeColor.video ||
        (widget.video == null && widget.path == null)) {
      return;
    }
    final generation = ++_requestGeneration;
    try {
      final video = widget.video ?? await _videoForPath();
      if (video == null) return;
      final bytes = await ref
          .read(videoInformationProvider)
          .getThumbnail(video, width: 160, height: 90);
      if (!mounted || generation != _requestGeneration || bytes == null) {
        return;
      }
      setState(() => _thumbnail = Uint8List.fromList(bytes));
    } catch (error) {
      debugPrint('Could not load a video thumbnail: $error');
    }
  }

  Future<VideoFile?> _videoForPath() async {
    final path = widget.path;
    if (path == null) return null;
    var driveId = widget.driveId;
    var relativePath = widget.relativePath;
    final devices = await _getStorageDevices();
    if (driveId == null || relativePath == null) {
      final normalizedPath = _normalizePath(path);
      StorageDevice? matchedDrive;
      for (final device in devices) {
        final root = _normalizePath(device.path);
        if ((normalizedPath == root || normalizedPath.startsWith('$root/')) &&
            (matchedDrive == null ||
                root.length > _normalizePath(matchedDrive.path).length)) {
          matchedDrive = device;
        }
      }
      if (matchedDrive == null) return null;
      driveId = matchedDrive.id;
      relativePath = path
          .replaceAll('\\', '/')
          .substring(matchedDrive.path.replaceAll('\\', '/').length)
          .replaceFirst(RegExp(r'^/+'), '');
    }
    final drive = devices.where((device) => device.id == driveId).firstOrNull;
    if (drive == null) return null;
    final extensions =
        ref
            .read(fileTypeCategoriesProvider)
            .where((category) => category.name == 'Video')
            .firstOrNull
            ?.extensions
            .toSet() ??
        {widget.extension};
    final normalizedPath = path.replaceAll('\\', '/');
    final absolutePath = relativePath.isEmpty
        ? drive.path
        : '${drive.path}/${relativePath.replaceAll('\\', '/')}';
    return ref
        .read(videoRepositoryProvider)
        .getVideoAtPath(
          drive: drive,
          path: widget.driveId == null ? normalizedPath : absolutePath,
          extensions: extensions,
        );
  }

  Future<List<StorageDevice>> _getStorageDevices() async {
    final cached = _storageDevices;
    if (cached != null) return cached;

    final request = ref.read(storageRepositoryProvider).listStorageDevices();
    _storageDevices = request;
    try {
      final devices = await request;
      if (devices.isEmpty && identical(_storageDevices, request)) {
        _storageDevices = null;
      }
      return devices;
    } catch (_) {
      if (identical(_storageDevices, request)) _storageDevices = null;
      rethrow;
    }
  }

  String _normalizePath(String path) =>
      path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '').toLowerCase();

  @override
  Widget build(BuildContext context) {
    ref.listen<List<FileTypeCategory>>(fileTypeCategoriesProvider, (_, _) {
      _requestGeneration++;
      _thumbnail = null;
      _applicationIcon = null;
      _loadThumbnail();
    });
    final colorType = widget.isFolder
        ? FileTypeColor.folder
        : fileTypeColorForExtension(
            widget.extension,
            categories: ref.watch(fileTypeCategoriesProvider),
          );
    final preview = colorType == FileTypeColor.package
        ? _applicationIcon
        : colorType == FileTypeColor.video
        ? _thumbnail
        : null;
    if (preview != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Image.memory(
          preview,
          width: widget.thumbnailSize,
          height: widget.thumbnailSize,
          fit: BoxFit.cover,
          cacheWidth: (widget.thumbnailSize * 2).round(),
          errorBuilder: (_, _, _) => _fallbackIcon(context, colorType),
        ),
      );
    }
    return _fallbackIcon(context, colorType);
  }

  Widget _fallbackIcon(BuildContext context, FileTypeColor colorType) {
    return Icon(
      widget.isFolder ? Icons.folder_outlined : _iconFor(colorType),
      size: widget.size,
      color: fileTypeColor(context, colorType),
    );
  }

  IconData _iconFor(FileTypeColor type) => switch (type) {
    FileTypeColor.folder => Icons.folder_outlined,
    FileTypeColor.pdf => Icons.picture_as_pdf_outlined,
    FileTypeColor.spreadsheet => Icons.table_chart_outlined,
    FileTypeColor.document => Icons.description_outlined,
    FileTypeColor.presentation => Icons.slideshow_outlined,
    FileTypeColor.audio => Icons.audiotrack_outlined,
    FileTypeColor.video => Icons.play_arrow,
    FileTypeColor.image => Icons.image_outlined,
    FileTypeColor.archive => Icons.folder_zip_outlined,
    FileTypeColor.package => Icons.android_outlined,
    FileTypeColor.code ||
    FileTypeColor.text => Icons.insert_drive_file_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}
