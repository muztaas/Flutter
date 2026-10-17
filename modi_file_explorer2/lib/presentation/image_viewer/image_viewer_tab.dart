import 'package:flutter/material.dart';

import 'image_file_preview.dart';

class ImageViewerTab extends StatefulWidget {
  const ImageViewerTab({
    super.key,
    required this.path,
    required this.isFullscreen,
    required this.onFullscreenChanged,
    required this.onZoomChanged,
  });

  final String path;
  final bool isFullscreen;
  final ValueChanged<bool> onFullscreenChanged;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<ImageViewerTab> createState() => _ImageViewerTabState();
}

class _ImageViewerTabState extends State<ImageViewerTab> {
  final TransformationController _transformationController =
      TransformationController();
  Offset? _doubleTapPosition;

  bool get _isZoomed =>
      (_transformationController.value.getMaxScaleOnAxis() - 1).abs() > 0.01;

  @override
  void initState() {
    super.initState();
    _transformationController.addListener(_notifyZoomChanged);
  }

  @override
  void didUpdateWidget(covariant ImageViewerTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _transformationController.value = Matrix4.identity();
    }
  }

  @override
  void dispose() {
    _transformationController.removeListener(_notifyZoomChanged);
    _transformationController.dispose();
    super.dispose();
  }

  void _notifyZoomChanged() {
    widget.onZoomChanged(_isZoomed);
  }

  Future<bool> _handleBack() async {
    if (!_isZoomed) return true;

    _transformationController.value = Matrix4.identity();
    return false;
  }

  void _handleDoubleTap() {
    if (_isZoomed) {
      _transformationController.value = Matrix4.identity();
      return;
    }

    final position = _doubleTapPosition;
    if (position == null) return;

    const scale = 2.5;
    _transformationController.value = Matrix4.identity()
      ..translate(position.dx * (1 - scale), position.dy * (1 - scale))
      ..scale(scale);
  }

  @override
  Widget build(BuildContext context) {
    final content = LayoutBuilder(
      builder: (context, constraints) => InteractiveViewer(
        transformationController: _transformationController,
        minScale: 1,
        maxScale: 6,
        boundaryMargin: const EdgeInsets.all(80),
        child: SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: ImageFilePreview(
            path: widget.path,
            fit: BoxFit.contain,
            loadingBuilder: (context) =>
                const Center(child: CircularProgressIndicator()),
            errorBuilder: (context, error, stackTrace) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not display image: $error',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return WillPopScope(
      onWillPop: _handleBack,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: SafeArea(
          top: widget.isFullscreen,
          bottom: !widget.isFullscreen,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () =>
                widget.onFullscreenChanged(!widget.isFullscreen),
            onDoubleTapDown: (details) {
              _doubleTapPosition = details.localPosition;
            },
            onDoubleTap: _handleDoubleTap,
            child: SizedBox.expand(child: content),
          ),
        ),
      ),
    );
  }
}
