import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../core/providers/pdf_reading_progress_provider.dart';
import '../../core/providers/pptx_file_provider.dart';
import '../../domain/entities/pdf_reading_progress.dart';
import '../../domain/repositories/pptx_file_repository.dart';
import '../common/built_in_viewer_shell.dart';
import '../common/marquee_text.dart';
import '../common/office_chart.dart';
import '../common/open_pptx_file.dart';

const _pptPointsToLogicalPixels = 4 / 3;

Color _officeColor(int value) =>
    Color(value <= 0xFFFFFF ? 0xFF000000 | value : value & 0xFFFFFFFF);

List<double> _gradientStops(List<double> stops, int colorCount) {
  if (stops.length == colorCount &&
      stops.first == 0 &&
      stops.last == 1 &&
      stops.asMap().entries.every(
        (entry) => entry.key == 0 || stops[entry.key] >= stops[entry.key - 1],
      )) {
    return stops;
  }
  return List<double>.generate(
    colorCount,
    (index) => index / (colorCount - 1),
    growable: false,
  );
}

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
  final LinkedHashMap<String, Future<Uint8List>> _imageBytes =
      LinkedHashMap<String, Future<Uint8List>>();
  Object? _loadError;
  int _currentIndex = 0;
  List<String> _notShownFeatures = const [];
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
    _notShownFeatures = const [];
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
        (slide) {
          unawaited(_registerFonts(slide, session));
          if (mounted && _isVisible) {
            setState(() {
              if (index == _currentIndex) {
                _notShownFeatures = slide.notShownFeatures;
              }
            });
          }
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

  Future<void> _registerFonts(PptxSlide slide, PptxReadSession session) async {
    final families = slide.elements
        .expand((element) => element.paragraphs)
        .expand((paragraph) => paragraph.runs)
        .map((run) => run.fontFamily)
        .whereType<String>()
        .where((family) {
          final separator = family.indexOf('::');
          return separator > 0 &&
              session.deckInfo.embeddedFontFamilies.contains(
                family.substring(separator + 2),
              );
        })
        .toSet();
    for (final family in families) {
      if (!mounted || !_isVisible || !identical(session, _session)) return;
      final separator = family.indexOf('::');
      if (separator <= 0) continue;
      final sourceFamily = family.substring(separator + 2);
      await _PptxEmbeddedFontRegistry.load(
        family,
        () => session.readFont(sourceFamily),
      );
      if (mounted && _isVisible && identical(session, _session)) {
        setState(() {});
      }
    }
  }

  void _handlePageChanged(int index) {
    setState(() {
      _imageBytes.clear();
      _currentIndex = index;
      _notShownFeatures = const [];
      _loadSlide(index);
      _loadSlide(index + 1);
      _slides[index]?.then((slide) {
        if (mounted && _isVisible && index == _currentIndex) {
          setState(() => _notShownFeatures = slide.notShownFeatures);
        }
      });
      _evictDistantSlides();
    });
    unawaited(_saveProgress(index));
  }

  Future<void> _showGoToSlideDialog(int slideCount) async {
    final pageNumber = await showDialog<int>(
      context: context,
      builder: (dialogContext) => _GoToSlideDialog(
        slideCount: slideCount,
        currentPage: _currentIndex + 1,
      ),
    );

    if (pageNumber == null || !mounted) return;
    final pageIndex = pageNumber - 1;
    if (_pageController.hasClients) {
      await _pageController.animateToPage(
        pageIndex,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );
    }
  }

  Future<void> _showSlideOverview() async {
    final deck = _deck;
    final session = _session;
    if (deck == null || session == null) return;
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => Dialog(
        child: SizedBox(
          width: 640,
          height: 520,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Slides',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 220,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1.22,
                  ),
                  itemCount: deck.slideCount,
                  itemBuilder: (context, index) => _PptxSlideThumbnail(
                    key: ValueKey(index),
                    index: index,
                    deck: deck,
                    session: session,
                    readImage: _readImage,
                    readSlide: () => session.readSlide(index),
                    onTap: () => Navigator.pop(context, index),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted || !_pageController.hasClients) return;
    _pageController.jumpToPage(selected);
  }

  Future<Uint8List> _readImage(String path) {
    final session = _session;
    if (session == null) {
      return Future.error(StateError('The PPTX presentation is closed'));
    }
    final cached = _imageBytes.remove(path);
    if (cached != null) {
      _imageBytes[path] = cached;
      return cached;
    }
    final future = session.readImage(path);
    _imageBytes[path] = future;
    while (_imageBytes.length > 6) {
      _imageBytes.remove(_imageBytes.keys.first);
    }
    return future;
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
                        showZoomControls:
                            index == _currentIndex && !widget.isChromeHidden,
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
                  child: Tooltip(
                    message: 'Go to slide',
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => _showGoToSlideDialog(deck.slideCount),
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
      notShownFeatures: _notShownFeatures,
      actions: [
        IconButton(
          tooltip: 'Slide overview',
          onPressed: _showSlideOverview,
          icon: const Icon(Icons.grid_view),
        ),
      ],
      child: child,
    );
  }
}

class _PptxSlideThumbnail extends StatefulWidget {
  const _PptxSlideThumbnail({
    super.key,
    required this.index,
    required this.deck,
    required this.session,
    required this.readImage,
    required this.readSlide,
    required this.onTap,
  });

  final int index;
  final PptxDeckInfo deck;
  final PptxReadSession session;
  final Future<Uint8List> Function(String path) readImage;
  final Future<PptxSlide> Function() readSlide;
  final VoidCallback onTap;

  @override
  State<_PptxSlideThumbnail> createState() => _PptxSlideThumbnailState();
}

class _PptxSlideThumbnailState extends State<_PptxSlideThumbnail> {
  late final Future<PptxSlide> _slide = widget.readSlide();

  Widget _preview(PptxSlide slide) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = math.min(
        constraints.maxWidth / widget.deck.width,
        constraints.maxHeight / widget.deck.height,
      );
      final slideWidth = widget.deck.width * scale;
      final slideHeight = widget.deck.height * scale;
      final background = slide.backgroundColor == null
          ? Colors.white
          : _officeColor(slide.backgroundColor!);
      final layers = <Widget>[
        Positioned.fill(
          child: CustomPaint(
            painter: _PptxSlidePainter(
              elements: const [],
              deck: widget.deck,
              background: background,
              drawBackground: true,
              backgroundGradientColors: slide.backgroundGradientColors,
              backgroundGradientStops: slide.backgroundGradientStops,
              backgroundGradientAngle: slide.backgroundGradientAngle,
            ),
          ),
        ),
      ];
      if (slide.backgroundImagePath != null) {
        layers.add(
          Positioned.fill(
            child: _PptxImage(
              session: widget.session,
              readImage: widget.readImage,
              path: slide.backgroundImagePath!,
              width: slideWidth.round(),
              height: slideHeight.round(),
            ),
          ),
        );
      }
      final shapeBatch = <PptxElement>[];
      void flushShapes() {
        if (shapeBatch.isEmpty) return;
        layers.add(
          Positioned.fill(
            child: CustomPaint(
              painter: _PptxSlidePainter(
                elements: List.unmodifiable(shapeBatch),
                deck: widget.deck,
                background: background,
              ),
            ),
          ),
        );
        shapeBatch.clear();
      }

      for (final element in slide.elements) {
        if (element.type == 'chart' && element.chartData != null) {
          flushShapes();
          layers.add(
            Positioned(
              left: element.x * scale,
              top: element.y * scale,
              width: element.width * scale,
              height: element.height * scale,
              child: OfficeChartView(
                chart: OfficeChartData.fromMap(element.chartData!),
              ),
            ),
          );
          continue;
        }
        if (element.type != 'image' || element.imagePath == null) {
          shapeBatch.add(element);
          continue;
        }
        flushShapes();
        layers.add(
          Positioned(
            left: element.x * scale,
            top: element.y * scale,
            width: element.width * scale,
            height: element.height * scale,
            child: Transform.rotate(
              angle: element.rotationDegrees * math.pi / 180,
              child: Transform.scale(
                scaleX: element.flipHorizontal ? -1 : 1,
                scaleY: element.flipVertical ? -1 : 1,
                child: _PptxImage(
                  session: widget.session,
                  readImage: widget.readImage,
                  path: element.imagePath!,
                  width: (element.width * scale).round(),
                  height: (element.height * scale).round(),
                  cropLeft: element.imageCropLeft,
                  cropTop: element.imageCropTop,
                  cropRight: element.imageCropRight,
                  cropBottom: element.imageCropBottom,
                ),
              ),
            ),
          ),
        );
      }
      flushShapes();
      return Center(
        child: SizedBox(
          width: slideWidth,
          height: slideHeight,
          child: Stack(fit: StackFit.expand, children: layers),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<PptxSlide>(
    future: _slide,
    builder: (context, snapshot) {
      final slide = snapshot.data;
      return Semantics(
        button: true,
        label: 'Go to slide ${widget.index + 1}',
        child: Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            child: Column(
              children: [
                Expanded(
                  child: ColoredBox(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: widget.deck.width / widget.deck.height,
                        child: slide == null
                            ? Center(
                                child: snapshot.hasError
                                    ? const Icon(Icons.broken_image_outlined)
                                    : const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                              )
                            : _preview(slide),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text('${widget.index + 1}'),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _GoToSlideDialog extends StatefulWidget {
  const _GoToSlideDialog({required this.slideCount, required this.currentPage});

  final int slideCount;
  final int currentPage;

  @override
  State<_GoToSlideDialog> createState() => _GoToSlideDialogState();
}

class _GoToSlideDialogState extends State<_GoToSlideDialog> {
  late final TextEditingController _controller;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${widget.currentPage}');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final page = int.tryParse(_controller.text);
    if (page == null || page < 1 || page > widget.slideCount) {
      setState(
        () => _errorMessage =
            'Enter a slide number from 1 to ${widget.slideCount}.',
      );
      return;
    }
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(page);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Go to slide'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.go,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: 'Slide number',
        helperText: _errorMessage == null
            ? 'Enter a number from 1 to ${widget.slideCount}'
            : null,
        errorText: _errorMessage,
      ),
      onChanged: (_) {
        if (_errorMessage != null) {
          setState(() => _errorMessage = null);
        }
      },
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () {
          FocusScope.of(context).unfocus();
          Navigator.of(context).pop();
        },
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Go')),
    ],
  );
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
    required this.showZoomControls,
    required this.transformation,
    required this.onZoomChanged,
  });

  final PptxSlide slide;
  final PptxDeckInfo deck;
  final PptxReadSession session;
  final Future<Uint8List> Function(String path) readImage;
  final bool active;
  final bool showZoomControls;
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
      final background = slide.backgroundColor == null
          ? Colors.white
          : _officeColor(slide.backgroundColor!);
      final layers = <Widget>[
        Positioned.fill(
          child: CustomPaint(
            painter: _PptxSlidePainter(
              elements: const [],
              deck: deck,
              background: background,
              drawBackground: true,
              backgroundGradientColors: slide.backgroundGradientColors,
              backgroundGradientStops: slide.backgroundGradientStops,
              backgroundGradientAngle: slide.backgroundGradientAngle,
            ),
          ),
        ),
      ];
      if (active && slide.backgroundImagePath != null) {
        layers.add(
          Positioned.fill(
            child: _PptxImage(
              session: session,
              readImage: readImage,
              path: slide.backgroundImagePath!,
              width: slideWidth.round(),
              height: slideHeight.round(),
            ),
          ),
        );
      }
      final shapeBatch = <PptxElement>[];

      void flushShapeBatch() {
        if (shapeBatch.isEmpty) return;
        layers.add(
          Positioned.fill(
            child: CustomPaint(
              painter: _PptxSlidePainter(
                elements: List.unmodifiable(shapeBatch),
                deck: deck,
                background: background,
              ),
            ),
          ),
        );
        shapeBatch.clear();
      }

      for (final element in slide.elements) {
        if (element.type == 'chart' && element.chartData != null) {
          flushShapeBatch();
          layers.add(
            Positioned(
              left: element.x * slideWidth / deck.width,
              top: element.y * slideHeight / deck.height,
              width: element.width * slideWidth / deck.width,
              height: element.height * slideHeight / deck.height,
              child: OfficeChartView(
                chart: OfficeChartData.fromMap(element.chartData!),
              ),
            ),
          );
          continue;
        }
        if (element.type != 'image' || element.imagePath == null) {
          shapeBatch.add(element);
          continue;
        }
        flushShapeBatch();
        if (!active) continue;
        layers.add(
          Positioned(
            left: element.x * slideWidth / deck.width,
            top: element.y * slideHeight / deck.height,
            width: element.width * slideWidth / deck.width,
            height: element.height * slideHeight / deck.height,
            child: Transform.rotate(
              angle: element.rotationDegrees * math.pi / 180,
              child: Transform.scale(
                scaleX: element.flipHorizontal ? -1 : 1,
                scaleY: element.flipVertical ? -1 : 1,
                child: element.customPaths.any((path) => path.fill)
                    ? ClipPath(
                        clipper: _PptxElementClipper(element.customPaths),
                        child: _PptxImage(
                          session: session,
                          readImage: readImage,
                          path: element.imagePath!,
                          width: (element.width * slideWidth).round(),
                          height: (element.height * slideHeight).round(),
                          cropLeft: element.imageCropLeft,
                          cropTop: element.imageCropTop,
                          cropRight: element.imageCropRight,
                          cropBottom: element.imageCropBottom,
                        ),
                      )
                    : _PptxImage(
                        session: session,
                        readImage: readImage,
                        path: element.imagePath!,
                        width: (element.width * slideWidth).round(),
                        height: (element.height * slideHeight).round(),
                        cropLeft: element.imageCropLeft,
                        cropTop: element.imageCropTop,
                        cropRight: element.imageCropRight,
                        cropBottom: element.imageCropBottom,
                      ),
              ),
            ),
          ),
        );
      }
      flushShapeBatch();
      void zoomBy(double factor) {
        final currentScale = transformation.value.getMaxScaleOnAxis();
        final nextScale = (currentScale * factor).clamp(1.0, 4.0);
        if ((nextScale - currentScale).abs() < 0.001) return;
        if (nextScale <= 1.001) {
          transformation.value = Matrix4.identity();
        } else {
          final ratio = nextScale / currentScale;
          final focalX = width / 2;
          final focalY = height / 2;
          final matrix = transformation.value.clone();
          matrix
            ..setEntry(0, 3, focalX - (focalX - matrix.entry(0, 3)) * ratio)
            ..setEntry(1, 3, focalY - (focalY - matrix.entry(1, 3)) * ratio)
            ..setEntry(0, 0, nextScale)
            ..setEntry(1, 1, nextScale);
          transformation.value = matrix;
        }
        onZoomChanged(nextScale > 1.01);
      }

      return Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              transformationController: transformation,
              minScale: 1,
              maxScale: 4,
              scaleEnabled: true,
              panEnabled: transformation.value.getMaxScaleOnAxis() > 1.01,
              onInteractionUpdate: (_) => onZoomChanged(
                transformation.value.getMaxScaleOnAxis() > 1.01,
              ),
              onInteractionEnd: (_) => onZoomChanged(
                transformation.value.getMaxScaleOnAxis() > 1.01,
              ),
              child: Center(
                child: SizedBox(
                  width: slideWidth,
                  height: slideHeight,
                  child: Stack(fit: StackFit.expand, children: layers),
                ),
              ),
            ),
          ),
          if (showZoomControls)
            Positioned(
              right: 12,
              bottom: 80,
              child: Material(
                color: Theme.of(
                  context,
                ).colorScheme.surface.withValues(alpha: 0.92),
                elevation: 3,
                borderRadius: BorderRadius.circular(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Zoom in',
                      onPressed: () => zoomBy(1.25),
                      icon: const Icon(Icons.add),
                    ),
                    IconButton(
                      tooltip: 'Zoom out',
                      onPressed: () => zoomBy(0.8),
                      icon: const Icon(Icons.remove),
                    ),
                    IconButton(
                      tooltip: 'Reset zoom',
                      onPressed: () =>
                          zoomBy(1 / transformation.value.getMaxScaleOnAxis()),
                      icon: const Icon(Icons.fit_screen),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}

class _PptxElementClipper extends CustomClipper<Path> {
  const _PptxElementClipper(this.paths);

  final List<PptxCustomPath> paths;

  @override
  Path getClip(Size size) {
    final combined = Path();
    for (final customPath in paths.where((path) => path.fill)) {
      final path = Path();
      Offset point(List<double> coordinates) =>
          Offset(coordinates[0] * size.width, coordinates[1] * size.height);

      for (final command in customPath.commands) {
        switch (command.type) {
          case 'moveTo':
            if (command.points.isNotEmpty) {
              final position = point(command.points.first);
              path.moveTo(position.dx, position.dy);
            }
          case 'lnTo':
            if (command.points.isNotEmpty) {
              final position = point(command.points.first);
              path.lineTo(position.dx, position.dy);
            }
          case 'cubicBezTo':
            if (command.points.length >= 3) {
              final control1 = point(command.points[0]);
              final control2 = point(command.points[1]);
              final end = point(command.points[2]);
              path.cubicTo(
                control1.dx,
                control1.dy,
                control2.dx,
                control2.dy,
                end.dx,
                end.dy,
              );
            }
          case 'quadBezTo':
            if (command.points.length >= 2) {
              final control = point(command.points[0]);
              final end = point(command.points[1]);
              path.quadraticBezierTo(control.dx, control.dy, end.dx, end.dy);
            }
          case 'close':
            path.close();
        }
      }
      combined.addPath(path, Offset.zero);
    }
    return combined;
  }

  @override
  bool shouldReclip(covariant _PptxElementClipper oldClipper) =>
      oldClipper.paths != paths;
}

class _PptxImage extends StatefulWidget {
  const _PptxImage({
    required this.session,
    required this.readImage,
    required this.path,
    required this.width,
    required this.height,
    this.cropLeft = 0,
    this.cropTop = 0,
    this.cropRight = 0,
    this.cropBottom = 0,
  });

  final PptxReadSession session;
  final Future<Uint8List> Function(String path) readImage;
  final String path;
  final int width;
  final int height;
  final double cropLeft;
  final double cropTop;
  final double cropRight;
  final double cropBottom;

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
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                snapshot.hasError
                    ? Icons.broken_image_outlined
                    : Icons.image_outlined,
              ),
              if (snapshot.hasError)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text(
                    'Image format not supported',
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
        );
      }
      _bytes = bytes;
      final pixelRatio = MediaQuery.devicePixelRatioOf(context);
      return LayoutBuilder(
        builder: (context, constraints) {
          final left = widget.cropLeft.clamp(0.0, 0.9);
          final top = widget.cropTop.clamp(0.0, 0.9);
          final right = widget.cropRight.clamp(0.0, 0.9 - left);
          final bottom = widget.cropBottom.clamp(0.0, 0.9 - top);
          final widthFraction = (1 - left - right).clamp(0.1, 1.0);
          final heightFraction = (1 - top - bottom).clamp(0.1, 1.0);
          final width = constraints.maxWidth / widthFraction;
          final height = constraints.maxHeight / heightFraction;
          return ClipRect(
            child: Stack(
              children: [
                Positioned(
                  left: -left * width,
                  top: -top * height,
                  width: width,
                  height: height,
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.fill,
                    cacheWidth: (width * pixelRatio).round().clamp(1, 1024),
                    cacheHeight: (height * pixelRatio).round().clamp(1, 1024),
                    errorBuilder: (context, error, stackTrace) =>
                        const Icon(Icons.broken_image_outlined),
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

class _PptxEmbeddedFontRegistry {
  static const _maximumFonts = 16;
  static const _maximumBytes = 4 * 1024 * 1024;
  static final Map<String, Future<bool>> _loads = {};
  static final Set<String> _loadedFamilies = {};
  static int _retainedBytes = 0;

  static Future<bool> load(
    String family,
    Future<Uint8List> Function() readFont,
  ) {
    final existing = _loads[family];
    if (existing != null) return existing;
    if (_loads.length >= _maximumFonts || _retainedBytes >= _maximumBytes) {
      debugPrint('Embedded presentation font limit reached; using fallback.');
      return _loads.putIfAbsent(family, () => Future.value(false));
    }

    final loading = _load(family, readFont);
    _loads[family] = loading;
    return loading;
  }

  static String? resolveFamily(String? family) {
    if (family == null || !family.contains('::')) return family;
    if (_loadedFamilies.contains(family)) return family;
    final sourceFamily = family
        .substring(family.indexOf('::') + 2)
        .toLowerCase();
    if (sourceFamily.contains('apple') || sourceFamily.contains('script')) {
      return 'cursive';
    }
    if (sourceFamily.contains('elite') || sourceFamily.contains('typewriter')) {
      return 'monospace';
    }
    return null;
  }

  static Future<bool> _load(
    String family,
    Future<Uint8List> Function() readFont,
  ) async {
    try {
      final bytes = await readFont();
      if (_retainedBytes + bytes.length > _maximumBytes) {
        debugPrint(
          'Embedded presentation font byte limit reached; using fallback.',
        );
        return false;
      }
      _retainedBytes += bytes.length;
      final loader = FontLoader(family)
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      _loadedFamilies.add(family);
      return true;
    } catch (error) {
      debugPrint('Could not load embedded presentation font "$family": $error');
      return false;
    }
  }
}

class _PptxSlidePainter extends CustomPainter {
  const _PptxSlidePainter({
    required this.elements,
    required this.deck,
    required this.background,
    this.drawBackground = false,
    this.backgroundGradientColors = const [],
    this.backgroundGradientStops = const [],
    this.backgroundGradientAngle = 0,
  });

  final List<PptxElement> elements;
  final PptxDeckInfo deck;
  final Color background;
  final bool drawBackground;
  final List<int> backgroundGradientColors;
  final List<double> backgroundGradientStops;
  final double backgroundGradientAngle;

  @override
  void paint(Canvas canvas, Size size) {
    if (drawBackground) {
      final rect = Offset.zero & size;
      final paint = Paint()..color = background;
      if (backgroundGradientColors.length >= 2) {
        final angle = backgroundGradientAngle * math.pi / 180;
        final halfDiagonal =
            math.sqrt(size.width * size.width + size.height * size.height) / 2;
        final direction = Offset(math.cos(angle), math.sin(angle));
        paint.shader = ui.Gradient.linear(
          rect.center - direction * halfDiagonal,
          rect.center + direction * halfDiagonal,
          backgroundGradientColors.map(_officeColor).toList(growable: false),
          _gradientStops(
            backgroundGradientStops,
            backgroundGradientColors.length,
          ),
        );
      }
      canvas.drawRect(rect, paint);
    }
    final scale = size.width / deck.width;
    for (final element in elements) {
      final rect = Rect.fromLTWH(
        element.x * scale,
        element.y * scale,
        element.width * scale,
        element.height * scale,
      );
      canvas.save();
      if (element.flipHorizontal || element.flipVertical) {
        canvas
          ..translate(rect.center.dx, rect.center.dy)
          ..scale(
            element.flipHorizontal ? -1.0 : 1.0,
            element.flipVertical ? -1.0 : 1.0,
          )
          ..translate(-rect.center.dx, -rect.center.dy);
      }
      if (element.rotationDegrees != 0) {
        canvas
          ..translate(rect.center.dx, rect.center.dy)
          ..rotate(element.rotationDegrees * math.pi / 180)
          ..translate(-rect.center.dx, -rect.center.dy);
      }
      if (element.type == 'table') {
        _drawTable(canvas, rect, element.tableRows, scale);
      } else if (element.type == 'shape') {
        _drawShape(canvas, rect, element, scale);
      }
      if (element.paragraphs.isNotEmpty) {
        _drawText(
          canvas,
          rect,
          element.paragraphs,
          scale,
          element.fillColor,
          element,
        );
      }
      canvas.restore();
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
              fontSize: 12 * _pptPointsToLogicalPixels * scale,
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
    if (element.shape == 'custom') {
      _drawCustomShape(canvas, rect, element, scale);
      return;
    }
    if (element.shape == 'line') {
      canvas.drawLine(
        rect.topLeft,
        rect.bottomRight,
        Paint()
          ..color = _officeColor(element.lineColor ?? 0x333333)
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
        : _presetGeometry(element.shape, rect);
    if (fill != null) {
      canvas.drawPath(shape, _fillPaint(rect, element));
    }
    if (border != null) {
      canvas.drawPath(
        shape,
        Paint()
          ..color = _officeColor(border)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (element.lineWidth * scale).clamp(0.5, 24),
      );
    }
  }

  Paint _fillPaint(Rect rect, PptxElement element) {
    final paint = Paint()
      ..color = _officeColor(element.fillColor ?? 0xFFFFFFFF);
    if (element.fillGradientColors.length >= 2) {
      final angle = element.fillGradientAngle * math.pi / 180;
      final halfDiagonal =
          math.sqrt(rect.width * rect.width + rect.height * rect.height) / 2;
      final direction = Offset(math.cos(angle), math.sin(angle));
      paint.shader = ui.Gradient.linear(
        rect.center - direction * halfDiagonal,
        rect.center + direction * halfDiagonal,
        element.fillGradientColors.map(_officeColor).toList(growable: false),
        _gradientStops(
          element.fillGradientStops,
          element.fillGradientColors.length,
        ),
      );
    }
    return paint;
  }

  Path _presetGeometry(String shape, Rect rect) {
    Offset p(double x, double y) =>
        Offset(rect.left + rect.width * x, rect.top + rect.height * y);
    Path polygon(List<Offset> points) => Path()
      ..moveTo(points.first.dx, points.first.dy)
      ..addPolygon(points.skip(1).toList(growable: false), true);

    switch (shape) {
      case 'triangle':
        return polygon([p(.5, 0), p(1, 1), p(0, 1)]);
      case 'rtTriangle':
        return polygon([p(0, 0), p(0, 1), p(1, 1)]);
      case 'diamond':
        return polygon([p(.5, 0), p(1, .5), p(.5, 1), p(0, .5)]);
      case 'parallelogram':
        return polygon([p(.25, 0), p(1, 0), p(.75, 1), p(0, 1)]);
      case 'trapezoid':
        return polygon([p(.2, 0), p(.8, 0), p(1, 1), p(0, 1)]);
      case 'pentagon':
        return _regularPolygon(rect, 5);
      case 'hexagon':
        return _regularPolygon(rect, 6);
      case 'octagon':
        return _regularPolygon(rect, 8);
      case 'leftArrow':
        return polygon([
          p(0, .5),
          p(.35, 0),
          p(.35, .28),
          p(1, .28),
          p(1, .72),
          p(.35, .72),
          p(.35, 1),
        ]);
      case 'rightArrow':
        return polygon([
          p(0, .28),
          p(.65, .28),
          p(.65, 0),
          p(1, .5),
          p(.65, 1),
          p(.65, .72),
          p(0, .72),
        ]);
      case 'upArrow':
        return polygon([
          p(.5, 0),
          p(1, .35),
          p(.72, .35),
          p(.72, 1),
          p(.28, 1),
          p(.28, .35),
          p(0, .35),
        ]);
      case 'downArrow':
        return polygon([
          p(.28, 0),
          p(.72, 0),
          p(.72, .65),
          p(1, .65),
          p(.5, 1),
          p(0, .65),
          p(.28, .65),
        ]);
      case 'leftRightArrow':
        return polygon([
          p(0, .5),
          p(.25, 0),
          p(.25, .28),
          p(.75, .28),
          p(.75, 0),
          p(1, .5),
          p(.75, 1),
          p(.75, .72),
          p(.25, .72),
          p(.25, 1),
        ]);
      case 'upDownArrow':
        return polygon([
          p(.5, 0),
          p(1, .25),
          p(.72, .25),
          p(.72, .75),
          p(1, .75),
          p(.5, 1),
          p(0, .75),
          p(.28, .75),
          p(.28, .25),
          p(0, .25),
        ]);
      case 'chevron':
        return polygon([
          p(0, 0),
          p(.58, 0),
          p(1, .5),
          p(.58, 1),
          p(0, 1),
          p(.42, .5),
        ]);
      case 'star4':
      case 'star5':
      case 'star6':
      case 'star8':
        return _starGeometry(rect, int.parse(shape.substring(4)));
      case 'wedgeRectCallout':
      case 'wedgeRoundRectCallout':
      case 'wedgeEllipseCallout':
      case 'cloudCallout':
        return Path()
          ..addRect(
            Rect.fromLTWH(rect.left, rect.top, rect.width, rect.height * .78),
          )
          ..moveTo(rect.left + rect.width * .28, rect.top + rect.height * .78)
          ..lineTo(rect.left + rect.width * .14, rect.bottom)
          ..lineTo(rect.left + rect.width * .46, rect.top + rect.height * .78)
          ..close();
      case 'heart':
        final heart = Path()
          ..moveTo(rect.center.dx, rect.bottom)
          ..cubicTo(
            rect.left - rect.width * .05,
            rect.height * .62,
            rect.left,
            rect.top + rect.height * .25,
            rect.left + rect.width * .25,
            rect.top + rect.height * .18,
          )
          ..cubicTo(
            rect.center.dx - rect.width * .05,
            rect.top + rect.height * .1,
            rect.center.dx,
            rect.top + rect.height * .32,
            rect.center.dx,
            rect.top + rect.height * .32,
          )
          ..cubicTo(
            rect.center.dx,
            rect.top + rect.height * .32,
            rect.center.dx + rect.width * .05,
            rect.top + rect.height * .1,
            rect.right - rect.width * .25,
            rect.top + rect.height * .18,
          )
          ..cubicTo(
            rect.right,
            rect.top + rect.height * .25,
            rect.right + rect.width * .05,
            rect.height * .62,
            rect.center.dx,
            rect.bottom,
          )
          ..close();
        return heart;
      case 'ellipse':
        return Path()..addOval(rect);
      case 'roundRect':
        return Path()..addRRect(
          RRect.fromRectAndRadius(
            rect,
            Radius.circular(rect.shortestSide * .1),
          ),
        );
      default:
        return Path()..addRect(rect);
    }
  }

  Path _regularPolygon(Rect rect, int sides) =>
      _starGeometry(rect, sides, innerFactor: 1);

  Path _starGeometry(Rect rect, int points, {double innerFactor = .46}) {
    final path = Path();
    final radius = math.min(rect.width, rect.height) * .5;
    final vertexCount = innerFactor == 1 ? points : points * 2;
    for (var index = 0; index < vertexCount; index++) {
      final angle =
          -math.pi / 2 +
          index * (innerFactor == 1 ? 2 * math.pi / points : math.pi / points);
      final currentRadius = innerFactor == 1 || index.isEven
          ? radius
          : radius * innerFactor;
      final point = Offset(
        rect.center.dx + math.cos(angle) * currentRadius,
        rect.center.dy + math.sin(angle) * currentRadius,
      );
      if (index == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    return path..close();
  }

  void _drawCustomShape(
    Canvas canvas,
    Rect rect,
    PptxElement element,
    double scale,
  ) {
    for (final customPath in element.customPaths) {
      final path = Path();
      Offset point(List<double> coordinates) => Offset(
        rect.left + coordinates[0] * rect.width,
        rect.top + coordinates[1] * rect.height,
      );

      for (final command in customPath.commands) {
        switch (command.type) {
          case 'moveTo':
            if (command.points.isNotEmpty) {
              final position = point(command.points.first);
              path.moveTo(position.dx, position.dy);
            }
          case 'lnTo':
            if (command.points.isNotEmpty) {
              final position = point(command.points.first);
              path.lineTo(position.dx, position.dy);
            }
          case 'cubicBezTo':
            if (command.points.length >= 3) {
              final control1 = point(command.points[0]);
              final control2 = point(command.points[1]);
              final end = point(command.points[2]);
              path.cubicTo(
                control1.dx,
                control1.dy,
                control2.dx,
                control2.dy,
                end.dx,
                end.dy,
              );
            }
          case 'quadBezTo':
            if (command.points.length >= 2) {
              final control = point(command.points[0]);
              final end = point(command.points[1]);
              path.quadraticBezierTo(control.dx, control.dy, end.dx, end.dy);
            }
          case 'close':
            path.close();
        }
      }

      if (customPath.fill && element.fillColor != null) {
        canvas.drawPath(path, _fillPaint(rect, element));
      }
      if (customPath.stroke && element.lineColor != null) {
        canvas.drawPath(
          path,
          Paint()
            ..color = _officeColor(element.lineColor!)
            ..style = PaintingStyle.stroke
            ..strokeWidth = (element.lineWidth * scale).clamp(0.5, 24),
        );
      }
    }
  }

  void _drawText(
    Canvas canvas,
    Rect rect,
    List<PptxTextParagraph> paragraphs,
    double scale,
    int? fillColor,
    PptxElement element,
  ) {
    final left = (rect.left + element.textInsetLeft * scale).clamp(
      rect.left,
      rect.right,
    );
    final insetTop = (rect.top + element.textInsetTop * scale).clamp(
      rect.top,
      rect.bottom,
    );
    final right = (rect.right - element.textInsetRight * scale).clamp(
      left,
      rect.right,
    );
    final bottom = (rect.bottom - element.textInsetBottom * scale).clamp(
      insetTop,
      rect.bottom,
    );
    final textRect = Rect.fromLTRB(left, insetTop, right, bottom);
    final textSurface = fillColor == null
        ? background
        : _officeColor(fillColor);

    Color textColor(int? color) {
      if (color == null) return const Color(0xff222222);
      final resolved = _officeColor(color);
      if ((color & 0xffffff) == (textSurface.toARGB32() & 0xffffff)) {
        return textSurface.computeLuminance() > 0.5
            ? const Color(0xff222222)
            : const Color(0xffeeeeee);
      }
      return resolved;
    }

    List<TextPainter> layoutParagraphs(double factor) {
      return paragraphs
          .map((paragraph) {
            final spans = <InlineSpan>[];
            if (paragraph.bullet != null) {
              spans.add(
                TextSpan(
                  text: '${paragraph.bullet} ',
                  style: TextStyle(
                    fontSize:
                        (paragraph.fontSize ?? 18) *
                        _pptPointsToLogicalPixels *
                        scale *
                        element.textScale *
                        factor,
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
                    decoration: TextDecoration.combine([
                      if (run.underline) TextDecoration.underline,
                      if (run.strikethrough) TextDecoration.lineThrough,
                    ]),
                    fontFamily: _PptxEmbeddedFontRegistry.resolveFamily(
                      run.fontFamily,
                    ),
                    fontSize:
                        (run.fontSize ?? paragraph.fontSize ?? 18) *
                        _pptPointsToLogicalPixels *
                        scale *
                        element.textScale *
                        factor,
                    color: textColor(run.color ?? paragraph.color),
                  ),
                ),
              );
            }
            final painter =
                TextPainter(
                  text: TextSpan(
                    style: TextStyle(height: paragraph.lineSpacing),
                    children: spans,
                  ),
                  textDirection: TextDirection.ltr,
                  textAlign: _textAlignment(paragraph.alignment),
                  textScaler: TextScaler.noScaling,
                )..layout(
                  minWidth: (textRect.width - paragraph.indent).clamp(
                    1,
                    double.infinity,
                  ),
                  maxWidth: (textRect.width - paragraph.indent).clamp(
                    1,
                    double.infinity,
                  ),
                );
            return painter;
          })
          .toList(growable: false);
    }

    var painters = layoutParagraphs(1);
    var totalHeight = 0.0;
    for (var index = 0; index < painters.length; index++) {
      final paragraph = paragraphs[index];
      totalHeight +=
          painters[index].height +
          (paragraph.spaceBefore ?? 0) * _pptPointsToLogicalPixels * scale +
          (paragraph.spaceAfter ?? 0) * _pptPointsToLogicalPixels * scale;
    }
    if (totalHeight > textRect.height && totalHeight > 0) {
      for (final painter in painters) {
        painter.dispose();
      }
      painters = layoutParagraphs(
        (textRect.height / totalHeight).clamp(0.35, 1.0),
      );
      totalHeight = 0;
      for (var index = 0; index < painters.length; index++) {
        final paragraph = paragraphs[index];
        totalHeight +=
            painters[index].height +
            (paragraph.spaceBefore ?? 0) * _pptPointsToLogicalPixels * scale +
            (paragraph.spaceAfter ?? 0) * _pptPointsToLogicalPixels * scale;
      }
    }
    canvas.save();
    canvas.clipRect(textRect);
    var top = switch (element.textVerticalAlignment) {
      'center' => textRect.top + (textRect.height - totalHeight) / 2,
      'bottom' => textRect.bottom - totalHeight,
      _ => textRect.top,
    };
    for (var index = 0; index < painters.length; index++) {
      final paragraph = paragraphs[index];
      final painter = painters[index];
      top += (paragraph.spaceBefore ?? 0) * _pptPointsToLogicalPixels * scale;
      painter.paint(
        canvas,
        Offset(
          textRect.left + paragraph.indent * _pptPointsToLogicalPixels * scale,
          top,
        ),
      );
      top +=
          painter.height +
          (paragraph.spaceAfter ?? 0) * _pptPointsToLogicalPixels * scale;
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
      oldDelegate.elements != elements ||
      oldDelegate.background != background ||
      oldDelegate.drawBackground != drawBackground;
}
