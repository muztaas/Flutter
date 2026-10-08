import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/providers/image_providers.dart';
import '../../domain/entities/image_file_types.dart';

class ImageFilePreview extends ConsumerStatefulWidget {
  const ImageFilePreview({
    super.key,
    required this.path,
    required this.fit,
    required this.loadingBuilder,
    required this.errorBuilder,
  });

  final String path;
  final BoxFit fit;
  final WidgetBuilder loadingBuilder;
  final ImageErrorWidgetBuilder errorBuilder;

  @override
  ConsumerState<ImageFilePreview> createState() => _ImageFilePreviewState();
}

class _ImageFilePreviewState extends ConsumerState<ImageFilePreview> {
  late Future<Uint8List> _imageBytes;

  @override
  void initState() {
    super.initState();
    _imageBytes = _readImageBytes();
  }

  @override
  void didUpdateWidget(covariant ImageFilePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _imageBytes = _readImageBytes();
    }
  }

  Future<Uint8List> _readImageBytes() =>
      ref.read(imageRepositoryProvider).readFileBytes(widget.path);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _imageBytes,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return widget.errorBuilder(
            context,
            snapshot.error!,
            snapshot.stackTrace ?? StackTrace.current,
          );
        }
        final bytes = snapshot.data;
        if (bytes == null) return widget.loadingBuilder(context);

        return ImageFileTypes.isSvgPath(widget.path)
            ? SvgPicture.memory(
                bytes,
                fit: widget.fit,
                errorBuilder: widget.errorBuilder,
              )
            : Image.memory(
                bytes,
                fit: widget.fit,
                errorBuilder: widget.errorBuilder,
              );
      },
    );
  }
}
