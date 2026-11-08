import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/docx_file_provider.dart';
import '../../domain/repositories/docx_file_repository.dart';
import '../common/built_in_viewer_shell.dart';
import '../common/marquee_text.dart';
import '../common/open_docx_file.dart';

class DocxViewerTab extends ConsumerStatefulWidget {
  const DocxViewerTab({
    super.key,
    required this.path,
    required this.isChromeHidden,
    required this.onChromeHiddenChanged,
    required this.onZoomChanged,
  });

  final String path;
  final bool isChromeHidden;
  final ValueChanged<bool> onChromeHiddenChanged;
  final ValueChanged<bool> onZoomChanged;

  @override
  ConsumerState<DocxViewerTab> createState() => _DocxViewerTabState();
}

class _DocxViewerTabState extends ConsumerState<DocxViewerTab>
    with AutomaticKeepAliveClientMixin {
  DocxReadSession? _session;
  final ValueNotifier<Map<int, double>> _tableScrollOffsets = ValueNotifier({});
  final List<DocxBlock> _blocks = [];
  Object? _loadError;
  int _generation = 0;
  double _zoom = 1;
  double _zoomAtGestureStart = 1;
  double _pinchStartDistance = 0;
  final Map<int, Offset> _activePointers = {};
  bool _isVisible = false;
  bool _isLoading = false;
  bool _isComplete = false;
  bool _isTruncated = false;
  bool _usePageLayout = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _setVisible(MarqueeVisibility.isVisibleOf(context));
  }

  @override
  void didUpdateWidget(covariant DocxViewerTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _closeDocument();
      if (_isVisible) unawaited(_openDocument());
    }
  }

  @override
  void dispose() {
    _isVisible = false;
    _closeDocument(notify: false);
    _tableScrollOffsets.dispose();
    super.dispose();
  }

  void _setVisible(bool visible) {
    if (_isVisible == visible) return;
    _isVisible = visible;
    if (visible) {
      if (_session == null && !_isLoading) unawaited(_openDocument());
    } else {
      _closeDocument();
    }
  }

  void _closeDocument({bool notify = true}) {
    ++_generation;
    final session = _session;
    _session = null;
    _blocks.clear();
    _loadError = null;
    _isLoading = false;
    _isComplete = false;
    _isTruncated = false;
    _tableScrollOffsets.value = const {};
    if (session != null) unawaited(session.close());
    if (notify && mounted) setState(() {});
  }

  void _scrollTable(int tableId, double delta, double maxOffset) {
    final offsets = _tableScrollOffsets.value;
    final offset = (offsets[tableId] ?? 0) + delta;
    final next = offset.clamp(0, maxOffset).toDouble();
    if (next == (offsets[tableId] ?? 0)) return;
    _tableScrollOffsets.value = {...offsets, tableId: next};
  }

  void _setZoom(double zoom) {
    final next = zoom.clamp(_usePageLayout ? 0.6 : 0.7, 2.5).toDouble();
    if ((next - _zoom).abs() < 0.005) return;
    setState(() => _zoom = next);
    widget.onZoomChanged(next > 1.001);
  }

  void _onPointerDown(PointerDownEvent event) {
    _activePointers[event.pointer] = event.position;
    if (_activePointers.length == 2) {
      _zoomAtGestureStart = _zoom;
      _pinchStartDistance = _pointerDistance;
    } else if (_activePointers.length > 2) {
      _pinchStartDistance = 0;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_activePointers.containsKey(event.pointer)) return;
    _activePointers[event.pointer] = event.position;
    if (_activePointers.length != 2 || _pinchStartDistance <= 0) return;
    _setZoom(_zoomAtGestureStart * _pointerDistance / _pinchStartDistance);
  }

  void _onPointerEnd(PointerEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.length == 2) {
      _zoomAtGestureStart = _zoom;
      _pinchStartDistance = _pointerDistance;
    } else {
      _pinchStartDistance = 0;
    }
  }

  double get _pointerDistance {
    final points = _activePointers.values.take(2).toList(growable: false);
    if (points.length < 2) return 0;
    return (points[0] - points[1]).distance;
  }

  Future<void> _openDocument() async {
    if (!_isVisible || _isLoading) return;
    final generation = ++_generation;
    setState(() {
      _isLoading = true;
      _loadError = null;
      _blocks.clear();
      _isComplete = false;
      _isTruncated = false;
    });
    DocxReadSession? session;
    try {
      session = await ref.read(docxFileRepositoryProvider).open(widget.path);
      if (!mounted || !_isVisible || generation != _generation) {
        await session.close();
        return;
      }
      _session = session;
      final progress = await session.readNextBlocks();
      if (!mounted || !_isVisible || generation != _generation) return;
      setState(() {
        _applyProgress(progress);
        _isLoading = false;
      });
      unawaited(_parseRemaining(session, generation));
    } catch (error) {
      if (session != null) await session.close();
      if (identical(_session, session)) _session = null;
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadError = error;
        _isLoading = false;
      });
    }
  }

  Future<void> _parseRemaining(DocxReadSession session, int generation) async {
    try {
      while (_isVisible &&
          mounted &&
          generation == _generation &&
          !_isComplete &&
          !_isTruncated) {
        final progress = await session.readNextBlocks();
        if (!mounted || !_isVisible || generation != _generation) return;
        setState(() => _applyProgress(progress));
      }
    } catch (error) {
      if (!mounted || !_isVisible || generation != _generation) return;
      setState(() {
        _loadError = error;
        _isComplete = true;
      });
    }
  }

  void _applyProgress(DocxReadProgress progress) {
    if (progress.startIndex != _blocks.length) {
      throw StateError(
        'The DOCX reader returned out-of-order document blocks.',
      );
    }
    _blocks.addAll(progress.blocks);
    _isComplete = progress.isComplete;
    _isTruncated = progress.isTruncated;
  }

  Widget _buildBlock(
    BuildContext context,
    DocxBlock block,
    DocxReadSession? session, {
    bool pageLayout = false,
  }) {
    if (block.type == 'paragraph') {
      final zoom = MediaQuery.textScalerOf(context).scale(1);
      final headingLevel = block.headingLevel ?? _headingLevel(block.styleName);
      final baseStyle = headingLevel == null
          ? Theme.of(context).textTheme.bodyMedium
          : switch (headingLevel) {
              1 => Theme.of(context).textTheme.headlineSmall,
              2 => Theme.of(context).textTheme.titleLarge,
              3 => Theme.of(context).textTheme.titleMedium,
              _ => Theme.of(context).textTheme.titleSmall,
            };
      final paragraphStyle = baseStyle?.copyWith(
        fontWeight: block.styleBold ? FontWeight.bold : null,
        fontStyle: block.styleItalic ? FontStyle.italic : null,
        height: block.paragraphLineHeight,
        decoration: TextDecoration.combine([
          if (block.styleUnderline) TextDecoration.underline,
          if (block.styleStrikethrough) TextDecoration.lineThrough,
        ]),
        fontSize: block.styleFontSize == null
            ? null
            : block.styleFontSize! * 4 / 3,
        color: block.styleColor == null
            ? null
            : Color(0xff000000 | block.styleColor!),
        backgroundColor: block.styleHighlight == null
            ? null
            : Color(0xff000000 | block.styleHighlight!),
      );
      final direction = block.isRightToLeft
          ? TextDirection.rtl
          : Directionality.of(context);
      final inheritedStyle = paragraphStyle ?? const TextStyle();
      final spans = <InlineSpan>[];
      for (final run in block.runs) {
        final style = inheritedStyle.copyWith(
          fontWeight: run.bold ? FontWeight.bold : inheritedStyle.fontWeight,
          fontStyle: run.italic ? FontStyle.italic : inheritedStyle.fontStyle,
          decoration: run.underline || run.strikethrough
              ? TextDecoration.combine([
                  if (run.underline) TextDecoration.underline,
                  if (run.strikethrough) TextDecoration.lineThrough,
                ])
              : inheritedStyle.decoration,
          fontSize: run.fontSize == null
              ? inheritedStyle.fontSize
              : run.fontSize! * 4 / 3,
          color: run.color == null
              ? inheritedStyle.color
              : Color(0xff000000 | run.color!),
          backgroundColor: run.highlight == null
              ? inheritedStyle.backgroundColor
              : Color(0xff000000 | run.highlight!),
        );
        if (run.imagePath != null && session != null) {
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: _DocxImage(
                session: session,
                path: run.imagePath!,
                width: run.imageWidth,
                height: run.imageHeight,
                inline: true,
              ),
            ),
          );
        } else if (run.hyperlink != null) {
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => unawaited(
                  _confirmAndOpenDocxLink(context, session, run.hyperlink),
                ),
                child: Text(run.text, style: style),
              ),
            ),
          );
        } else {
          spans.add(TextSpan(text: run.text, style: style));
        }
      }
      final textAlign = switch (block.alignment) {
        'center' => TextAlign.center,
        'right' || 'end' => TextAlign.right,
        'both' || 'distribute' => TextAlign.justify,
        _ => TextAlign.left,
      };
      final text = Text.rich(
        TextSpan(style: inheritedStyle, children: spans),
        textDirection: direction,
        textAlign: textAlign,
      );
      final hangingIndent = (block.paragraphHangingIndent ?? 18.0) * zoom;
      var markerColor = paragraphStyle?.color;
      for (final run in block.runs) {
        if (run.color != null) {
          markerColor = Color(0xff000000 | run.color!);
          break;
        }
      }
      final indentLeft = block.listMarker == null
          ? (block.paragraphIndentLeft ?? 0)
          : ((block.paragraphIndentLeft ??
                        (block.listLevel * 18.0 +
                            (block.paragraphHangingIndent ?? 18.0))) -
                    (block.paragraphHangingIndent ?? 18.0))
                .clamp(0, 1000)
                .toDouble();
      final indentRight = block.paragraphIndentRight ?? 0;
      final paragraphContent = block.listMarker == null
          ? text
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              textDirection: direction,
              children: [
                SizedBox(
                  width: hangingIndent,
                  child: Text(
                    block.listMarker!,
                    style: paragraphStyle?.copyWith(color: markerColor),
                    textAlign: TextAlign.start,
                  ),
                ),
                Expanded(child: text),
              ],
            );
      final borderColor = block.paragraphBottomBorderColor;
      final paragraph = Container(
        decoration: borderColor == null
            ? null
            : BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: Color(0xff000000 | borderColor),
                    width: (block.paragraphBottomBorderWidth ?? 0.5) * zoom,
                  ),
                ),
              ),
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            ((pageLayout ? 3 : 12) + indentLeft) * zoom,
            (block.paragraphSpaceBefore ??
                    (pageLayout
                        ? (headingLevel == null ? 1 : 6)
                        : (headingLevel == null ? 3 : 12))) *
                zoom,
            ((pageLayout ? 3 : 12) + indentRight) * zoom,
            (block.paragraphSpaceAfter ??
                    (pageLayout
                        ? (headingLevel == null ? 1 : 4)
                        : (headingLevel == null ? 5 : 7))) *
                zoom,
          ),
          child: paragraphContent,
        ),
      );
      final background = block.floatingBackground;
      if (pageLayout || background == null) return paragraph;
      final maxRight = _blocks.fold<double>(0, (maximum, item) {
        final right = (item.floatingLeft ?? 0) + (item.floatingWidth ?? 0);
        return right > maximum ? right : maximum;
      });
      return LayoutBuilder(
        builder: (context, constraints) {
          final pageWidth = maxRight > 0 ? maxRight : constraints.maxWidth;
          final availableWidth = constraints.maxWidth;
          final left = ((block.floatingLeft ?? 0) / pageWidth * availableWidth)
              .clamp(0, availableWidth * 0.6)
              .toDouble();
          final width =
              ((block.floatingWidth ?? pageWidth) / pageWidth * availableWidth)
                  .clamp(0, availableWidth - left)
                  .toDouble();
          return Padding(
            padding: EdgeInsets.only(left: left),
            child: Container(
              width: width,
              color: Color(0xff000000 | background),
              child: paragraph,
            ),
          );
        },
      );
    }
    if (block.type == 'tableRow') {
      return _DocxTableRow(
        block: block,
        session: session,
        scrollOffsets: _tableScrollOffsets,
        onScroll: _scrollTable,
        onOpenLink: (context, hyperlink) =>
            _confirmAndOpenDocxLink(context, session, hyperlink),
      );
    }
    return _DocxBlockView(block: block, session: session);
  }

  Widget _buildPageLayout(BuildContext context, DocxReadSession? session) {
    final positionedContentBlocks = _blocks
        .where(
          (block) =>
              block.floatingId != null && block.type != 'floatingBackground',
        )
        .toList(growable: false);
    final backgroundBlocks = _blocks
        .where((block) => block.type == 'floatingBackground')
        .toList(growable: false);
    final remainingBlocks = _blocks
        .where(
          (block) =>
              block.floatingId == null && block.type != 'floatingBackground',
        )
        .toList(growable: false);
    final groups = <int, List<DocxBlock>>{};
    for (final block in positionedContentBlocks) {
      groups.putIfAbsent(block.floatingId!, () => []).add(block);
    }
    final positionedBlocks = [...positionedContentBlocks, ...backgroundBlocks];
    final leftEdge = positionedBlocks.fold<double>(0, (minimum, block) {
      return math.min(
        minimum,
        _boundedFloatingValue(block.floatingLeft, -2400, 2400),
      );
    });
    final topEdge = positionedBlocks.fold<double>(0, (minimum, block) {
      return math.min(
        minimum,
        _boundedFloatingValue(block.floatingTop, -4000, 4000),
      );
    });
    final rightEdge = positionedBlocks.fold<double>(leftEdge, (maximum, block) {
      final right =
          _boundedFloatingValue(block.floatingLeft, -2400, 2400) +
          _boundedFloatingValue(block.floatingWidth, 0, 2400);
      return math.max(maximum, right);
    });
    final bottomEdge = positionedBlocks.fold<double>(topEdge, (maximum, block) {
      final bottom =
          _boundedFloatingValue(block.floatingTop, -4000, 4000) +
          _boundedFloatingValue(block.floatingHeight, 0, 4000);
      return math.max(maximum, bottom);
    });
    final pageWidth = (rightEdge - leftEdge).clamp(1.0, 2400.0).toDouble();
    final pageHeight = (bottomEdge - topEdge).clamp(1.0, 4000.0).toDouble();

    return LayoutBuilder(
      builder: (context, constraints) {
        final hasPositionedBlocks = positionedBlocks.isNotEmpty;
        final layoutWidth = pageWidth;
        final layoutHeight = hasPositionedBlocks ? pageHeight : 0.0;
        final fitScale = math
            .min(constraints.maxWidth / layoutWidth, 1.0)
            .toDouble();
        final scale = fitScale * _zoom;
        final renderedWidth = layoutWidth * scale;
        final renderedHeight = layoutHeight * scale;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: math.max(constraints.maxWidth, renderedWidth).toDouble(),
            child: ColoredBox(
              color: Colors.white,
              child: ListView.builder(
                key: ValueKey(_generation),
                addAutomaticKeepAlives: false,
                itemCount:
                    remainingBlocks.length + (hasPositionedBlocks ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index != 0 || !hasPositionedBlocks) {
                    final blockIndex = hasPositionedBlocks ? index - 1 : index;
                    return MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: TextScaler.linear(_zoom)),
                      child: _buildBlock(
                        context,
                        remainingBlocks[blockIndex],
                        session,
                        pageLayout: true,
                      ),
                    );
                  }
                  return Center(
                    child: SizedBox(
                      width: renderedWidth,
                      height: renderedHeight,
                      child: OverflowBox(
                        alignment: Alignment.topLeft,
                        minWidth: 0,
                        minHeight: 0,
                        maxWidth: double.infinity,
                        maxHeight: double.infinity,
                        child: Transform.scale(
                          scale: scale,
                          alignment: Alignment.topLeft,
                          child: SizedBox(
                            width: layoutWidth,
                            height: layoutHeight,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                border: Border.all(
                                  color: Theme.of(context).dividerColor,
                                  width: 0.5,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.12),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: ClipRect(
                                child: Stack(
                                  clipBehavior: Clip.hardEdge,
                                  children: [
                                    for (final background in backgroundBlocks)
                                      if (background.floatingBackground !=
                                              null ||
                                          background.floatingOutlineColor !=
                                              null)
                                        Positioned(
                                          left:
                                              _boundedFloatingValue(
                                                background.floatingLeft,
                                                -2400,
                                                2400,
                                              ) -
                                              leftEdge,
                                          top:
                                              _boundedFloatingValue(
                                                background.floatingTop,
                                                -4000,
                                                4000,
                                              ) -
                                              topEdge,
                                          width: _boundedFloatingValue(
                                            background.floatingWidth,
                                            0,
                                            2400,
                                          ),
                                          height: _boundedFloatingValue(
                                            background.floatingHeight,
                                            0,
                                            4000,
                                          ),
                                          child: _buildFloatingShape(
                                            background.floatingShape,
                                            background.floatingBackground ==
                                                    null
                                                ? null
                                                : Color(
                                                    0xff000000 |
                                                        background
                                                            .floatingBackground!,
                                                  ),
                                            outlineColor:
                                                background
                                                        .floatingOutlineColor ==
                                                    null
                                                ? null
                                                : Color(
                                                    0xff000000 |
                                                        background
                                                            .floatingOutlineColor!,
                                                  ),
                                            outlineWidth:
                                                background.floatingOutlineWidth,
                                            rotationDegrees:
                                                background.floatingRotation,
                                          ),
                                        ),
                                    for (final entry in groups.entries)
                                      if (entry.value.isNotEmpty)
                                        Positioned(
                                          left:
                                              _boundedFloatingValue(
                                                entry.value.first.floatingLeft,
                                                -2400,
                                                2400,
                                              ) -
                                              leftEdge,
                                          top:
                                              _boundedFloatingValue(
                                                entry.value.first.floatingTop,
                                                -4000,
                                                4000,
                                              ) -
                                              topEdge,
                                          width: _boundedFloatingValue(
                                            entry.value.first.floatingWidth,
                                            0,
                                            2400,
                                          ),
                                          height: _boundedFloatingValue(
                                            entry.value.first.floatingHeight,
                                            0,
                                            4000,
                                          ),
                                          child: ClipRect(
                                            child: Container(
                                              decoration: _floatingShapeDecoration(
                                                entry.value.first.floatingShape,
                                                entry
                                                            .value
                                                            .first
                                                            .floatingBackground ==
                                                        null
                                                    ? null
                                                    : Color(
                                                        0xff000000 |
                                                            entry
                                                                .value
                                                                .first
                                                                .floatingBackground!,
                                                      ),
                                              ),
                                              foregroundDecoration:
                                                  _floatingShapeDecoration(
                                                    entry
                                                        .value
                                                        .first
                                                        .floatingShape,
                                                    null,
                                                    outlineColor:
                                                        entry
                                                                .value
                                                                .first
                                                                .floatingOutlineColor ==
                                                            null
                                                        ? null
                                                        : Color(
                                                            0xff000000 |
                                                                entry
                                                                    .value
                                                                    .first
                                                                    .floatingOutlineColor!,
                                                          ),
                                                    outlineWidth: entry
                                                        .value
                                                        .first
                                                        .floatingOutlineWidth,
                                                  ),
                                              child: ListView.builder(
                                                padding: EdgeInsets.zero,
                                                physics:
                                                    const NeverScrollableScrollPhysics(),
                                                primary: false,
                                                addAutomaticKeepAlives: false,
                                                itemCount: entry.value.length,
                                                itemBuilder: (context, index) =>
                                                    _buildBlock(
                                                      context,
                                                      entry.value[index],
                                                      session,
                                                      pageLayout: true,
                                                    ),
                                              ),
                                            ),
                                          ),
                                        ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final session = _session;
    final media = MediaQuery.of(context);
    final scaledMedia = media.copyWith(
      textScaler: TextScaler.linear(_usePageLayout ? 1 : _zoom),
    );
    return BuiltInViewerShell(
      name: widget.path.split(RegExp(r'[/\\]')).last,
      isChromeHidden: widget.isChromeHidden,
      onChromeHiddenChanged: widget.onChromeHiddenChanged,
      onOpenWithAnother: () => openDocxFile(
        context,
        ref,
        path: widget.path,
        name: widget.path.split(RegExp(r'[/\\]')).last,
        excludeBuiltIn: true,
        useSavedDefaultApps: false,
        allowSaveDefault: false,
      ),
      actions: [
        if (_usePageLayout) ...[
          IconButton(
            tooltip: 'Zoom out',
            onPressed: () => _setZoom(_zoom - 0.1),
            icon: const Icon(Icons.zoom_out),
          ),
          IconButton(
            tooltip: 'Reset zoom to 100%',
            onPressed: _zoom == 1 ? null : () => _setZoom(1),
            icon: Text('${(_zoom * 100).round()}%'),
          ),
          IconButton(
            tooltip: 'Zoom in',
            onPressed: () => _setZoom(_zoom + 0.1),
            icon: const Icon(Icons.zoom_in),
          ),
        ],
        IconButton(
          tooltip: _usePageLayout
              ? 'Switch to mobile layout'
              : 'Switch to page layout',
          onPressed: () {
            setState(() {
              _usePageLayout = !_usePageLayout;
              _zoom = 1;
            });
            widget.onZoomChanged(false);
          },
          icon: Icon(
            _usePageLayout ? Icons.phone_android : Icons.description_outlined,
          ),
        ),
      ],
      child: _loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not open this DOCX document: $_loadError',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : _blocks.isEmpty && _isLoading
          ? const Center(child: Text('Loading document...'))
          : SafeArea(
              top: false,
              left: false,
              right: false,
              child: Column(
                children: [
                  Expanded(
                    child: AnimatedPadding(
                      padding: EdgeInsets.only(
                        top: widget.isChromeHidden ? 0 : 44,
                      ),
                      duration: const Duration(milliseconds: 180),
                      child: Listener(
                        onPointerDown: _onPointerDown,
                        onPointerMove: _onPointerMove,
                        onPointerUp: _onPointerEnd,
                        onPointerCancel: _onPointerEnd,
                        child: MediaQuery(
                          data: scaledMedia,
                          child: _usePageLayout
                              ? _buildPageLayout(context, session)
                              : ListView.builder(
                                  key: ValueKey(_generation),
                                  addAutomaticKeepAlives: false,
                                  itemCount: _blocks.length,
                                  itemBuilder: (context, index) {
                                    final block = _blocks[index];
                                    if (block.type == 'paragraph') {
                                      final headingLevel =
                                          block.headingLevel ??
                                          _headingLevel(block.styleName);
                                      final baseStyle = headingLevel == null
                                          ? Theme.of(
                                              context,
                                            ).textTheme.bodyMedium
                                          : switch (headingLevel) {
                                              1 => Theme.of(
                                                context,
                                              ).textTheme.headlineSmall,
                                              2 => Theme.of(
                                                context,
                                              ).textTheme.titleLarge,
                                              3 => Theme.of(
                                                context,
                                              ).textTheme.titleMedium,
                                              _ => Theme.of(
                                                context,
                                              ).textTheme.titleSmall,
                                            };
                                      final paragraphStyle = baseStyle
                                          ?.copyWith(
                                            fontWeight: block.styleBold
                                                ? FontWeight.bold
                                                : null,
                                            fontStyle: block.styleItalic
                                                ? FontStyle.italic
                                                : null,
                                            decoration: TextDecoration.combine([
                                              if (block.styleUnderline)
                                                TextDecoration.underline,
                                              if (block.styleStrikethrough)
                                                TextDecoration.lineThrough,
                                            ]),
                                            fontSize:
                                                block.styleFontSize == null
                                                ? null
                                                : block.styleFontSize! * 4 / 3,
                                            color: block.styleColor == null
                                                ? null
                                                : Color(
                                                    0xff000000 |
                                                        block.styleColor!,
                                                  ),
                                            backgroundColor:
                                                block.styleHighlight == null
                                                ? null
                                                : Color(
                                                    0xff000000 |
                                                        block.styleHighlight!,
                                                  ),
                                          );
                                      final direction = block.isRightToLeft
                                          ? TextDirection.rtl
                                          : Directionality.of(context);
                                      final inheritedStyle =
                                          paragraphStyle ?? const TextStyle();
                                      final paragraph = Padding(
                                        padding: EdgeInsetsDirectional.fromSTEB(
                                          12 +
                                              (block.listMarker == null
                                                  ? 0
                                                  : block.listLevel * 18),
                                          headingLevel == null ? 3 : 12,
                                          12,
                                          headingLevel == null ? 5 : 7,
                                        ),
                                        child: Wrap(
                                          textDirection: direction,
                                          alignment: switch (block.alignment) {
                                            'center' => WrapAlignment.center,
                                            'right' => WrapAlignment.end,
                                            'both' || 'distribute' =>
                                              WrapAlignment.spaceBetween,
                                            _ => WrapAlignment.start,
                                          },
                                          children: [
                                            if (block.listMarker != null)
                                              Text(
                                                '${block.listMarker} ',
                                                textDirection: direction,
                                                style: paragraphStyle,
                                              ),
                                            for (final run in block.runs)
                                              if (run.imagePath != null &&
                                                  session != null)
                                                _DocxImage(
                                                  session: session,
                                                  path: run.imagePath!,
                                                  width: run.imageWidth,
                                                  height: run.imageHeight,
                                                  inline: true,
                                                )
                                              else
                                                Builder(
                                                  builder: (context) {
                                                    final style = inheritedStyle.copyWith(
                                                      fontWeight: run.bold
                                                          ? FontWeight.bold
                                                          : inheritedStyle
                                                                .fontWeight,
                                                      fontStyle: run.italic
                                                          ? FontStyle.italic
                                                          : inheritedStyle
                                                                .fontStyle,
                                                      decoration:
                                                          run.underline ||
                                                              run.strikethrough
                                                          ? TextDecoration.combine([
                                                              if (run.underline)
                                                                TextDecoration
                                                                    .underline,
                                                              if (run
                                                                  .strikethrough)
                                                                TextDecoration
                                                                    .lineThrough,
                                                            ])
                                                          : inheritedStyle
                                                                .decoration,
                                                      fontSize:
                                                          run.fontSize == null
                                                          ? inheritedStyle
                                                                .fontSize
                                                          : run.fontSize! *
                                                                4 /
                                                                3,
                                                      color: run.color == null
                                                          ? inheritedStyle.color
                                                          : Color(
                                                              0xff000000 |
                                                                  run.color!,
                                                            ),
                                                      backgroundColor:
                                                          run.highlight == null
                                                          ? inheritedStyle
                                                                .backgroundColor
                                                          : Color(
                                                              0xff000000 |
                                                                  run.highlight!,
                                                            ),
                                                    );
                                                    final text = Text(
                                                      run.text,
                                                      textDirection: direction,
                                                      style: style,
                                                    );
                                                    final hyperlink =
                                                        run.hyperlink;
                                                    return hyperlink == null
                                                        ? text
                                                        : GestureDetector(
                                                            behavior:
                                                                HitTestBehavior
                                                                    .opaque,
                                                            onTap: () => unawaited(
                                                              _confirmAndOpenDocxLink(
                                                                context,
                                                                session,
                                                                hyperlink,
                                                              ),
                                                            ),
                                                            child: text,
                                                          );
                                                  },
                                                ),
                                          ],
                                        ),
                                      );
                                      final background =
                                          block.floatingBackground;
                                      if (background == null) return paragraph;
                                      final maxRight = _blocks.fold<double>(0, (
                                        maximum,
                                        item,
                                      ) {
                                        final right =
                                            (item.floatingLeft ?? 0) +
                                            (item.floatingWidth ?? 0);
                                        return right > maximum
                                            ? right
                                            : maximum;
                                      });
                                      return LayoutBuilder(
                                        builder: (context, constraints) {
                                          final pageWidth = maxRight > 0
                                              ? maxRight
                                              : constraints.maxWidth;
                                          final availableWidth =
                                              constraints.maxWidth;
                                          final left =
                                              ((block.floatingLeft ?? 0) /
                                                      pageWidth *
                                                      availableWidth)
                                                  .clamp(
                                                    0,
                                                    availableWidth * 0.6,
                                                  )
                                                  .toDouble();
                                          final width =
                                              ((block.floatingWidth ??
                                                          pageWidth) /
                                                      pageWidth *
                                                      availableWidth)
                                                  .clamp(
                                                    0,
                                                    availableWidth - left,
                                                  )
                                                  .toDouble();
                                          return Padding(
                                            padding: EdgeInsets.only(
                                              left: left,
                                            ),
                                            child: Container(
                                              width: width,
                                              color: Color(
                                                0xff000000 | background,
                                              ),
                                              child: paragraph,
                                            ),
                                          );
                                        },
                                      );
                                    }
                                    if (block.type == 'tableRow') {
                                      return _DocxTableRow(
                                        block: block,
                                        session: session,
                                        scrollOffsets: _tableScrollOffsets,
                                        onScroll: _scrollTable,
                                        onOpenLink: (context, hyperlink) =>
                                            _confirmAndOpenDocxLink(
                                              context,
                                              session,
                                              hyperlink,
                                            ),
                                      );
                                    }
                                    return _DocxBlockView(
                                      block: block,
                                      session: session,
                                    );
                                  },
                                ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

Future<void> _confirmAndOpenDocxLink(
  BuildContext context,
  DocxReadSession? session,
  String? hyperlink,
) async {
  final uri = Uri.tryParse(hyperlink ?? '');
  if (session == null ||
      uri == null ||
      !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return;
  }
  final shouldOpen = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Open this link?'),
      content: Text(uri.toString()),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Open'),
        ),
      ],
    ),
  );
  if (shouldOpen != true) return;
  try {
    await session.openExternalLink(uri.toString());
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not open link: $error')));
    }
  }
}

class _DocxBlockView extends StatelessWidget {
  const _DocxBlockView({required this.block, required this.session});

  final DocxBlock block;
  final DocxReadSession? session;

  @override
  Widget build(BuildContext context) {
    final imageSession = session;
    if (block.type == 'pageBreak') {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        child: Divider(color: Theme.of(context).dividerColor, height: 1),
      );
    }
    if (block.type == 'image' &&
        block.imagePath != null &&
        imageSession != null) {
      Widget image = _DocxImage(
        session: imageSession,
        path: block.imagePath!,
        width: block.imageWidth,
        height: block.imageHeight,
      );
      if (block.floatingShape == 'ellipse') {
        image = ClipOval(child: image);
      } else if (block.floatingShape == 'roundRect') {
        image = ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: image,
        );
      }
      return image;
    }
    if (block.type == 'placeholder') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 18),
        child: Center(
          child: Text(
            block.placeholder ?? 'Object not shown',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

const _docxDefaultTableColumnWidth = 144.0;
const _docxMinTableColumnWidth = 64.0;
const _docxMaxTableColumnWidth = 480.0;
const _docxMaxTableColumns = 256;

List<List<DocxTextRun>> _splitDocxTableCellParagraphs(List<DocxTextRun> runs) {
  final paragraphs = <List<DocxTextRun>>[];
  var current = <DocxTextRun>[];

  void finishParagraph() {
    if (current.isEmpty) return;
    paragraphs.add(current);
    current = [];
  }

  for (final run in runs) {
    if (run.imagePath != null) {
      current.add(run);
      continue;
    }
    final lines = run.text.split('\n');
    for (var index = 0; index < lines.length; index++) {
      final text = lines[index];
      if (text.isNotEmpty) {
        current.add(
          DocxTextRun(
            text: text,
            bold: run.bold,
            italic: run.italic,
            underline: run.underline,
            strikethrough: run.strikethrough,
            fontSize: run.fontSize,
            color: run.color,
            highlight: run.highlight,
            hyperlink: run.hyperlink,
          ),
        );
      }
      if (index < lines.length - 1) finishParagraph();
    }
  }
  finishParagraph();
  return paragraphs;
}

class _DocxTableRow extends StatelessWidget {
  const _DocxTableRow({
    required this.block,
    required this.session,
    required this.scrollOffsets,
    required this.onScroll,
    required this.onOpenLink,
  });

  final DocxBlock block;
  final DocxReadSession? session;
  final ValueNotifier<Map<int, double>> scrollOffsets;
  final void Function(int tableId, double delta, double maxOffset) onScroll;
  final Future<void> Function(BuildContext, String?) onOpenLink;

  @override
  Widget build(BuildContext context) {
    final zoom = MediaQuery.textScalerOf(context).scale(1);
    final cells = block.tableRows.isEmpty
        ? const <List<DocxTextRun>>[]
        : block.tableRows.first;
    if (cells.isEmpty) return const SizedBox.shrink();
    var requiredColumns = 0;
    for (var index = 0; index < cells.length; index++) {
      requiredColumns += index < block.tableCellSpans.length
          ? block.tableCellSpans[index]
          : 1;
    }
    requiredColumns = requiredColumns
        .clamp(block.tableColumnWidths.length, _docxMaxTableColumns)
        .toInt();
    final columnWidths = List<double>.generate(requiredColumns, (index) {
      final width = index < block.tableColumnWidths.length
          ? block.tableColumnWidths[index]
          : _docxDefaultTableColumnWidth;
      return (width.isFinite && width > 0
                  ? width
                  : _docxDefaultTableColumnWidth)
              .clamp(_docxMinTableColumnWidth, _docxMaxTableColumnWidth)
              .toDouble() *
          zoom;
    }, growable: false);
    final tableWidth = columnWidths.fold<double>(
      0,
      (total, width) => total + width,
    );
    if (tableWidth <= 0) return const SizedBox.shrink();

    final borderColor = Theme.of(context).dividerColor;
    final rowChildren = <Widget>[];
    var gridColumn = 0;
    for (var index = 0; index < cells.length; index++) {
      if (gridColumn >= requiredColumns) break;
      final span =
          (index < block.tableCellSpans.length
                  ? block.tableCellSpans[index]
                  : 1)
              .clamp(1, requiredColumns - gridColumn)
              .toInt();
      final cellWidth = columnWidths
          .skip(gridColumn)
          .take(span)
          .fold<double>(0, (total, width) => total + width);
      rowChildren.add(
        SizedBox(
          width: cellWidth,
          child: Container(
            padding: EdgeInsets.all(8 * zoom),
            decoration: BoxDecoration(
              border: Border.all(color: borderColor, width: 0.5 * zoom),
            ),
            constraints: BoxConstraints(minHeight: 40 * zoom),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final paragraph in _splitDocxTableCellParagraphs(
                  cells[index],
                ))
                  Wrap(
                    textDirection: Directionality.of(context),
                    children: [
                      for (final run in paragraph)
                        if (run.imagePath != null && session != null)
                          _DocxImage(
                            session: session!,
                            path: run.imagePath!,
                            width: run.imageWidth,
                            height: run.imageHeight,
                            inline: true,
                          )
                        else
                          Builder(
                            builder: (context) {
                              final baseStyle = Theme.of(
                                context,
                              ).textTheme.bodyMedium;
                              final text = Text(
                                run.text,
                                style: baseStyle?.copyWith(
                                  fontWeight: run.bold ? FontWeight.bold : null,
                                  fontStyle: run.italic
                                      ? FontStyle.italic
                                      : null,
                                  decoration: run.underline || run.strikethrough
                                      ? TextDecoration.combine([
                                          if (run.underline)
                                            TextDecoration.underline,
                                          if (run.strikethrough)
                                            TextDecoration.lineThrough,
                                        ])
                                      : null,
                                  fontSize: run.fontSize == null
                                      ? baseStyle.fontSize
                                      : run.fontSize! * 4 / 3,
                                  color: run.color == null
                                      ? baseStyle.color
                                      : Color(0xff000000 | run.color!),
                                  backgroundColor: run.highlight == null
                                      ? baseStyle.backgroundColor
                                      : Color(0xff000000 | run.highlight!),
                                ),
                              );
                              return run.hyperlink == null
                                  ? text
                                  : GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () => unawaited(
                                        onOpenLink(context, run.hyperlink),
                                      ),
                                      child: text,
                                    );
                            },
                          ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      );
      gridColumn += span;
    }
    while (gridColumn < requiredColumns) {
      rowChildren.add(
        SizedBox(
          width: columnWidths[gridColumn],
          child: Container(
            padding: EdgeInsets.all(8 * zoom),
            decoration: BoxDecoration(
              border: Border.all(color: borderColor, width: 0.5 * zoom),
            ),
          ),
        ),
      );
      gridColumn++;
    }

    return Padding(
      padding: EdgeInsets.symmetric(vertical: zoom),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return _SyncedTableRowViewport(
            tableId: block.tableId ?? 0,
            tableWidth: tableWidth,
            viewportWidth: constraints.maxWidth,
            scrollOffsets: scrollOffsets,
            onScroll: onScroll,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: rowChildren,
            ),
          );
        },
      ),
    );
  }
}

class _SyncedTableRowViewport extends StatefulWidget {
  const _SyncedTableRowViewport({
    required this.tableId,
    required this.tableWidth,
    required this.viewportWidth,
    required this.scrollOffsets,
    required this.onScroll,
    required this.child,
  });

  final int tableId;
  final double tableWidth;
  final double viewportWidth;
  final ValueNotifier<Map<int, double>> scrollOffsets;
  final void Function(int tableId, double delta, double maxOffset) onScroll;
  final Widget child;

  @override
  State<_SyncedTableRowViewport> createState() =>
      _SyncedTableRowViewportState();
}

class _SyncedTableRowViewportState extends State<_SyncedTableRowViewport> {
  late final ScrollController _controller;
  var _synchronizing = false;
  var _lastOffset = 0.0;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController()..addListener(_handleScroll);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (_synchronizing || !_controller.hasClients) return;
    final position = _controller.position;
    final offset = position.pixels;
    final delta = offset - _lastOffset;
    _lastOffset = offset;
    if (delta.abs() < 0.01) return;
    widget.onScroll(widget.tableId, delta, position.maxScrollExtent);
  }

  void _syncOffset(double offset) {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final next = offset.clamp(0, position.maxScrollExtent).toDouble();
    if ((position.pixels - next).abs() < 0.5) return;
    _synchronizing = true;
    _controller.jumpTo(next);
    _lastOffset = next;
    _synchronizing = false;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ValueListenableBuilder<Map<int, double>>(
      valueListenable: widget.scrollOffsets,
      builder: (context, offsets, child) {
        final offset = offsets[widget.tableId] ?? 0;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _syncOffset(offset);
        });
        return SizedBox(
          width: constraints.maxWidth,
          child: ClipRect(
            child: SingleChildScrollView(
              controller: _controller,
              scrollDirection: Axis.horizontal,
              child: SizedBox(width: widget.tableWidth, child: child),
            ),
          ),
        );
      },
      child: widget.child,
    ),
  );
}

class _DocxImage extends StatefulWidget {
  const _DocxImage({
    required this.session,
    required this.path,
    required this.width,
    required this.height,
    this.inline = false,
  });

  final DocxReadSession session;
  final String path;
  final double? width;
  final double? height;
  final bool inline;

  @override
  State<_DocxImage> createState() => _DocxImageState();
}

class _DocxImageState extends State<_DocxImage> {
  late Future<Uint8List> _bytes;
  Uint8List? _loadedBytes;

  @override
  void initState() {
    super.initState();
    _bytes = widget.session.readImage(widget.path);
  }

  @override
  void didUpdateWidget(covariant _DocxImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        !identical(oldWidget.session, widget.session)) {
      _evictImage();
      _loadedBytes = null;
      _bytes = widget.session.readImage(widget.path);
    }
  }

  void _evictImage() {
    final bytes = _loadedBytes;
    if (bytes != null) {
      final provider = MemoryImage(bytes);
      unawaited(provider.evict());
    }
  }

  @override
  void dispose() {
    _evictImage();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: _bytes,
    builder: (context, snapshot) {
      final bytes = snapshot.data;
      if (bytes != null) _loadedBytes = bytes;
      if (bytes == null) {
        if (snapshot.hasError) {
          return const _DocxObjectPlaceholder('Image could not be displayed');
        }
        return widget.inline
            ? const SizedBox(
                width: 48,
                height: 48,
                child: Icon(Icons.image_outlined),
              )
            : const _DocxObjectPlaceholder('Loading image');
      }
      final pixelRatio = MediaQuery.devicePixelRatioOf(context);
      final viewportWidth = MediaQuery.sizeOf(context).width - 48;
      final zoom = MediaQuery.textScalerOf(context).scale(1);
      final width =
          (widget.width ?? viewportWidth).clamp(24, 800).toDouble() * zoom;
      final height = widget.height == null
          ? null
          : widget.height!.clamp(24, 900).toDouble() * zoom;
      return Padding(
        padding: widget.inline
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Image.memory(
            bytes,
            width: widget.inline
                ? width.clamp(24, 480 * zoom).toDouble()
                : width,
            height: height,
            fit: BoxFit.contain,
            cacheWidth: (width * pixelRatio).round().clamp(1, 2048).toInt(),
            cacheHeight: height == null
                ? null
                : (height * pixelRatio).round().clamp(1, 2048).toInt(),
            errorBuilder: (context, error, stackTrace) =>
                const _DocxObjectPlaceholder('Unsupported image'),
          ),
        ),
      );
    },
  );
}

class _DocxObjectPlaceholder extends StatelessWidget {
  const _DocxObjectPlaceholder(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Center(
      child: Text(label, style: Theme.of(context).textTheme.labelSmall),
    ),
  );
}

double _boundedFloatingValue(double? value, double minimum, double maximum) {
  if (value == null || !value.isFinite) return 0;
  return value.clamp(minimum, maximum).toDouble();
}

BoxDecoration _floatingShapeDecoration(
  String? shape,
  Color? color, {
  Color? outlineColor,
  double? outlineWidth,
}) => BoxDecoration(
  color: color,
  shape: shape == 'ellipse' ? BoxShape.circle : BoxShape.rectangle,
  borderRadius: shape == 'roundRect' ? BorderRadius.circular(16) : null,
  border: outlineColor == null
      ? null
      : Border.all(
          color: outlineColor,
          width: (outlineWidth ?? 0.5).clamp(0.1, 12).toDouble(),
        ),
);

Widget _buildFloatingShape(
  String? shape,
  Color? color, {
  Color? outlineColor,
  double? outlineWidth,
  double? rotationDegrees,
}) {
  final child = shape == 'line'
      ? CustomPaint(
          painter: _DocxFloatingLinePainter(
            outlineColor ?? color ?? const Color(0x00000000),
          ),
          child: const SizedBox.expand(),
        )
      : DecoratedBox(
          decoration: _floatingShapeDecoration(
            shape,
            color,
            outlineColor: outlineColor,
            outlineWidth: outlineWidth,
          ),
        );
  if (rotationDegrees == null || rotationDegrees == 0) return child;
  return Transform.rotate(angle: rotationDegrees * math.pi / 180, child: child);
}

class _DocxFloatingLinePainter extends CustomPainter {
  const _DocxFloatingLinePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    if (size.width >= size.height) {
      final y = size.height / 2;
      canvas.drawLine(
        Offset.zero.translate(0, y),
        Offset(size.width, y),
        paint,
      );
    } else {
      final x = size.width / 2;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DocxFloatingLinePainter oldDelegate) =>
      oldDelegate.color != color;
}

int? _headingLevel(String? styleName) {
  final match = RegExp(
    r'heading\s*([1-6])',
    caseSensitive: false,
  ).firstMatch(styleName ?? '');
  return int.tryParse(match?.group(1) ?? '');
}
