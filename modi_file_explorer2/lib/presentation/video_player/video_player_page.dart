import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/video_providers.dart';
import '../../domain/entities/video_player_item.dart';
import '../../domain/entities/video_player_state.dart';
import '../../domain/repositories/video_player_repository.dart';
import '../common/marquee_text.dart';
import '../common/open_video_file.dart';

const Duration _controlsHideDelay = Duration(milliseconds: 1500);
const Duration _systemBarsHideDelay = Duration(seconds: 2);
const Duration _resumeMessageDuration = Duration(seconds: 4);
const List<double> _playbackSpeeds = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];

class VideoPlayerPage extends ConsumerStatefulWidget {
  const VideoPlayerPage({
    super.key,
    required this.sessionId,
    required this.items,
    required this.initialIndex,
    this.onPlaybackBegan,
    this.onResumePosition,
    this.onSaveResumePosition,
    this.onResetResumePosition,
  });

  final String sessionId;
  final List<VideoPlayerItem> items;
  final int initialIndex;
  final Future<void> Function(VideoPlayerItem item)? onPlaybackBegan;
  final Future<Duration> Function(VideoPlayerItem item)? onResumePosition;
  final Future<void> Function(VideoPlayerItem item, Duration position)?
  onSaveResumePosition;
  final Future<void> Function(VideoPlayerItem item)? onResetResumePosition;

  @override
  ConsumerState<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends ConsumerState<VideoPlayerPage>
    with WidgetsBindingObserver {
  late final VideoPlayerController _controller;
  late int _currentIndex;
  StreamSubscription<VideoPlayerState>? _stateSubscription;
  Timer? _controlsTimer;
  Timer? _systemBarsTimer;
  Timer? _gestureIndicatorTimer;
  Timer? _resumeMessageTimer;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>?
  _resumeSnackBarController;
  final Map<int, Offset> _activePointers = {};
  bool _orientationReady = false;
  bool _orientationChosen = false;
  bool _playbackMarked = false;
  bool _closing = false;
  bool _controlsVisible = true;
  bool _seekDragging = false;
  bool _popupOpen = false;
  bool _systemBarsVisible = true;
  bool _videoFill = false;
  bool _resumeMessageShown = false;
  bool _endPositionReset = false;
  bool _lastObservedPlaying = false;
  bool _gestureVolumeBrightnessInitialized = false;
  _VideoGesture? _videoGesture;
  String? _gestureIndicator;
  DateTime? _lastTapAt;
  int? _lastTapZone;
  DateTime _lastResumeSave = DateTime.now();
  Duration? _gestureSeekTarget;
  Duration _gestureSeekStart = Duration.zero;
  double _gestureLevel = 0;
  double _gestureLevelStart = 0;
  double _gesturePinchDistance = 0;
  double _gesturePinchScale = 1;
  double _gestureVerticalDelta = 0;
  double _gestureAreaHeight = 1;
  double _gestureAreaWidth = 1;
  bool _gestureLevelBrightness = false;
  late Offset _gestureStart;
  double _playbackSpeed = 1;
  Duration? _seekTarget;
  Duration _displayPosition = Duration.zero;

  VideoPlayerItem get _currentItem => widget.items[_currentIndex];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentIndex = widget.initialIndex.clamp(0, widget.items.length - 1);
    _controller = ref.read(videoPlayerControllerProvider(widget.sessionId));
    _stateSubscription = _controller.states.listen(_onPlayerState);
    SystemChrome.setSystemUIChangeCallback(_onSystemUiChanged);
    unawaited(_startPlayback());
  }

