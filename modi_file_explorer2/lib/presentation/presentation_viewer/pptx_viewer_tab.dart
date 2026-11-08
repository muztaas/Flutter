import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/pdf_reading_progress_provider.dart';
import '../../core/providers/pptx_file_provider.dart';
import '../../domain/entities/pdf_reading_progress.dart';
import '../../domain/repositories/pptx_file_repository.dart';
import '../common/built_in_viewer_shell.dart';
import '../common/marquee_text.dart';
import '../common/open_pptx_file.dart';

class PptxViewerTab extends ConsumerStatefulWidget {
  const PptxViewerTab({
    super.key,
    required this.path,
    required this.volumeId,
    required this.relativePath,
    required this.isChromeHidden,
    required this.onChromeHiddenChanged,
    required this.onZoomChanged,
    required this.onBoundaryHandoff,
  });

  final String path;
  final String volumeId;
  final String relativePath;
  final bool isChromeHidden;
  final ValueChanged<bool> onChromeHiddenChanged;
  final ValueChanged<bool> onZoomChanged;
  final ValueChanged<int> onBoundaryHandoff;

  @override
  ConsumerState<PptxViewerTab> createState() => _PptxViewerTabState();
}

class _PptxViewerTabState extends ConsumerState<PptxViewerTab>
    with AutomaticKeepAliveClientMixin {
  PptxReadSession? _session;
  PptxDeckInfo? _deck;
  final PageController _pageController = PageController();
  final Map<int, Future<PptxSlide>> _slides = {};
  final Map<int, TransformationController> _transformations = {};
  final Map<int, bool> _zoomedSlides = {};
  final Map<String, Future<Uint8List>> _imageBytes = {};
  Object? _loadError;
  int _currentIndex = 0;
  int _generation = 0;
  bool _isVisible = false;
  bool _isLoading = false;
  int? _fileSize;
  int? _modifiedTimeMilliseconds;

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _setVisible(MarqueeVisibility.isVisibleOf(context));
  }

  @override
  void didUpdateWidget(covariant PptxViewerTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _closePresentation();
      if (_isVisible) unawaited(_openPresentation());
    }
  }

  @override
  void dispose() {
    unawaited(_saveProgress(_currentIndex));
    _isVisible = false;
    _closePresentation();
    _pageController.dispose();
    super.dispose();
  }

  void _setVisible(bool visible) {
    if (_isVisible == visible) return;
    _isVisible = visible;
    if (visible) {
      if (_session == null && !_isLoading) unawaited(_openPresentation());
    } else {
      unawaited(_saveProgress(_currentIndex));
      _closePresentation();
    }
  }

  void _closePresentation() {
    ++_generation;
    final session = _session;
    _session = null;
    _deck = null;
    _slides.clear();
    _imageBytes.clear();
    _loadError = null;
    _isLoading = false;
    final transformations = _transformations.values.toList();
    _transformations.clear();
    _zoomedSlides.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final controller in transformations) {
        controller.dispose();
      }
    });
    widget.onZoomChanged(false);
    if (session != null) unawaited(session.close());
    if (mounted) setState(() {});
  }

  Future<void> _openPresentation() async {
    if (!_isVisible || _isLoading) return;
    final generation = ++_generation;
    setState(() {
      _isLoading = true;
      _loadError = null;
      _currentIndex = 0;
    });
    PptxReadSession? session;
    try {
      session = await ref.read(pptxFileRepositoryProvider).open(widget.path);
      if (!mounted || !_isVisible || generation != _generation) {
        await session.close();
        return;
      }
      if (session.deckInfo.slideCount == 0) {
        throw const FormatException(
          'This presentation contains no visible slides.',
        );
      }
      final fileStat = await File(widget.path).stat();
      var restoredIndex = 0;
      try {
        final saved = await ref
            .read(pdfReadingProgressRepositoryProvider)
            .get(widget.volumeId, widget.relativePath);
        if (saved != null &&
            saved.pageCount == session.deckInfo.slideCount &&
            saved.fileSize == fileStat.size &&
            saved.modifiedTimeMilliseconds ==
                fileStat.modified.millisecondsSinceEpoch) {
          restoredIndex = (saved.pageNumber - 1)
              .clamp(0, session.deckInfo.slideCount - 1)
              .toInt();
        }
      } catch (error) {
        debugPrint('Could not load presentation reading position: $error');
      }
      _session = session;
      _deck = session.deckInfo;
      _fileSize = fileStat.size;
      _modifiedTimeMilliseconds = fileStat.modified.millisecondsSinceEpoch;
      _currentIndex = restoredIndex;
      _isLoading = false;
      _loadSlide(restoredIndex);
      _loadSlide(restoredIndex + 1);
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            generation == _generation &&
            _pageController.hasClients &&
            (_pageController.page?.round() ?? 0) != restoredIndex) {
          _pageController.jumpToPage(restoredIndex);
        }
      });
    } catch (error) {
      if (session != null) await session.close();
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadError = error;
        _isLoading = false;
      });
    }
  }

  void _loadSlide(int index) {
    final session = _session;
    final deck = _deck;
    if (session == null ||
        deck == null ||
        index < 0 ||
        index >= deck.slideCount) {
      return;
    }
    _slides.putIfAbsent(index, () {
      final future = session.readSlide(index);
      future.then(
        (_) {
          if (mounted && _isVisible) setState(() {});
        },
        onError: (Object error, StackTrace stackTrace) {
          if (mounted && _isVisible) {
            setState(() => _loadError = error);
          }
        },
      );
      return future;
    });
  }

  void _handlePageChanged(int index) {
    setState(() {
      _imageBytes.clear();
      _currentIndex = index;
      _loadSlide(index);
      _loadSlide(index + 1);
      _evictDistantSlides();
    });
    unawaited(_saveProgress(index));
  }

  Future<Uint8List> _readImage(String path) {
    final session = _session;
    if (session == null) {
      return Future.error(StateError('The PPTX presentation is closed'));
    }
    return _imageBytes.putIfAbsent(path, () => session.readImage(path));
  }

  Future<void> _saveProgress(int slideIndex) async {
    final deck = _deck;
    final fileSize = _fileSize;
    final modifiedTime = _modifiedTimeMilliseconds;
    if (deck == null || fileSize == null || modifiedTime == null) return;
    try {
      await ref
          .read(pdfReadingProgressRepositoryProvider)
          .save(
            widget.volumeId,
            widget.relativePath,
            PdfReadingProgress(
              pageNumber: slideIndex + 1,
              pageFraction: 0,
              pageCount: deck.slideCount,
              fileSize: fileSize,
              modifiedTimeMilliseconds: modifiedTime,
              lastOpenedTimeMilliseconds: DateTime.now().millisecondsSinceEpoch,
            ),
          );
    } catch (error) {
      debugPrint('Could not save presentation reading position: $error');
    }
  }

  void _evictDistantSlides() {
    final keep = {_currentIndex - 1, _currentIndex, _currentIndex + 1};
    for (final index in _slides.keys.toList()) {
      if (!keep.contains(index)) _slides.remove(index);
    }
    for (final index in _transformations.keys.toList()) {
      if (keep.contains(index)) continue;
      _transformations.remove(index)?.dispose();
      _zoomedSlides.remove(index);
    }
    widget.onZoomChanged(_zoomedSlides[_currentIndex] ?? false);
  }

  TransformationController _transformationFor(int index) =>
      _transformations.putIfAbsent(index, TransformationController.new);

  void _setZoomed(int index, bool zoomed) {
    if (_zoomedSlides[index] == zoomed) return;
    setState(() => _zoomedSlides[index] = zoomed);
    if (index == _currentIndex) widget.onZoomChanged(zoomed);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final deck = _deck;
    final session = _session;
    final child = _loadError != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Could not open this PPTX presentation: $_loadError',
                textAlign: TextAlign.center,
              ),
            ),
          )
        : deck == null
        ? Center(
            child: Text(
              _isLoading
                  ? 'Loading presentation...'
                  : 'Presentation unavailable',
            ),
          )
        : Stack(
            fit: StackFit.expand,
            children: [
              PageView.builder(
                controller: _pageController,
                itemCount: deck.slideCount,
                physics: (_zoomedSlides[_currentIndex] ?? false)
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                onPageChanged: _handlePageChanged,
                itemBuilder: (context, index) {
                  _loadSlide(index);
                  final future = _slides[index];
                  if (future == null) {
                    return const Center(child: Text('Loading slide...'));
                  }
                  return FutureBuilder<PptxSlide>(
                    future: future,
                    builder: (context, snapshot) {
                      final slide = snapshot.data;
                      if (slide == null) {
                        return Center(
                          child: snapshot.hasError
                              ? const Text('This slide could not be displayed.')
                              : const Text('Loading slide...'),
                        );
                      }
                      return _PptxSlidePage(
                        key: ValueKey(index),
                        slide: slide,
                        deck: deck,
                        session: session!,
                        readImage: _readImage,
                        active: index == _currentIndex,
                        transformation: _transformationFor(index),
                        onZoomChanged: (zoomed) => _setZoomed(index, zoomed),
                      );
                    },
                  );
                },
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 72,
                child: _TabSwipeZone(onHandoff: widget.onBoundaryHandoff),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height: 72,
                child: _TabSwipeZone(onHandoff: widget.onBoundaryHandoff),
              ),
              Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 50),
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.62),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 5,
                        ),
                        child: Text(
                          '${_currentIndex + 1} / ${deck.slideCount}',
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
    return BuiltInViewerShell(
      name: widget.path.split(RegExp(r'[/\\]')).last,
      isChromeHidden: widget.isChromeHidden,
      onChromeHiddenChanged: widget.onChromeHiddenChanged,
      onOpenWithAnother: () => openPptxFile(
        context,
        ref,
        path: widget.path,
        name: widget.path.split(RegExp(r'[/\\]')).last,
        excludeBuiltIn: true,
        useSavedDefaultApps: false,
        allowSaveDefault: false,
      ),
      child: child,
    );
  }
}

