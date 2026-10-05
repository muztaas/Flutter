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
  final TextStyle? style;
  final TextAlign textAlign;
  final MarqueeStyle styleMode;
  final bool isActive;

  const MarqueeText(
    this.text, {
    super.key,
    this.style,
    this.textAlign = TextAlign.start,
    this.styleMode = MarqueeStyle.continuousLoop,
    this.isActive = true,
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
        oldWidget.style != widget.style ||
        oldWidget.styleMode != widget.styleMode ||
        oldWidget.isActive != widget.isActive) {
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
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: textStyle),
          maxLines: 1,
          textDirection: Directionality.of(context),
        )..layout(minWidth: 0, maxWidth: double.infinity);

        final shouldScroll = painter.width > constraints.maxWidth;
        if (_shouldScroll != shouldScroll) {
          _shouldScroll = shouldScroll;
          _resetAnimation();
        }
        if (!shouldScroll) {
          return Text(
            widget.text,
            style: textStyle,
            textAlign: widget.textAlign,
            maxLines: 1,
            overflow: TextOverflow.visible,
            softWrap: false,
          );
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
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final progress = _scrollProgress(duration);
                final offset = -cycleWidth * progress;
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
                          child: _buildText(painter.width, textStyle),
                        ),
                        Positioned(
                          left: offset + cycleWidth,
                          top: 0,
                          child: _buildText(painter.width, textStyle),
                        ),
                      ],
                    ),
                  ),
                );
              },
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

  Widget _buildText(double width, TextStyle? style) {
    return SizedBox(
      width: width,
      child: Text(
        widget.text,
        style: style,
        maxLines: 1,
        overflow: TextOverflow.visible,
        softWrap: false,
      ),
    );
  }
}
