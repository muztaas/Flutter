import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/image_providers.dart';
import '../../core/providers/file_type_categories_provider.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/providers/sort_rules_provider.dart';
import '../../core/providers/storage_providers.dart';
import '../../core/utils/file_name_comparator.dart';
import '../../domain/entities/file_system_entry.dart';
import '../../domain/entities/file_type_category.dart';
import '../../domain/entities/sort_rule.dart';
import '../../domain/usecases/resolve_effective_sort_rule.dart';
import '../common/marquee_text.dart';
import 'image_file_preview.dart';

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

  bool get _transformationIsZoomed =>
      ((_activeTransformation?.value.getMaxScaleOnAxis() ?? 1) - 1).abs() >
      0.01;

  String get _currentImageName {
    final currentPath = _imagePaths.isEmpty
        ? widget.currentPath
        : _imagePaths[_currentIndex];
    return currentPath
            .split(RegExp(r'[/\\]'))
            .where((part) => part.isNotEmpty)
            .lastOrNull ??
        currentPath;
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
      canPop: !_isZoomed,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isZoomed) {
          _activeTransformation?.value = Matrix4.identity();
        }
      },
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: SafeArea(
          top: false,
          bottom: false,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onFullscreenChanged(!widget.isFullscreen),
            onDoubleTapDown: (details) {
              _doubleTapPosition = details.localPosition;
            },
            onDoubleTap: _handleDoubleTap,
            child: _imagePaths.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final pixelRatio = MediaQuery.devicePixelRatioOf(context);
                      final decodeWidth = (constraints.maxWidth * pixelRatio)
                          .ceil();
                      return NotificationListener<ScrollNotification>(
                        onNotification: _handlePageNotification,
                        child: Stack(
                          children: [
                            if (!widget.isFullscreen)
                              Positioned(
                                top: 0,
                                left: 0,
                                right: 0,
                                height: 40,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: MarqueeText(
                                      _currentImageName,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleSmall,
                                      styleMode: MarqueeStyle.pauseAndLoop,
                                    ),
                                  ),
                                ),
                              ),
                            PageView.builder(
                              controller: _pageController,
                              itemCount: _imagePaths.length,
                              physics: _isZoomed
                                  ? const NeverScrollableScrollPhysics()
                                  : _imagePaths.length <= 1
                                  ? const AlwaysScrollableScrollPhysics(
                                      parent: PageScrollPhysics(),
                                    )
                                  : const PageScrollPhysics(),
                              onPageChanged: _handlePageChanged,
                              itemBuilder: (context, index) {
                                final path = _imagePaths[index];
                                return InteractiveViewer(
                                  transformationController: _transformationFor(
                                    path,
                                  ),
                                  panEnabled: _isZoomed,
                                  minScale: 1,
                                  maxScale: 6,
                                  boundaryMargin: const EdgeInsets.all(80),
                                  child: SizedBox(
                                    width: constraints.maxWidth,
                                    height: constraints.maxHeight,
                                    child: ImageFilePreview(
                                      key: ValueKey(path),
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
                                              padding: const EdgeInsets.all(24),
                                              child: Text(
                                                'Could not display image: $error',
                                                textAlign: TextAlign.center,
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.bodyMedium,
                                              ),
                                            ),
                                          ),
                                    ),
                                  ),
                                );
                              },
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
      ),
    );
  }
}
