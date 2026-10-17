import 'dart:math' as math;

import 'package:flutter/material.dart';

const Duration marqueePauseDuration = Duration(milliseconds: 1800);
const double marqueeOverflowToScrollDurationRatio = 1000 / (25 * 0.54);

/// Controls whether a marquee scrolls continuously or pauses at each cycle.
enum MarqueeStyle { continuousLoop, pauseAndLoop }

class MarqueeVisibility extends InheritedWidget {
  final bool isVisible;

  const MarqueeVisibility({
    super.key,
    required this.isVisible,
    required super.child,
  });

  static bool isVisibleOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<MarqueeVisibility>()
          ?.isVisible ??
      true;

  @override
  bool updateShouldNotify(MarqueeVisibility oldWidget) =>
      isVisible != oldWidget.isVisible;
}

class MarqueeText extends StatefulWidget {
  final String text;
  final InlineSpan? textSpan;
  final TextStyle? style;
  final TextAlign textAlign;
  final MarqueeStyle styleMode;
  final bool isActive;
  final bool isManuallyScrollable;

  const MarqueeText(
    this.text, {
    super.key,
    this.style,
    this.textAlign = TextAlign.start,
    this.styleMode = MarqueeStyle.continuousLoop,
    this.isActive = true,
    this.isManuallyScrollable = false,
    this.textSpan,
  });

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const double _gap = 32;

  late final AnimationController _controller;
  bool _appIsResumed = true;
  bool _pageIsVisible = true;
  bool _shouldScroll = false;
  bool _animationRequested = false;
  double _dragOffset = 0;
  Duration? _configuredDuration;

  bool get _canAnimate => widget.isActive && _appIsResumed && _pageIsVisible;

  @override
  void initState() {
    super.initState();
    _appIsResumed =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _controller = AnimationController(vsync: this);
  }

  @override
  void didUpdateWidget(covariant MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.textSpan?.toPlainText() != widget.textSpan?.toPlainText()) {
      _dragOffset = 0;
    }
    if (oldWidget.text != widget.text ||
        oldWidget.textSpan?.toPlainText() != widget.textSpan?.toPlainText() ||
        oldWidget.style != widget.style ||
        oldWidget.styleMode != widget.styleMode ||
        oldWidget.isActive != widget.isActive ||
        oldWidget.isManuallyScrollable != widget.isManuallyScrollable) {
      _resetAnimation();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isVisible = MarqueeVisibility.isVisibleOf(context);
    if (_pageIsVisible == isVisible) return;
    _pageIsVisible = isVisible;
    if (!isVisible) _resetAnimation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (_appIsResumed == resumed) return;
    _appIsResumed = resumed;
    if (!resumed) {
      _resetAnimation();
    } else {
      setState(() {});
    }
  }

  void _resetAnimation() {
    _animationRequested = false;
    _controller.stop();
    _controller.reset();
    _configuredDuration = null;
  }

  void _requestAnimation(Duration duration) {
    if (!_canAnimate || !_shouldScroll || _animationRequested) return;
    _animationRequested = true;
    _configuredDuration = duration;
    _controller.duration = duration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_canAnimate || !_shouldScroll) {
        _animationRequested = false;
        return;
      }
      _controller.repeat();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textStyle = widget.style ?? Theme.of(context).textTheme.titleSmall;

    return LayoutBuilder(
      builder: (context, constraints) {
        final textSpan =
            widget.textSpan ?? TextSpan(text: widget.text, style: textStyle);
        final painter = TextPainter(
          text: textSpan,
          maxLines: 1,
          textDirection: Directionality.of(context),
        )..layout(minWidth: 0, maxWidth: double.infinity);

        final shouldScroll = painter.width > constraints.maxWidth;
        if (_shouldScroll != shouldScroll) {
          _shouldScroll = shouldScroll;
          _resetAnimation();
        }
        if (!shouldScroll) {
          return _buildText(textSpan, painter.width, textStyle);
        }

        final cycleWidth = painter.width + _gap;
        final scrollDuration = Duration(
          milliseconds: (cycleWidth * marqueeOverflowToScrollDurationRatio)
              .round(),
        );
        final duration = widget.styleMode == MarqueeStyle.pauseAndLoop
            ? marqueePauseDuration + scrollDuration
            : scrollDuration;

        if (_configuredDuration != duration) {
          _resetAnimation();
        }
        if (_canAnimate) {
          _requestAnimation(duration);
        } else if (_animationRequested) {
          _resetAnimation();
        }

        return ClipRect(
          child: SizedBox(
            width: constraints.maxWidth,
            child: GestureDetector(
              onHorizontalDragUpdate: widget.isManuallyScrollable
                  ? (details) {
                      setState(() {
                        _dragOffset = _wrapOffset(
                          _dragOffset + details.delta.dx,
                          cycleWidth,
                        );
                      });
                    }
                  : null,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final progress = _scrollProgress(duration);
                  final offset = _wrapOffset(
                    -cycleWidth * progress + _dragOffset,
                    cycleWidth,
                  );
                  return SizedBox(
                    width: constraints.maxWidth,
                    height: painter.height,
                    child: ClipRect(
                      child: Stack(
                        clipBehavior: Clip.hardEdge,
                        children: [
                          Positioned(
                            left: offset,
                            top: 0,
                            child: _buildText(
                              textSpan,
                              painter.width,
                              textStyle,
                            ),
                          ),
                          Positioned(
                            left: offset + cycleWidth,
                            top: 0,
                            child: _buildText(
                              textSpan,
                              painter.width,
                              textStyle,
                            ),
                          ),
                        ],
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

  double _scrollProgress(Duration totalDuration) {
    if (widget.styleMode == MarqueeStyle.continuousLoop) {
      return _controller.value;
    }
    final pauseFraction =
        marqueePauseDuration.inMicroseconds / totalDuration.inMicroseconds;
    return math.max(
      0,
      math.min(1, (_controller.value - pauseFraction) / (1 - pauseFraction)),
    );
  }

  double _wrapOffset(double offset, double cycleWidth) {
    final wrapped = offset % cycleWidth;
    if (wrapped == 0) return -cycleWidth;
    return wrapped > 0 ? wrapped - cycleWidth : wrapped;
  }

  Widget _buildText(InlineSpan span, double width, TextStyle? style) {
    return SizedBox(
      width: width,
      child: Text.rich(
        span,
        style: style,
        textAlign: widget.textAlign,
        maxLines: 1,
        overflow: TextOverflow.visible,
        softWrap: false,
      ),
    );
  }
}
