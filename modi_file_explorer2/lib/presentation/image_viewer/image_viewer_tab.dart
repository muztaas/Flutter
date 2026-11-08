import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../core/filesystem/file_change_notifier.dart';
import '../../core/providers/image_providers.dart';
import '../../core/providers/file_type_categories_provider.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/providers/sort_rules_provider.dart';
import '../../core/providers/storage_providers.dart';
import '../../core/utils/file_name_comparator.dart';
import '../../core/utils/format_bytes.dart';
import '../../domain/entities/file_system_entry.dart';
import '../../domain/entities/file_type_category.dart';
import '../../domain/entities/image_file_types.dart';
import '../../domain/entities/sort_rule.dart';
import '../../domain/usecases/resolve_effective_sort_rule.dart';
import '../common/content_sized_menu.dart';
import '../common/detected_content_recovery.dart';
import '../common/animated_bar_visibility.dart';
import '../common/marquee_text.dart';
import '../common/name_entry_dialog.dart';
import 'image_file_preview.dart';

enum _ImageEditorTool { crop, rotate, adjust }

class _CropSelectionOverlay extends StatelessWidget {
  const _CropSelectionOverlay({
    required this.cropRect,
    required this.onChanged,
  });

  final Rect cropRect;
  final ValueChanged<Rect> onChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final handles = <(String, double, double)>[
          ('topLeft', cropRect.left, cropRect.top),
          ('topRight', cropRect.right, cropRect.top),
          ('bottomLeft', cropRect.left, cropRect.bottom),
          ('bottomRight', cropRect.right, cropRect.bottom),
        ];
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(painter: _CropSelectionPainter(cropRect)),
              ),
            ),
            for (final (handle, x, y) in handles)
              Positioned(
                left: (x * size.width - 18)
                    .clamp(0.0, size.width - 36)
                    .toDouble(),
                top: (y * size.height - 18)
                    .clamp(0.0, size.height - 36)
                    .toDouble(),
                width: 36,
                height: 36,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (details) {
                    final dx = details.delta.dx / size.width;
                    final dy = details.delta.dy / size.height;
                    const minimumSize = 0.06;
                    var left = cropRect.left;
                    var top = cropRect.top;
                    var right = cropRect.right;
                    var bottom = cropRect.bottom;
                    if (handle.contains('Left')) {
                      left = (left + dx).clamp(0.0, right - minimumSize);
                    } else {
                      right = (right + dx).clamp(left + minimumSize, 1.0);
                    }
                    if (handle.startsWith('top')) {
                      top = (top + dy).clamp(0.0, bottom - minimumSize);
                    } else {
                      bottom = (bottom + dy).clamp(top + minimumSize, 1.0);
                    }
                    onChanged(Rect.fromLTRB(left, top, right, bottom));
                  },
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.primary,
                        width: 2,
                      ),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CropSelectionPainter extends CustomPainter {
  const _CropSelectionPainter(this.cropRect);

  final Rect cropRect;

  @override
  void paint(Canvas canvas, Size size) {
    final selected = Rect.fromLTRB(
      cropRect.left * size.width,
      cropRect.top * size.height,
      cropRect.right * size.width,
      cropRect.bottom * size.height,
    );
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(selected);
    canvas.drawPath(
      outside,
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(selected, borderPaint);
    for (var index = 1; index < 3; index++) {
      final x = selected.left + selected.width * index / 3;
      final y = selected.top + selected.height * index / 3;
      canvas.drawLine(
        Offset(x, selected.top),
        Offset(x, selected.bottom),
        borderPaint..strokeWidth = 0.7,
      );
      canvas.drawLine(
        Offset(selected.left, y),
        Offset(selected.right, y),
        borderPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CropSelectionPainter oldDelegate) =>
      oldDelegate.cropRect != cropRect;
}

class ImageViewerTab extends ConsumerStatefulWidget {
  const ImageViewerTab({
    super.key,
    required this.initialPath,
    this.initialImagePaths,
    required this.currentPath,
    required this.isFullscreen,
    required this.onFullscreenChanged,
    required this.onZoomChanged,
    required this.onCurrentPathChanged,
    required this.onBoundaryHandoff,
  });

  final String initialPath;
  final List<String>? initialImagePaths;
  final String currentPath;
  final bool isFullscreen;
  final ValueChanged<bool> onFullscreenChanged;
  final ValueChanged<bool> onZoomChanged;
  final ValueChanged<String> onCurrentPathChanged;
  final ValueChanged<int> onBoundaryHandoff;

  @override
  ConsumerState<ImageViewerTab> createState() => _ImageViewerTabState();
}

class _ImageViewerTabState extends ConsumerState<ImageViewerTab> {
  final Map<String, TransformationController> _transformations = {};
  TransformationController? _activeTransformation;
  final PageController _pageController = PageController();
  Offset? _doubleTapPosition;
  List<String> _imagePaths = const [];
  Object? _loadError;
  int _currentIndex = 0;
  int? _pendingHandoffDirection;
  int _loadGeneration = 0;
  bool _isZoomed = false;
  bool _imageDeleted = false;
  bool _editorOpen = false;
  bool _isSavingEditedImage = false;
  int _imageRenderRevision = 0;
  double _rotationDegrees = 0;
  Rect _cropRect = const Rect.fromLTRB(0, 0, 1, 1);
  double _brightness = 0;
  double _contrast = 1;
  String _editorSaveMode = 'original';
  _ImageEditorTool _editorTool = _ImageEditorTool.crop;
  Size? _currentImageSize;

  void _closeImageEditor({bool afterSave = false}) {
    if (!mounted || (_isSavingEditedImage && !afterSave)) return;
    setState(() {
      _editorOpen = false;
      _isSavingEditedImage = false;
      _resetImageEditorValues();
    });
  }

  void _resetImageEditorValues() {
    _rotationDegrees = 0;
    _cropRect = const Rect.fromLTRB(0, 0, 1, 1);
    _brightness = 0;
    _contrast = 1;
    _editorSaveMode = 'original';
    _editorTool = _ImageEditorTool.crop;
  }

  bool get _transformationIsZoomed =>
      ((_activeTransformation?.value.getMaxScaleOnAxis() ?? 1) - 1).abs() >
      0.01;

  void _rotateByQuarterTurn(int direction) {
    setState(() {
      _rotationDegrees = (_rotationDegrees + direction * 90 + 180) % 360 - 180;
    });
  }

  String get _currentImagePath =>
      _imagePaths.isEmpty ? widget.currentPath : _imagePaths[_currentIndex];

  String get _currentImageName {
    return _currentImagePath
            .split(RegExp(r'[/\\]'))
            .where((part) => part.isNotEmpty)
            .lastOrNull ??
        _currentImagePath;
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  List<PopupMenuEntry<String>> _imageMenuItems() => const [
    PopupMenuItem(value: 'rename', child: Text('Rename')),
    PopupMenuItem(value: 'copy', child: Text('Copy')),
    PopupMenuItem(value: 'edit', child: Text('Edit')),
    PopupMenuItem(value: 'delete', child: Text('Delete')),
    PopupMenuItem(value: 'properties', child: Text('Properties')),
  ];

  Future<void> _handleImageMenu(String action) async {
    final path = _currentImagePath;
    switch (action) {
      case 'rename':
        await _renameCurrentImage(path);
        break;
      case 'copy':
        try {
          await Clipboard.setData(ClipboardData(text: path));
          _showMessage('Image path copied to clipboard');
        } catch (error) {
          _showMessage('Could not copy image path: $error');
        }
        break;
      case 'edit':
        _openImageEditor();
        break;
      case 'delete':
        await _deleteCurrentImage(path);
        break;
      case 'properties':
        await _showImageProperties(path);
        break;
    }
  }

  void _openImageEditor() {
    setState(() {
      _resetImageEditorValues();
      _currentImageSize = null;
      _editorOpen = true;
    });
    unawaited(_loadCurrentImageSize(_currentImagePath));
  }

  Future<void> _loadCurrentImageSize(String path) async {
    try {
      final bytes = await ref.read(imageRepositoryProvider).readFileBytes(path);
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          if (!mounted || path != _currentImagePath) return;
          setState(() {
            _currentImageSize = Size(
              descriptor.width.toDouble(),
              descriptor.height.toDouble(),
            );
          });
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
    } catch (error) {
      if (mounted && path == _currentImagePath) {
        _showMessage('Could not prepare image editing: $error');
      }
    }
  }

  Future<void> _saveEditedImage() async {
    if (_isSavingEditedImage) return;
    final sourcePath = _currentImagePath;
    final file = File(sourcePath);
    if (!await file.exists()) {
      _showMessage('Source image no longer exists');
      return;
    }
    setState(() => _isSavingEditedImage = true);
    try {
      final savingCopy = _editorSaveMode != 'original';
      final savedPath = await ref
          .read(imageEditorRepositoryProvider)
          .saveEditedImage(
            sourcePath: sourcePath,
            rotationDegrees: _rotationDegrees,
            cropLeft: _cropRect.left,
            cropTop: _cropRect.top,
            cropRight: 1 - _cropRect.right,
            cropBottom: 1 - _cropRect.bottom,
            brightness: _brightness,
            contrast: _contrast,
            overwriteOriginal: _editorSaveMode == 'original',
          );
      final savedToOriginalPath =
          File(savedPath).absolute.path == file.absolute.path;
      if (savedToOriginalPath) {
        FileChangeNotifier.instance.publish([
          FileChange(kind: FileChangeKind.modified, path: savedPath),
        ]);
      } else if (_editorSaveMode == 'original') {
        FileChangeNotifier.instance.publish([
          FileChange(
            kind: FileChangeKind.renamed,
            oldPath: sourcePath,
            newPath: savedPath,
          ),
        ]);
      } else {
        FileChangeNotifier.instance.publish([
          FileChange(kind: FileChangeKind.created, path: savedPath),
        ]);
      }
      if (savedToOriginalPath) {
        setState(() => _imageRenderRevision++);
      }
      if (!savedToOriginalPath && _editorSaveMode == 'original') {
        final updatedPaths = [..._imagePaths];
        final pathIndex = updatedPaths.indexOf(sourcePath);
        if (pathIndex >= 0) updatedPaths[pathIndex] = savedPath;
        setState(() {
          _imagePaths = updatedPaths;
        });
        widget.onCurrentPathChanged(savedPath);
      } else if (!savedToOriginalPath && !_imagePaths.contains(savedPath)) {
        setState(() {
          _imagePaths = [..._imagePaths, savedPath];
        });
      }
      _closeImageEditor(afterSave: true);
      _showMessage(savingCopy ? 'Edited copy saved' : 'Image saved in place');
    } catch (error) {
      if (mounted) setState(() => _isSavingEditedImage = false);
      _showMessage('Could not save image: $error');
    }
  }

  Future<void> _showImageProperties(String path) async {
    try {
      final file = File(path);
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) {
        throw FileSystemException('Image file is no longer available', path);
      }
      var resolution = 'Unavailable';
      Object? resolutionError;
      try {
        resolution = await _imageResolution(path);
      } catch (error) {
        resolutionError = error;
      }
      if (!mounted) return;
      if (resolutionError != null) {
        _showMessage('Could not read image resolution: $resolutionError');
      }
      final modified = stat.modified.toLocal();
      final details = [
        'Name: ${_fileName(path)}',
        'Path: $path',
        'Type: Image',
        'Size: ${formatBytes(stat.size)}',
        'Resolution: $resolution',
        'Modified: $modified',
      ];
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Image properties'),
          content: SingleChildScrollView(child: Text(details.join('\n'))),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (error) {
      _showMessage('Could not read image properties: $error');
    }
  }

  Future<String> _imageResolution(String path) async {
    if (ImageFileTypes.isSvgPath(path)) return 'Vector (SVG)';
    final bytes = await ref.read(imageRepositoryProvider).readFileBytes(path);
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        return '${descriptor.width} × ${descriptor.height}';
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  Future<void> _renameCurrentImage(String oldPath) async {
    final input = await showNameEntryDialog(
      context,
      title: 'Rename',
      initialName: _fileName(oldPath),
    );
    if (input == null) return;
    if (input.isEmpty ||
        input == '.' ||
        input == '..' ||
        input.contains('/') ||
        input.contains('\\')) {
      _showMessage('Cannot rename: enter a valid file name');
      return;
    }
    final newPath =
        '${File(oldPath).parent.path}${Platform.pathSeparator}$input';
    if (newPath == oldPath) return;
    try {
      if (await FileSystemEntity.type(newPath) !=
          FileSystemEntityType.notFound) {
        _showMessage('Cannot rename: an item with that name already exists');
        return;
      }
      await File(oldPath).rename(newPath);
      FileChangeNotifier.instance.publish([
        FileChange(
          kind: FileChangeKind.renamed,
          oldPath: oldPath,
          newPath: newPath,
        ),
      ]);
      final controller = _transformations.remove(oldPath);
      if (controller != null) _transformations[newPath] = controller;
      final updatedPaths = [..._imagePaths];
      final index = updatedPaths.indexOf(oldPath);
      if (index >= 0) updatedPaths[index] = newPath;
      setState(() {
        _imagePaths = updatedPaths;
        _imageDeleted = false;
      });
      widget.onCurrentPathChanged(newPath);
      _showMessage('Image renamed');
    } catch (error) {
      _showMessage('Could not rename image: $error');
    }
  }

  Future<void> _deleteCurrentImage(String path) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete image?'),
        content: Text('Delete "$_currentImageName"? This cannot be undone.'),
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
    if (confirmed != true) return;
    try {
      await File(path).delete();
      FileChangeNotifier.instance.publish([
        FileChange(kind: FileChangeKind.deleted, path: path),
      ]);
      final updatedPaths = [..._imagePaths]..remove(path);
      if (updatedPaths.isEmpty) {
        setState(() {
          _imagePaths = const [];
          _imageDeleted = true;
        });
        widget.onCurrentPathChanged(path);
      } else {
        final nextIndex = _currentIndex.clamp(0, updatedPaths.length - 1);
        setState(() {
          _imagePaths = updatedPaths;
          _currentIndex = nextIndex;
          _imageDeleted = false;
          _setActiveTransformation(updatedPaths[nextIndex]);
        });
        widget.onCurrentPathChanged(updatedPaths[nextIndex]);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _pageController.hasClients) {
            _pageController.jumpToPage(nextIndex);
          }
        });
      }
      _showMessage('Image deleted');
    } catch (error) {
      _showMessage('Could not delete image: $error');
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadFolderImages());
  }

  @override
  void didUpdateWidget(covariant ImageViewerTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentPath != widget.currentPath) {
      final index = _imagePaths.indexOf(widget.currentPath);
      if (index >= 0 && index != _currentIndex) {
        _currentIndex = index;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _pageController.hasClients) {
            _pageController.jumpToPage(index);
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    for (final controller in _transformations.values) {
      controller.removeListener(_notifyZoomChanged);
      controller.dispose();
    }
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadFolderImages() async {
    final generation = ++_loadGeneration;
    try {
      final settings = ref.read(appSettingsProvider);
      final folder = File(widget.initialPath).parent.path;
      final devices = widget.initialImagePaths == null
          ? await ref.read(storageRepositoryProvider).listStorageDevices()
          : const [];
      final normalizedFolder = normalizeSortPath(folder);
      final drive =
          devices
              .where(
                (device) =>
                    normalizedFolder == normalizeSortPath(device.path) ||
                    normalizedFolder.startsWith(
                      '${normalizeSortPath(device.path)}/',
                    ),
              )
              .toList()
            ..sort(
              (left, right) => right.path.length.compareTo(left.path.length),
            );
      final drivePath = drive.isEmpty ? folder : drive.first.path;
      final driveId = drive.isEmpty
          ? 'path:${normalizeSortPath(drivePath)}'
          : drive.first.id;
      await ref.read(fileTypeCategoriesProvider.notifier).ready;
      final imageExtensions =
          ref
              .read(fileTypeCategoriesProvider)
              .where((category) => category.name == 'Image')
              .firstOrNull
              ?.extensions
              .toSet() ??
          FileTypeCategory.defaults
              .where((category) => category.name == 'Image')
              .first
              .extensions
              .toSet();
      final images = widget.initialImagePaths == null
          ? await ref
                .read(imageRepositoryProvider)
                .listImageFiles(
                  folder,
                  driveRoot: drivePath,
                  showHiddenFiles: settings.showHiddenFiles,
                  showNomediaFiles: settings.showNomediaFiles,
                  extensions: imageExtensions,
                )
          : <FileSystemEntry>[];

      final List<String> orderedPaths;
      if (widget.initialImagePaths != null) {
        orderedPaths = [...widget.initialImagePaths!];
      } else {
        await ref.read(sortRulesProvider.notifier).ready;
        final rules =
            ref.read(sortRulesProvider).asData?.value ?? const <SortRule>[];
        final rule = resolveEffectiveSortRule(
          rules: rules,
          drivePath: drivePath,
          driveId: driveId,
          folderPath: folder,
        );
        final field = rule?.field ?? SortField.name;
        final ascending = rule?.order != SortOrder.descending;
        images.sort((left, right) {
          final comparison = _compareImageEntries(left, right, field);
          if (comparison != 0) return ascending ? comparison : -comparison;
          return left.path.compareTo(right.path);
        });
        orderedPaths = images.map((image) => image.path).toList();
        if (!orderedPaths.contains(widget.initialPath)) {
          final stat = await File(widget.initialPath).stat();
          if (stat.type == FileSystemEntityType.file) {
            images.add(
              FileSystemEntry(
                name: _fileName(widget.initialPath),
                path: widget.initialPath,
                isDirectory: false,
                size: stat.size,
                modified: stat.modified,
              ),
            );
            images.sort((left, right) {
              final comparison = _compareImageEntries(left, right, field);
              if (comparison != 0) return ascending ? comparison : -comparison;
              return left.path.compareTo(right.path);
            });
            orderedPaths
              ..clear()
              ..addAll(images.map((image) => image.path));
          }
        }
      }
      if (!orderedPaths.contains(widget.initialPath)) {
        orderedPaths.add(widget.initialPath);
      }
      if (orderedPaths.isEmpty) orderedPaths.add(widget.initialPath);
      final currentIndex = orderedPaths.indexOf(widget.currentPath);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _imagePaths = orderedPaths;
        _currentIndex = currentIndex < 0 ? 0 : currentIndex;
        _loadError = null;
      });
      _setActiveTransformation(orderedPaths[_currentIndex]);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageController.hasClients) {
          _pageController.jumpToPage(_currentIndex);
        }
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loadError = error;
        _imagePaths = [widget.initialPath];
        _currentIndex = 0;
      });
    }
  }

  int _compareImageEntries(
    FileSystemEntry left,
    FileSystemEntry right,
    SortField field,
  ) {
    final comparison = switch (field) {
      SortField.name => compareStorageNames(left.name, right.name),
      SortField.dateModified =>
        (left.modified?.millisecondsSinceEpoch ?? 0).compareTo(
          right.modified?.millisecondsSinceEpoch ?? 0,
        ),
      SortField.size => (left.size ?? 0).compareTo(right.size ?? 0),
    };
    return comparison != 0
        ? comparison
        : compareStorageNames(left.name, right.name);
  }

  String _fileName(String path) =>
      path.split(RegExp(r'[/\\]')).where((part) => part.isNotEmpty).last;

  void _notifyZoomChanged() {
    final zoomed = _transformationIsZoomed;
    if (_isZoomed != zoomed && mounted) {
      setState(() => _isZoomed = zoomed);
    }
    widget.onZoomChanged(zoomed);
  }

  TransformationController _transformationFor(String path) =>
      _transformations.putIfAbsent(path, TransformationController.new);

  void _setActiveTransformation(String path) {
    final next = _transformationFor(path);
    if (identical(next, _activeTransformation)) return;
    _activeTransformation?.removeListener(_notifyZoomChanged);
    _activeTransformation = next;
    next.addListener(_notifyZoomChanged);
    _isZoomed = _transformationIsZoomed;
  }

  void _handlePageChanged(int index) {
    setState(() {
      _currentIndex = index;
      _currentImageSize = null;
      _setActiveTransformation(_imagePaths[index]);
    });
    _pendingHandoffDirection = null;
    _activeTransformation?.value = Matrix4.identity();
    widget.onCurrentPathChanged(_imagePaths[index]);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final firstRetainedIndex = _currentIndex > 0 ? _currentIndex - 1 : 0;
      final retained = _imagePaths.skip(firstRetainedIndex).take(3).toSet();
      final stalePaths = _transformations.keys
          .where((path) => !retained.contains(path))
          .toList();
      for (final path in stalePaths) {
        final controller = _transformations.remove(path);
        if (controller == null) continue;
        controller.removeListener(_notifyZoomChanged);
        controller.dispose();
      }
    });
  }

  bool _handlePageNotification(ScrollNotification notification) {
    if (_isZoomed || notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      _pendingHandoffDirection = null;
    } else if (notification is OverscrollNotification &&
        notification.dragDetails != null) {
      final metrics = notification.metrics;
      final fingerDelta = notification.dragDetails!.delta.dx;
      if (metrics.extentBefore <= 0 && fingerDelta > 0) {
        _pendingHandoffDirection = -1;
      } else if (metrics.extentAfter <= 0 && fingerDelta < 0) {
        _pendingHandoffDirection = 1;
      }
    } else if (notification is ScrollEndNotification) {
      final direction = _pendingHandoffDirection;
      _pendingHandoffDirection = null;
      if (direction != null) widget.onBoundaryHandoff(direction);
    }
    return false;
  }

  void _handleDoubleTap() {
    if (_editorOpen) return;
    if (_isZoomed) {
      _activeTransformation?.value = Matrix4.identity();
      return;
    }

    final position = _doubleTapPosition;
    if (position == null) return;

    const scale = 2.5;
    if (_activeTransformation != null) {
      _activeTransformation!.value = Matrix4.identity()
        ..translateByDouble(
          position.dx * (1 - scale),
          position.dy * (1 - scale),
          0,
          1,
        )
        ..scaleByDouble(scale, scale, 1, 1);
    }
  }

  ui.ColorFilter get _editorColorFilter {
    final contrast = _contrast.clamp(0.5, 2.0);
    final brightness = _brightness.clamp(-100.0, 100.0) / 100 * 255;
    final offset = brightness + 128 * (1 - contrast);
    return ui.ColorFilter.matrix([
      contrast,
      0,
      0,
      0,
      offset,
      0,
      contrast,
      0,
      0,
      offset,
      0,
      0,
      contrast,
      0,
      offset,
      0,
      0,
      0,
      1,
      0,
    ]);
  }

  Widget _buildInlineEditorControls() {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Material(
      color: colors.surfaceContainerHigh,
      elevation: 8,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewPaddingOf(context).bottom,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Cancel editing',
                    onPressed: _isSavingEditedImage ? null : _closeImageEditor,
                    icon: const Icon(Icons.close),
                  ),
                  Expanded(
                    child: Text(
                      'Edit image',
                      style: textTheme.titleMedium,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Reset edits',
                    onPressed: _isSavingEditedImage
                        ? null
                        : () => setState(_resetImageEditorValues),
                    icon: const Icon(Icons.restart_alt),
                  ),
                ],
              ),
              SegmentedButton<_ImageEditorTool>(
                segments: const [
                  ButtonSegment(
                    value: _ImageEditorTool.crop,
                    icon: Icon(Icons.crop),
                    label: Text('Crop'),
                  ),
                  ButtonSegment(
                    value: _ImageEditorTool.rotate,
                    icon: Icon(Icons.rotate_90_degrees_ccw),
                    label: Text('Rotate'),
                  ),
                  ButtonSegment(
                    value: _ImageEditorTool.adjust,
                    icon: Icon(Icons.tune),
                    label: Text('Adjust'),
                  ),
                ],
                selected: {_editorTool},
                onSelectionChanged: (selection) =>
                    setState(() => _editorTool = selection.first),
              ),
              const SizedBox(height: 4),
              if (_editorTool == _ImageEditorTool.crop)
                Row(
                  children: [
                    const Icon(Icons.open_with, size: 18),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text('Drag the corners on the image to crop'),
                    ),
                    TextButton(
                      onPressed: () => setState(
                        () => _cropRect = const Rect.fromLTRB(0, 0, 1, 1),
                      ),
                      child: const Text('Reset crop'),
                    ),
                  ],
                )
              else if (_editorTool == _ImageEditorTool.rotate)
                Column(
                  children: [
                    Row(
                      children: [
                        IconButton(
                          tooltip: 'Rotate left 90°',
                          onPressed: () => _rotateByQuarterTurn(-1),
                          icon: const Icon(Icons.rotate_left),
                        ),
                        Expanded(
                          child: Slider(
                            value: _rotationDegrees.clamp(-180, 180).toDouble(),
                            min: -180,
                            max: 180,
                            label: '${_rotationDegrees.round()}°',
                            onChanged: (value) =>
                                setState(() => _rotationDegrees = value),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Rotate right 90°',
                          onPressed: () => _rotateByQuarterTurn(1),
                          icon: const Icon(Icons.rotate_right),
                        ),
                        SizedBox(
                          width: 42,
                          child: Text('${_rotationDegrees.round()}°'),
                        ),
                      ],
                    ),
                  ],
                )
              else
                Column(
                  children: [
                    _buildAdjustmentSlider(
                      label: 'Brightness',
                      value: _brightness,
                      min: -100,
                      max: 100,
                      valueLabel: _brightness.round().toString(),
                      onChanged: (value) => setState(() => _brightness = value),
                    ),
                    _buildAdjustmentSlider(
                      label: 'Contrast',
                      value: _contrast,
                      min: 0.5,
                      max: 2,
                      valueLabel: _contrast.toStringAsFixed(2),
                      onChanged: (value) => setState(() => _contrast = value),
                    ),
                  ],
                ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: true, label: Text('Original')),
                        ButtonSegment(value: false, label: Text('Copy')),
                      ],
                      selected: {_editorSaveMode == 'original'},
                      onSelectionChanged: (selection) => setState(
                        () => _editorSaveMode = selection.first
                            ? 'original'
                            : 'copy',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _isSavingEditedImage ? null : _saveEditedImage,
                    icon: _isSavingEditedImage
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save),
                    label: Text(_isSavingEditedImage ? 'Saving' : 'Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAdjustmentSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required String valueLabel,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(width: 82, child: Text(label)),
        Expanded(
          child: Slider(value: value, min: min, max: max, onChanged: onChanged),
        ),
        SizedBox(width: 38, child: Text(valueLabel)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AppSettings>(appSettingsProvider, (previous, next) {
      if (previous?.showHiddenFiles != next.showHiddenFiles ||
          previous?.showNomediaFiles != next.showNomediaFiles) {
        unawaited(_loadFolderImages());
      }
    });
    ref.listen<List<FileTypeCategory>>(fileTypeCategoriesProvider, (
      previous,
      next,
    ) {
      if (previous != null && previous != next) unawaited(_loadFolderImages());
    });
    ref.listen<AsyncValue<List<SortRule>>>(sortRulesProvider, (previous, next) {
      if (widget.initialImagePaths == null && next.asData != null) {
        unawaited(_loadFolderImages());
      }
    });
    return PopScope(
      canPop: !_isZoomed && !_editorOpen,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _editorOpen) {
          _closeImageEditor();
        } else if (!didPop && _isZoomed) {
          _activeTransformation?.value = Matrix4.identity();
        }
      },
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: SafeArea(
          top: false,
          bottom: false,
          child: Column(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _editorOpen
                      ? null
                      : () => widget.onFullscreenChanged(!widget.isFullscreen),
                  onDoubleTapDown: _editorOpen
                      ? null
                      : (details) {
                          _doubleTapPosition = details.localPosition;
                        },
                  onDoubleTap: _editorOpen ? null : _handleDoubleTap,
                  child: _imagePaths.isEmpty
                      ? Center(
                          child: _imageDeleted
                              ? const Text('Image deleted')
                              : const CircularProgressIndicator(),
                        )
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            final pixelRatio = MediaQuery.devicePixelRatioOf(
                              context,
                            );
                            final decodeWidth =
                                (constraints.maxWidth * pixelRatio).ceil();
                            return NotificationListener<ScrollNotification>(
                              onNotification: _handlePageNotification,
                              child: Stack(
                                children: [
                                  PageView.builder(
                                    controller: _pageController,
                                    itemCount: _imagePaths.length,
                                    physics: _editorOpen || _isZoomed
                                        ? const NeverScrollableScrollPhysics()
                                        : _imagePaths.length <= 1
                                        ? const AlwaysScrollableScrollPhysics(
                                            parent: PageScrollPhysics(),
                                          )
                                        : const PageScrollPhysics(),
                                    onPageChanged: _handlePageChanged,
                                    itemBuilder: (context, index) {
                                      final path = _imagePaths[index];
                                      final editingCurrentImage =
                                          _editorOpen &&
                                          path == _currentImagePath;
                                      final imagePreview = ImageFilePreview(
                                        key: ValueKey(
                                          '$path:$_imageRenderRevision',
                                        ),
                                        path: path,
                                        fit: BoxFit.contain,
                                        decodeWidth: decodeWidth,
                                        loadingBuilder: (_) => const Center(
                                          child: CircularProgressIndicator(),
                                        ),
                                        errorBuilder:
                                            (
                                              context,
                                              error,
                                              stackTrace,
                                            ) => Center(
                                              child: Padding(
                                                padding: const EdgeInsets.all(
                                                  24,
                                                ),
                                                child: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Text(
                                                      'Could not display image: $error',
                                                      textAlign:
                                                          TextAlign.center,
                                                      style: Theme.of(
                                                        context,
                                                      ).textTheme.bodyMedium,
                                                    ),
                                                    DetectedContentRecoveryAction(
                                                      path: path,
                                                      currentCategory: 'Image',
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                      );
                                      final shownImage = editingCurrentImage
                                          ? ColorFiltered(
                                              colorFilter: _editorColorFilter,
                                              child: imagePreview,
                                            )
                                          : imagePreview;
                                      final imageSize = _currentImageSize;
                                      final sourceAspectRatio =
                                          imageSize == null ||
                                              imageSize.height == 0
                                          ? 1.0
                                          : imageSize.width / imageSize.height;
                                      final rotationRadians =
                                          _rotationDegrees * math.pi / 180;
                                      final cosine = math
                                          .cos(rotationRadians)
                                          .abs();
                                      final sine = math
                                          .sin(rotationRadians)
                                          .abs();
                                      final rotatedAspectRatio =
                                          (sourceAspectRatio * cosine + sine) /
                                          (cosine + sourceAspectRatio * sine);
                                      return InteractiveViewer(
                                        transformationController:
                                            _transformationFor(path),
                                        panEnabled:
                                            !editingCurrentImage && _isZoomed,
                                        minScale: 1,
                                        maxScale: 6,
                                        boundaryMargin: const EdgeInsets.all(
                                          80,
                                        ),
                                        child: SizedBox(
                                          width: constraints.maxWidth,
                                          height: constraints.maxHeight,
                                          child: editingCurrentImage
                                              ? Center(
                                                  child: AspectRatio(
                                                    aspectRatio:
                                                        rotatedAspectRatio,
                                                    child: LayoutBuilder(
                                                      builder: (context, imageConstraints) {
                                                        final rotatedWidth =
                                                            sourceAspectRatio *
                                                                cosine +
                                                            sine;
                                                        final rotatedHeight =
                                                            cosine +
                                                            sourceAspectRatio *
                                                                sine;
                                                        final scale = math.min(
                                                          imageConstraints
                                                                  .maxWidth /
                                                              rotatedWidth,
                                                          imageConstraints
                                                                  .maxHeight /
                                                              rotatedHeight,
                                                        );
                                                        return Stack(
                                                          fit: StackFit.expand,
                                                          clipBehavior:
                                                              Clip.none,
                                                          children: [
                                                            Center(
                                                              child: Transform.rotate(
                                                                angle:
                                                                    rotationRadians,
                                                                child: SizedBox(
                                                                  width:
                                                                      sourceAspectRatio *
                                                                      scale,
                                                                  height: scale,
                                                                  child:
                                                                      shownImage,
                                                                ),
                                                              ),
                                                            ),
                                                            if (_editorTool ==
                                                                _ImageEditorTool
                                                                    .crop)
                                                              _CropSelectionOverlay(
                                                                cropRect:
                                                                    _cropRect,
                                                                onChanged: (value) =>
                                                                    setState(() {
                                                                      _cropRect =
                                                                          value;
                                                                    }),
                                                              ),
                                                          ],
                                                        );
                                                      },
                                                    ),
                                                  ),
                                                )
                                              : imagePreview,
                                        ),
                                      );
                                    },
                                  ),
                                  Positioned(
                                    top: 0,
                                    left: 0,
                                    right: 0,
                                    height: 40,
                                    child: AnimatedBarVisibility(
                                      visible:
                                          !_editorOpen &&
                                          !widget.isFullscreen &&
                                          _imagePaths.isNotEmpty,
                                      height: 40,
                                      child: ColoredBox(
                                        color: Colors.grey.withValues(
                                          alpha: 0.72,
                                        ),
                                        child: Row(
                                          children: [
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: MarqueeText(
                                                _currentImageName,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleSmall
                                                    ?.copyWith(
                                                      color: Theme.of(
                                                        context,
                                                      ).colorScheme.onSurface,
                                                    ),
                                                styleMode:
                                                    MarqueeStyle.pauseAndLoop,
                                              ),
                                            ),
                                            ContentSizedMenuButton<String>(
                                              menuColor: Colors.grey.withValues(
                                                alpha: 0.82,
                                              ),
                                              builder: (context, openMenu) =>
                                                  IconButton(
                                                    tooltip: 'More options',
                                                    padding: EdgeInsets.zero,
                                                    constraints:
                                                        const BoxConstraints.tightFor(
                                                          width: 40,
                                                          height: 40,
                                                        ),
                                                    onPressed: openMenu,
                                                    icon: const Icon(
                                                      Icons.more_vert,
                                                    ),
                                                  ),
                                              onSelected: _handleImageMenu,
                                              itemBuilder: (_) =>
                                                  _imageMenuItems(),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (_loadError != null)
                                    Positioned(
                                      left: 12,
                                      right: 12,
                                      bottom: 12,
                                      child: Material(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .surfaceContainerHighest
                                            .withValues(alpha: 0.9),
                                        borderRadius: BorderRadius.circular(8),
                                        child: Padding(
                                          padding: const EdgeInsets.all(8),
                                          child: Text(
                                            'Could not load neighboring images: $_loadError',
                                            textAlign: TextAlign.center,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodySmall,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ),
              if (_editorOpen) _buildInlineEditorControls(),
            ],
          ),
        ),
      ),
    );
  }
}
