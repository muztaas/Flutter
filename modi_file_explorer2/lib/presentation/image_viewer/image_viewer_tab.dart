import 'package:flutter/material.dart';

import 'image_file_preview.dart';

class ImageViewerTab extends StatelessWidget {
  const ImageViewerTab({
    super.key,
    required this.path,
    required this.isFullscreen,
    required this.onFullscreenChanged,
  });

  final String path;
  final bool isFullscreen;
  final ValueChanged<bool> onFullscreenChanged;

  @override
  Widget build(BuildContext context) {
    final content = LayoutBuilder(
      builder: (context, constraints) => InteractiveViewer(
        minScale: 1,
        maxScale: 6,
        boundaryMargin: const EdgeInsets.all(80),
        child: SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: ImageFilePreview(
            path: path,
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

    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: isFullscreen,
        bottom: !isFullscreen,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onFullscreenChanged(!isFullscreen),
          child: SizedBox.expand(child: content),
        ),
      ),
    );
  }
}