  Future<void> _startPlayback() async {
    try {
      final information = _currentItem.knownInformation;
      if (information?.width != null && information?.height != null) {
        await _applyOrientation(
          information!.width!,
          information.height!,
          information.rotationDegrees,
        );
        if (!mounted) return;
        setState(() => _orientationReady = true);
      }
      final resumePosition =
          await widget.onResumePosition?.call(_currentItem) ?? Duration.zero;
      if (!mounted) return;
      await _controller.initialize(
        _currentItem,
        resumePosition: resumePosition,
      );
      if (mounted) {
        setState(() {});
        _showControlsAndBars(resetTimers: true);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _orientationReady = true;
          _controlsVisible = true;
          _systemBarsVisible = true;
        });
        _cancelHideTimers();
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        _showMessage('Could not start video playback: $error');
      }
    }
  }

  Future<void> _onPlayerState(VideoPlayerState state) async {
    if (!mounted || _closing) return;
    final orientationChanged = state.hasVideoSize && !_orientationChosen;
    if (orientationChanged) {
      await _applyOrientation(state.width, state.height, state.rotationDegrees);
      if (!mounted) return;
      _orientationReady = true;
    }
    _displayPosition = state.position;
    if (_controlsVisible || orientationChanged || state.error != null) {
      setState(() {
        if (state.error != null) {
          _controlsVisible = true;
          _systemBarsVisible = true;
        }
      });
    }
    if (state.error != null) {
      _cancelHideTimers();
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    if (state.isPlaying && !_playbackMarked) {
      _playbackMarked = true;
      final callback = widget.onPlaybackBegan;
      if (callback != null) {
        try {
          await callback(_currentItem);
        } catch (error) {
          if (mounted) _showMessage('Could not save playback history: $error');
        }
      }
    }
    if (state.resumedPosition > Duration.zero && !_resumeMessageShown) {
      _resumeMessageShown = true;
      _showResumeMessage(state.resumedPosition);
    }
    if (_lastObservedPlaying && !state.isPlaying && !state.isEnded) {
      unawaited(_savePosition(_currentItem, state.position));
    }
    _lastObservedPlaying = state.isPlaying;
    final now = DateTime.now();
    if (state.isPlaying &&
        now.difference(_lastResumeSave) >= const Duration(seconds: 10)) {
      _lastResumeSave = now;
      unawaited(_savePosition(_currentItem, state.position));
    }
    if (state.isEnded && !_endPositionReset) {
      _endPositionReset = true;
      unawaited(_resetPosition(_currentItem));
    }
  }

  Future<void> _applyOrientation(int width, int height, int rotation) async {
    final displayedWidth = rotation % 180 == 0 ? width : height;
    final displayedHeight = rotation % 180 == 0 ? height : width;
    if (displayedWidth == displayedHeight) {
      _orientationChosen = true;
      return;
    }
    final orientations = displayedWidth > displayedHeight
        ? const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
        : const [DeviceOrientation.portraitUp];
    await SystemChrome.setPreferredOrientations(orientations);
    _orientationChosen = true;
  }

  Future<void> _playAt(int index) async {
    if (index < 0 || index >= widget.items.length || index == _currentIndex) {
      return;
    }
    _clearResumeMessage();
    await _savePosition(_currentItem, _controller.state.position);
    _onControlUsed();
    setState(() {
      _currentIndex = index;
      _playbackMarked = false;
      _orientationChosen = false;
      _orientationReady = false;
      _displayPosition = Duration.zero;
      _resumeMessageShown = false;
      _endPositionReset = false;
      _lastObservedPlaying = false;
      _lastResumeSave = DateTime.now();
    });
    try {
      final information = _currentItem.knownInformation;
      if (information?.width != null && information?.height != null) {
        await _applyOrientation(
          information!.width!,
          information.height!,
          information.rotationDegrees,
        );
        if (mounted) setState(() => _orientationReady = true);
      }
      final resumePosition =
          await widget.onResumePosition?.call(_currentItem) ?? Duration.zero;
      if (!mounted) return;
      await _controller.setSource(_currentItem, resumePosition: resumePosition);
    } catch (error) {
      if (mounted) _showMessage('Could not play ${_currentItem.name}: $error');
    }
  }

  Future<void> playNext() => _playAt(_currentIndex + 1);

  Future<void> playPrevious() => _playAt(_currentIndex - 1);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(_controller.pause());
      unawaited(_saveCurrentPosition());
      _cancelHideTimers();
    } else if (state == AppLifecycleState.resumed && !_closing) {
      _showControlsAndBars(resetTimers: true);
    }
  }

  @override
  void dispose() {
    _closing = true;
    _cancelHideTimers();
    _gestureIndicatorTimer?.cancel();
    _clearResumeMessage();
    unawaited(_savePosition(_currentItem, _controller.state.position));
    SystemChrome.setSystemUIChangeCallback(null);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stateSubscription?.cancel());
    unawaited(_controller.dispose());
    unawaited(SystemChrome.setPreferredOrientations(const []));
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  Future<void> _onSystemUiChanged(bool visible) async {
    if (!mounted || _closing) return;
    _systemBarsVisible = visible;
    if (visible) {
      _systemBarsTimer?.cancel();
      if (!_controlsVisible) {
        _systemBarsTimer = Timer(_systemBarsHideDelay, _hideSystemBars);
      }
    }
  }

  void _showControlsAndBars({required bool resetTimers}) {
    if (!mounted || _closing) return;
    _controlsTimer?.cancel();
    _systemBarsTimer?.cancel();
    if (!_controlsVisible || !_systemBarsVisible) {
      setState(() {
        _controlsVisible = true;
        _systemBarsVisible = true;
      });
    }
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    if (resetTimers) _scheduleHideTimers();
  }

  void _toggleControls() {
    if (_popupOpen || _seekDragging) return;
    if (_controlsVisible) {
      _controlsTimer?.cancel();
      _systemBarsTimer?.cancel();
      setState(() => _controlsVisible = false);
      unawaited(
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
      );
    } else {
      _showControlsAndBars(resetTimers: true);
    }
  }

  void _scheduleHideTimers() {
    if (_popupOpen || _seekDragging) return;
    _controlsTimer?.cancel();
    _systemBarsTimer?.cancel();
    _controlsTimer = Timer(_controlsHideDelay, () {
      if (!mounted || _popupOpen || _seekDragging) return;
      if (_controlsVisible) setState(() => _controlsVisible = false);
    });
    _systemBarsTimer = Timer(_systemBarsHideDelay, _hideSystemBars);
  }

  void _hideSystemBars() {
    if (!mounted || _closing || _popupOpen || _seekDragging) return;
    _systemBarsVisible = false;
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
  }

  void _cancelHideTimers() {
    _controlsTimer?.cancel();
    _systemBarsTimer?.cancel();
  }

  void _onControlUsed() {
    _showControlsAndBars(resetTimers: true);
  }

  Future<void> _togglePlayback() async {
    _onControlUsed();
    try {
      final state = _controller.state;
      if (state.isPlaying) {
        await _controller.pause();
      } else if (state.isReady) {
        if (state.isEnded || _atEnd(state)) {
          await _controller.seek(Duration.zero);
        }
        await _controller.play();
      }
    } catch (error) {
      if (mounted) _showMessage('Could not control playback: $error');
    }
  }

  Future<void> _jumpToStart() async {
    _onControlUsed();
    try {
      await _controller.seek(Duration.zero);
    } catch (error) {
      if (mounted) _showMessage('Could not seek to the start: $error');
    }
  }

  Future<void> _jumpToEnd() async {
    _onControlUsed();
    try {
      await _controller.pause();
      await _controller.seek(_controller.state.duration);
    } catch (error) {
      if (mounted) _showMessage('Could not seek to the end: $error');
    }
  }

  void _beginSeek(double _) {
    _controlsTimer?.cancel();
    _systemBarsTimer?.cancel();
    setState(() {
      _seekDragging = true;
      _seekTarget = _displayPosition;
    });
  }

  void _updateSeek(double value) {
    setState(() {
      _seekTarget = Duration(milliseconds: value.round());
    });
  }

  Future<void> _commitSeek(double value) async {
    final target = Duration(milliseconds: value.round());
    setState(() {
      _seekDragging = false;
      _seekTarget = null;
      _displayPosition = target;
    });
    try {
      await _controller.seek(target);
    } catch (error) {
      if (mounted) _showMessage('Could not seek in this video: $error');
    } finally {
      if (mounted) _scheduleHideTimers();
    }
  }

  Future<void> _openSpeedMenu() async {
    _onControlUsed();
    _popupOpen = true;
    _controlsTimer?.cancel();
    _systemBarsTimer?.cancel();
    final overlay = Overlay.of(context).context.findRenderObject();
    final button = _speedButtonKey.currentContext?.findRenderObject();
    if (overlay is! RenderBox || button is! RenderBox) {
      _popupOpen = false;
      _scheduleHideTimers();
      return;
    }
    final position = button.localToGlobal(Offset.zero, ancestor: overlay);
    final selected = await showMenu<double>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy + button.size.height,
        overlay.size.width - position.dx - button.size.width,
        0,
      ),
      items: [
        for (final speed in _playbackSpeeds)
          PopupMenuItem<double>(
            value: speed,
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: speed == _playbackSpeed
                      ? const Icon(Icons.check, size: 20)
                      : null,
                ),
                Text(_speedLabel(speed)),
              ],
            ),
          ),
      ],
    );
    _popupOpen = false;
    if (selected != null && mounted) {
      try {
        await _controller.setSpeed(selected);
        if (mounted) setState(() => _playbackSpeed = selected);
      } catch (error) {
        if (mounted) _showMessage('Could not change playback speed: $error');
      }
    }
    if (mounted) {
      _showControlsAndBars(resetTimers: true);
    }
  }

  Future<void> _openWithAnotherApp() async {
    await openVideoFile(
      context,
      ref,
      path: _currentItem.path,
      name: _currentItem.name,
      excludeBuiltIn: true,
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _savePosition(VideoPlayerItem item, Duration position) async {
    try {
      await widget.onSaveResumePosition?.call(item, position);
    } catch (error) {
      debugPrint('Could not save video resume position: $error');
    }
  }

  Future<void> _saveCurrentPosition() =>
      _savePosition(_currentItem, _controller.state.position);

  Future<void> _resetPosition(VideoPlayerItem item) async {
    try {
      await widget.onResetResumePosition?.call(item);
    } catch (error) {
      debugPrint('Could not reset video resume position: $error');
    }
  }

  void _showResumeMessage(Duration position) {
    _clearResumeMessage();
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    _resumeSnackBarController = messenger.showSnackBar(
      SnackBar(
        content: Text('Resumed at ${_formatDuration(position)}'),
        duration: _resumeMessageDuration,
        action: SnackBarAction(
          label: 'Start over',
          onPressed: () {
            _clearResumeMessage();
            _onControlUsed();
            unawaited(_controller.seek(Duration.zero));
          },
        ),
      ),
    );
    _resumeMessageTimer = Timer(_resumeMessageDuration, () {
      if (mounted) {
        _resumeSnackBarController?.close();
        _resumeSnackBarController = null;
      }
    });
  }

  void _clearResumeMessage() {
    _resumeMessageTimer?.cancel();
    _resumeMessageTimer = null;
    final controller = _resumeSnackBarController;
    _resumeSnackBarController = null;
    controller?.close();
  }

  void _showGestureIndicator(String message) {
    _gestureIndicatorTimer?.cancel();
    setState(() => _gestureIndicator = message);
  }

  void _hideGestureIndicatorSoon() {
    _gestureIndicatorTimer?.cancel();
    _gestureIndicatorTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _gestureIndicator = null);
    });
  }

  void _onPointerDown(PointerDownEvent event) {
    _activePointers[event.pointer] = event.position;
    final size = MediaQuery.sizeOf(context);
    _gestureAreaWidth = size.width;
    _gestureAreaHeight = size.height;
    if (_activePointers.length == 1) {
      _gestureStart = event.position;
      _videoGesture = _VideoGesture.undecided;
      _gestureSeekStart = _controller.state.position;
      _gestureSeekTarget = _gestureSeekStart;
      return;
    }
    if (_activePointers.length == 2) {
      final points = _activePointers.values.toList(growable: false);
      _gesturePinchDistance = (points[0] - points[1]).distance;
      _gesturePinchScale = 1;
      _videoGesture = _VideoGesture.pinch;
      _lastTapAt = null;
      _cancelHideTimers();
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_activePointers.containsKey(event.pointer)) return;
    _activePointers[event.pointer] = event.position;
    if (_activePointers.length > 1) {
      if (_videoGesture != _VideoGesture.pinch) return;
      final points = _activePointers.values.toList(growable: false);
      if (_gesturePinchDistance <= 0) return;
      _gesturePinchScale =
          (points[0] - points[1]).distance / _gesturePinchDistance;
      final fill = _gesturePinchScale >= 1.04;
      final fit = _gesturePinchScale <= 0.96;
      if ((fill && !_videoFill) || (fit && _videoFill)) {
        setState(() => _videoFill = fill);
      }
      return;
    }
    final start = _gestureStart;
    final delta = event.position - start;
    if (_videoGesture == _VideoGesture.undecided) {
      if (delta.distance < 10) return;
      _videoGesture = delta.dx.abs() >= delta.dy.abs()
          ? _VideoGesture.horizontal
          : _VideoGesture.vertical;
      _lastTapAt = null;
      _cancelHideTimers();
      if (_videoGesture == _VideoGesture.horizontal) {
        _gestureSeekStart = _controller.state.position;
      } else {
        _gestureLevelBrightness = start.dx < _gestureAreaWidth / 2;
        unawaited(_initializeLevelGesture());
      }
    }

    switch (_videoGesture) {
      case _VideoGesture.horizontal:
        final deltaMilliseconds =
            (delta.dx /
                    _gestureAreaWidth *
                    _controller.state.duration.inMilliseconds)
                .round();
        final target = Duration(
          milliseconds: (_gestureSeekStart.inMilliseconds + deltaMilliseconds)
              .clamp(0, _controller.state.duration.inMilliseconds)
              .toInt(),
        );
        _gestureSeekTarget = target;
        final difference = target - _gestureSeekStart;
        final sign = difference.isNegative ? '-' : '+';
        _showGestureIndicator(
          '${_formatDuration(target)} [$sign${_formatDuration(difference.abs())}]',
        );
        break;
      case _VideoGesture.vertical:
        _gestureVerticalDelta = delta.dy / _gestureAreaHeight;
        final level = (_gestureLevelStart - delta.dy / _gestureAreaHeight)
            .clamp(0.0, 1.0)
            .toDouble();
        _gestureLevel = level;
        final label = _gestureLevelBrightness ? 'Brightness' : 'Volume';
        _showGestureIndicator('$label ${(level * 100).round()}%');
        unawaited(_applyLevelGesture(level));
        break;
      case _VideoGesture.undecided:
      case _VideoGesture.pinch:
      case null:
        break;
    }
  }

  Future<void> _initializeLevelGesture() async {
    _gestureVolumeBrightnessInitialized = false;
    try {
      if (_gestureLevelBrightness) {
        _gestureLevelStart = await _controller.getWindowBrightness();
      } else {
        _gestureLevelStart = await _controller.getMediaVolume();
      }
      if (!mounted || _videoGesture != _VideoGesture.vertical) return;
      _gestureLevel = (_gestureLevelStart - _gestureVerticalDelta)
          .clamp(0.0, 1.0)
          .toDouble();
      _gestureVolumeBrightnessInitialized = true;
      await _applyLevelGesture(_gestureLevel);
    } catch (error) {
      if (mounted) _showMessage('Could not read the device level: $error');
    }
  }

  Future<void> _applyLevelGesture(double level) async {
    if (!_gestureVolumeBrightnessInitialized) return;
    try {
      if (_gestureLevelBrightness) {
        await _controller.setWindowBrightness(level);
      } else {
        await _controller.setMediaVolume(level);
      }
    } catch (error) {
      if (mounted) _showMessage('Could not adjust the device level: $error');
    }
  }

  Future<void> _onPointerUp(PointerUpEvent event) async {
    final gesture = _videoGesture;
    final position = event.position;
    _activePointers.remove(event.pointer);
    if (_activePointers.isNotEmpty) return;
    _videoGesture = null;

    if (gesture == _VideoGesture.undecided || gesture == null) {
      final zone = position.dx < _gestureAreaWidth / 3
          ? 0
          : position.dx >= _gestureAreaWidth * 2 / 3
          ? 2
          : 1;
      final now = DateTime.now();
      final isDoubleTap =
          zone != 1 &&
          _lastTapZone == zone &&
          _lastTapAt != null &&
          now.difference(_lastTapAt!) <= const Duration(milliseconds: 350);
      if (isDoubleTap) {
        _lastTapAt = null;
        final movement = zone == 0
            ? const Duration(seconds: -10)
            : const Duration(seconds: 10);
        final target = Duration(
          milliseconds:
              (_controller.state.position.inMilliseconds +
                      movement.inMilliseconds)
                  .clamp(0, _controller.state.duration.inMilliseconds)
                  .toInt(),
        );
        try {
          await _controller.seek(target);
        } catch (error) {
          if (mounted) _showMessage('Could not seek in this video: $error');
          return;
        }
        _showGestureIndicator(zone == 0 ? '-10s' : '+10s');
        _hideGestureIndicatorSoon();
        return;
      }
      _lastTapAt = now;
      _lastTapZone = zone;
      _toggleControls();
      return;
    }
    _lastTapAt = null;
    if (gesture == _VideoGesture.horizontal) {
      final target = _gestureSeekTarget;
      if (target != null && target != _gestureSeekStart) {
        try {
          await _controller.seek(target);
        } catch (error) {
          if (mounted) _showMessage('Could not seek in this video: $error');
        }
      }
      if (target != null) {
        final difference = target - _gestureSeekStart;
        final sign = difference.isNegative ? '-' : '+';
        _showGestureIndicator(
          '${_formatDuration(target)} [$sign${_formatDuration(difference.abs())}]',
        );
      }
    }
    if (gesture == _VideoGesture.vertical) {
      _gestureVolumeBrightnessInitialized = false;
    }
    _hideGestureIndicatorSoon();
    _scheduleHideTimers();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.isNotEmpty) return;
    _videoGesture = null;
    _gestureVolumeBrightnessInitialized = false;
    _gestureSeekTarget = null;
    _hideGestureIndicatorSoon();
    _scheduleHideTimers();
  }

  bool _atEnd(VideoPlayerState state) =>
      state.duration > Duration.zero &&
      state.position >= state.duration - const Duration(milliseconds: 200);

  String _formatDuration(Duration duration) {
    final seconds = duration.inSeconds;
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final remainder = seconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:'
          '${remainder.toString().padLeft(2, '0')}';
    }
    return '$minutes:${remainder.toString().padLeft(2, '0')}';
  }

  String _speedLabel(double speed) =>
      '${speed == speed.roundToDouble() ? speed.toInt() : speed}x';

  Widget _buildVideo(VideoPlayerState state) {
    final textureId = state.textureId;
    if (!_orientationReady || textureId == null || !state.hasVideoSize) {
      return const ColoredBox(color: Colors.black);
    }
    final quarterTurns = (state.rotationDegrees % 360) ~/ 90;
    final displayedWidth = quarterTurns.isOdd ? state.height : state.width;
    final displayedHeight = quarterTurns.isOdd ? state.width : state.height;
    return ClipRect(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final containScale = [
            constraints.maxWidth / displayedWidth,
            constraints.maxHeight / displayedHeight,
          ].reduce((a, b) => a < b ? a : b);
          final coverScale = [
            constraints.maxWidth / displayedWidth,
            constraints.maxHeight / displayedHeight,
          ].reduce((a, b) => a > b ? a : b);
          final fillScale = containScale > 0 ? coverScale / containScale : 1.0;
          return TweenAnimationBuilder<double>(
            tween: Tween<double>(end: _videoFill ? fillScale : 1),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            child: RotatedBox(
              quarterTurns: quarterTurns,
              child: SizedBox(
                width: state.width.toDouble(),
                height: state.height.toDouble(),
                child: Texture(textureId: textureId),
              ),
            ),
            builder: (context, scale, child) => SizedBox.expand(
              child: Transform.scale(
                scale: scale,
                child: Center(
                  child: FittedBox(fit: BoxFit.contain, child: child),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _iconButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    double size = 26,
  }) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed == null
        ? null
        : () {
            _onControlUsed();
            onPressed();
          },
    constraints: const BoxConstraints.tightFor(width: 52, height: 52),
    padding: EdgeInsets.zero,
    color: Colors.white,
    disabledColor: Colors.white38,
    icon: Icon(icon, size: size),
  );

  Widget _buildTopControls(TextScaler scaler) {
    final style = TextStyle(color: Colors.white, fontSize: scaler.scale(16));
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            _iconButton(
              tooltip: 'Back',
              icon: Icons.arrow_back,
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            TextButton(
              key: _speedButtonKey,
              onPressed: _openSpeedMenu,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                minimumSize: const Size(52, 48),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: Text(_speedLabel(_playbackSpeed), style: style),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: MarqueeText(
                _currentItem.name,
                style: style,
                styleMode: MarqueeStyle.pauseAndLoop,
                isActive: _controlsVisible,
              ),
            ),
            _iconButton(
              tooltip: 'Options',
              icon: Icons.more_vert,
              onPressed: () => _showMessage('Options are coming soon'),
            ),
          ],
        ),
      ),
    );
  }

  final GlobalKey _speedButtonKey = GlobalKey();

  Widget _buildBottomControls(VideoPlayerState state, TextScaler scaler) {
    final duration = state.duration;
    final totalMilliseconds = duration.inMilliseconds
        .toDouble()
        .clamp(1, double.infinity)
        .toDouble();
    final position = _seekDragging
        ? _seekTarget ?? _displayPosition
        : _displayPosition;
    final positionMilliseconds = position.inMilliseconds
        .toDouble()
        .clamp(0, totalMilliseconds)
        .toDouble();
    final textStyle = TextStyle(
      color: Colors.white,
      fontSize: scaler.scale(14),
    );
    final canPrevious = _currentIndex > 0;
    final canNext = _currentIndex < widget.items.length - 1;
    final isAtEnd = state.isEnded || _atEnd(state);
    final centerIcon = state.isPlaying
        ? Icons.pause
        : isAtEnd
        ? Icons.replay
        : Icons.play_arrow;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_seekDragging && _seekTarget != null)
              Text(_formatDuration(_seekTarget!), style: textStyle),
            Row(
              children: [
                Text(_formatDuration(position), style: textStyle),
                Expanded(
                  child: Slider(
                    value: positionMilliseconds,
                    min: 0,
                    max: totalMilliseconds,
                    onChangeStart: _beginSeek,
                    onChanged: _updateSeek,
                    onChangeEnd: _commitSeek,
                    activeColor: Colors.white,
                    inactiveColor: Colors.white38,
                  ),
                ),
                Text(_formatDuration(duration), style: textStyle),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _iconButton(
                  tooltip: 'Previous video',
                  icon: Icons.skip_previous,
                  onPressed: canPrevious ? playPrevious : null,
                ),
                _iconButton(
                  tooltip: 'Go to start',
                  icon: Icons.first_page,
                  onPressed: _jumpToStart,
                ),
                _iconButton(
                  tooltip: state.isPlaying ? 'Pause' : 'Play',
                  icon: centerIcon,
                  onPressed: _togglePlayback,
                  size: 30,
                ),
                _iconButton(
                  tooltip: 'Go to end',
                  icon: Icons.last_page,
                  onPressed: _jumpToEnd,
                ),
                _iconButton(
                  tooltip: 'Next video',
                  icon: Icons.skip_next,
                  onPressed: canNext ? playNext : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(
      videoPlayerControllerProvider(widget.sessionId),
    );
    final state = controller.state;
    final error = state.error;
    final scaler = MediaQuery.textScalerOf(context);
    final gestureIndicator = _gestureIndicator;
    return PopScope(
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: false,
        body: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: Colors.black,
              child: error == null
                  ? Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: _onPointerDown,
                      onPointerMove: _onPointerMove,
                      onPointerUp: _onPointerUp,
                      onPointerCancel: _onPointerCancel,
                      child: _buildVideo(state),
                    )
                  : Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'This device cannot play this video',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: scaler.scale(16),
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            FilledButton(
                              onPressed: _openWithAnotherApp,
                              child: Text(
                                'Open with another app',
                                style: TextStyle(fontSize: scaler.scale(14)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
            if (error == null && !state.isReady)
              const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            if (error == null &&
                state.isReady &&
                !state.isPlaying &&
                !state.isEnded &&
                !_controlsVisible)
              const Center(
                child: IgnorePointer(
                  child: Icon(Icons.play_arrow, color: Colors.white, size: 64),
                ),
              ),
            if (gestureIndicator != null)
              Center(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.62),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                      child: Text(
                        gestureIndicator,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: scaler.scale(18),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (_controlsVisible)
              Positioned.fill(
                child: Column(
                  children: [
                    DecoratedBox(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0xB8000000), Colors.transparent],
                        ),
                      ),
                      child: SizedBox(
                        width: double.infinity,
                        child: _buildTopControls(scaler),
                      ),
                    ),
                    const Spacer(),
                    if (error == null)
                      DecoratedBox(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [Color(0xD9000000), Colors.transparent],
                          ),
                        ),
                        child: SizedBox(
                          width: double.infinity,
                          child: _buildBottomControls(state, scaler),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _VideoGesture { undecided, horizontal, vertical, pinch }