class _TabSwipeZone extends StatefulWidget {
  const _TabSwipeZone({required this.onHandoff});

  final ValueChanged<int> onHandoff;

  @override
  State<_TabSwipeZone> createState() => _TabSwipeZoneState();
}

class _TabSwipeZoneState extends State<_TabSwipeZone> {
  double _dragDistance = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onHorizontalDragStart: (_) => _dragDistance = 0,
    onHorizontalDragUpdate: (details) => _dragDistance += details.delta.dx,
    onHorizontalDragEnd: (details) {
      if (_dragDistance.abs() < 40) return;
      widget.onHandoff(_dragDistance < 0 ? 1 : -1);
    },
    child: const SizedBox.expand(),
  );
}

class _PptxSlidePage extends StatelessWidget {
  const _PptxSlidePage({
    super.key,
    required this.slide,
    required this.deck,
    required this.session,
    required this.readImage,
    required this.active,
    required this.transformation,
    required this.onZoomChanged,
  });

  final PptxSlide slide;
  final PptxDeckInfo deck;
  final PptxReadSession session;
  final Future<Uint8List> Function(String path) readImage;
  final bool active;
  final TransformationController transformation;
  final ValueChanged<bool> onZoomChanged;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final height = constraints.maxHeight;
      final scale = math.min(width / deck.width, height / deck.height);
      final slideWidth = deck.width * scale;
      final slideHeight = deck.height * scale;
      return Center(
        child: InteractiveViewer(
          transformationController: transformation,
          minScale: 1,
          maxScale: 4,
          panEnabled: transformation.value.getMaxScaleOnAxis() > 1.01,
          onInteractionUpdate: (_) =>
              onZoomChanged(transformation.value.getMaxScaleOnAxis() > 1.01),
          onInteractionEnd: (_) =>
              onZoomChanged(transformation.value.getMaxScaleOnAxis() > 1.01),
          child: SizedBox(
            width: slideWidth,
            height: slideHeight,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(
                  painter: _PptxSlidePainter(
                    slide: slide,
                    deck: deck,
                    background: slide.backgroundColor == null
                        ? Colors.white
                        : Color(0xff000000 | slide.backgroundColor!),
                  ),
                ),
                for (final element in slide.elements)
                  if (active &&
                      element.type == 'image' &&
                      element.imagePath != null)
                    Positioned(
                      left: element.x * slideWidth / deck.width,
                      top: element.y * slideHeight / deck.height,
                      width: element.width * slideWidth / deck.width,
                      height: element.height * slideHeight / deck.height,
                      child: _PptxImage(
                        session: session,
                        readImage: readImage,
                        path: element.imagePath!,
                        width: (element.width * slideWidth).round(),
                        height: (element.height * slideHeight).round(),
                      ),
                    ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _PptxImage extends StatefulWidget {
  const _PptxImage({
    required this.session,
    required this.readImage,
    required this.path,
    required this.width,
    required this.height,
  });

  final PptxReadSession session;
  final Future<Uint8List> Function(String path) readImage;
  final String path;
  final int width;
  final int height;

  @override
  State<_PptxImage> createState() => _PptxImageState();
}

class _PptxImageState extends State<_PptxImage> {
  late Future<Uint8List> _future;
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _future = widget.readImage(widget.path);
  }

  @override
  void didUpdateWidget(covariant _PptxImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        !identical(oldWidget.session, widget.session)) {
      _evict();
      _bytes = null;
      _future = widget.readImage(widget.path);
    }
  }

  void _evict() {
    final bytes = _bytes;
    if (bytes != null) unawaited(MemoryImage(bytes).evict());
  }

  @override
  void dispose() {
    _evict();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: _future,
    builder: (context, snapshot) {
      final bytes = snapshot.data;
      if (bytes == null) {
        return ColoredBox(
          color: Colors.black12,
          child: Center(
            child: snapshot.hasError
                ? const Icon(Icons.broken_image_outlined)
                : const Icon(Icons.image_outlined),
          ),
        );
      }
      _bytes = bytes;
      final pixelRatio = MediaQuery.devicePixelRatioOf(context);
      return Image.memory(
        bytes,
        fit: BoxFit.contain,
        cacheWidth: (widget.width * pixelRatio).round().clamp(1, 1024),
        cacheHeight: (widget.height * pixelRatio).round().clamp(1, 1024),
        errorBuilder: (context, error, stackTrace) =>
            const Icon(Icons.broken_image_outlined),
      );
    },
  );
}

class _PptxSlidePainter extends CustomPainter {
  const _PptxSlidePainter({
    required this.slide,
    required this.deck,
    required this.background,
  });

  final PptxSlide slide;
  final PptxDeckInfo deck;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    final scale = size.width / deck.width;
    for (final element in slide.elements) {
      final rect = Rect.fromLTWH(
        element.x * scale,
        element.y * scale,
        element.width * scale,
        element.height * scale,
      );
      if (element.type == 'table') {
        _drawTable(canvas, rect, element.tableRows, scale);
      } else if (element.type == 'shape') {
        _drawShape(canvas, rect, element, scale);
      }
      if (element.paragraphs.isNotEmpty) {
        _drawText(canvas, rect, element.paragraphs, scale);
      }
    }
  }

  void _drawTable(
    Canvas canvas,
    Rect rect,
    List<List<String>> rows,
    double scale,
  ) {
    if (rows.isEmpty) return;
    final columns = rows.fold<int>(
      0,
      (count, row) => math.max(count, row.length),
    );
    if (columns == 0) return;
    final cellWidth = rect.width / columns;
    final cellHeight = rect.height / rows.length;
    final fill = Paint()..color = const Color(0xfffafafa);
    final border = Paint()
      ..color = const Color(0xff777777)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6;
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      final row = rows[rowIndex];
      for (var columnIndex = 0; columnIndex < columns; columnIndex++) {
        final cell = Rect.fromLTWH(
          rect.left + columnIndex * cellWidth,
          rect.top + rowIndex * cellHeight,
          cellWidth,
          cellHeight,
        );
        canvas.drawRect(cell, fill);
        canvas.drawRect(cell, border);
        if (columnIndex >= row.length || cell.width < 8 || cell.height < 6) {
          continue;
        }
        final text = TextPainter(
          text: TextSpan(
            text: row[columnIndex],
            style: TextStyle(
              color: const Color(0xff222222),
              fontSize: 12 * scale,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 3,
          ellipsis: '…',
        )..layout(maxWidth: (cell.width - 8).clamp(1, double.infinity));
        canvas.save();
        canvas.clipRect(cell.deflate(3));
        text.paint(canvas, Offset(cell.left + 4, cell.top + 3));
        canvas.restore();
        text.dispose();
      }
    }
  }

  void _drawShape(Canvas canvas, Rect rect, PptxElement element, double scale) {
    if (element.shape == 'line') {
      canvas.drawLine(
        rect.topLeft,
        rect.bottomRight,
        Paint()
          ..color = Color(0xff000000 | (element.lineColor ?? 0x333333))
          ..strokeWidth = (element.lineWidth * scale).clamp(0.5, 24),
      );
      return;
    }
    final fill = element.fillColor;
    final border = element.lineColor;
    final isEllipse = element.shape == 'ellipse';
    final isRounded = element.shape == 'roundRect';
    final shape = isEllipse
        ? (Path()..addOval(rect))
        : isRounded
        ? (Path()..addRRect(
            RRect.fromRectAndRadius(
              rect,
              Radius.circular(rect.shortestSide * 0.1),
            ),
          ))
        : (Path()..addRect(rect));
    if (fill != null) {
      canvas.drawPath(shape, Paint()..color = Color(0xff000000 | fill));
    }
    if (border != null) {
      canvas.drawPath(
        shape,
        Paint()
          ..color = Color(0xff000000 | border)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (element.lineWidth * scale).clamp(0.5, 24),
      );
    }
  }

  void _drawText(
    Canvas canvas,
    Rect rect,
    List<PptxTextParagraph> paragraphs,
    double scale,
  ) {
    List<TextPainter> layoutParagraphs(double factor) {
      return paragraphs
          .map((paragraph) {
            final spans = <InlineSpan>[];
            if (paragraph.bullet != null) {
              spans.add(
                TextSpan(
                  text: '${paragraph.bullet} ',
                  style: TextStyle(
                    fontSize: (paragraph.fontSize ?? 18) * scale * factor,
                  ),
                ),
              );
            }
            for (final run in paragraph.runs) {
              spans.add(
                TextSpan(
                  text: run.text,
                  style: TextStyle(
                    fontWeight: run.bold ? FontWeight.bold : null,
                    fontStyle: run.italic ? FontStyle.italic : null,
                    decoration: run.underline ? TextDecoration.underline : null,
                    fontSize:
                        (run.fontSize ?? paragraph.fontSize ?? 18) *
                        scale *
                        factor,
                    color: run.color == null
                        ? (paragraph.color == null
                              ? const Color(0xff222222)
                              : Color(0xff000000 | paragraph.color!))
                        : Color(0xff000000 | run.color!),
                  ),
                ),
              );
            }
            final painter = TextPainter(
              text: TextSpan(children: spans),
              textDirection: TextDirection.ltr,
              textAlign: _textAlignment(paragraph.alignment),
              textScaler: TextScaler.noScaling,
            )..layout(maxWidth: rect.width.clamp(1, double.infinity));
            return painter;
          })
          .toList(growable: false);
    }

    var painters = layoutParagraphs(1);
    var totalHeight = painters.fold<double>(
      0,
      (sum, painter) => sum + painter.height,
    );
    if (totalHeight > rect.height && totalHeight > 0) {
      for (final painter in painters) {
        painter.dispose();
      }
      painters = layoutParagraphs((rect.height / totalHeight).clamp(0.35, 1.0));
    }
    canvas.save();
    canvas.clipRect(rect);
    var top = rect.top;
    for (final painter in painters) {
      painter.paint(canvas, Offset(rect.left, top));
      top += painter.height;
      painter.dispose();
    }
    canvas.restore();
  }

  TextAlign _textAlignment(String alignment) => switch (alignment) {
    'center' => TextAlign.center,
    'right' => TextAlign.right,
    'justify' => TextAlign.justify,
    _ => TextAlign.left,
  };

  @override
  bool shouldRepaint(covariant _PptxSlidePainter oldDelegate) =>
      oldDelegate.slide != slide || oldDelegate.background != background;
}
