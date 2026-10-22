import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../domain/entities/video_player_item.dart';
import '../../../domain/entities/video_player_state.dart';
import '../../../domain/repositories/video_player_repository.dart';

class AndroidVideoPlayerController implements VideoPlayerController {
  AndroidVideoPlayerController()
    : _sessionId = DateTime.now().microsecondsSinceEpoch.toString() {
    _eventSubscription = _events
        .receiveBroadcastStream()
        .listen(_onEvent, onError: _onStreamError);
  }

  static const _methods = MethodChannel('modi_file_explorer2/video_player');
  static const _events = EventChannel('modi_file_explorer2/video_player/events');

  final String _sessionId;
  final StreamController<VideoPlayerState> _states =
      StreamController<VideoPlayerState>.broadcast();
  final StreamController<Duration> _positions =
      StreamController<Duration>.broadcast();
  late final StreamSubscription<Object?> _eventSubscription;
  VideoPlayerState _state = const VideoPlayerState();
  bool _disposed = false;

  @override
  VideoPlayerState get state => _state;

  @override
  Stream<VideoPlayerState> get states => _states.stream;

  @override
  Stream<Duration> get positions => _positions.stream;

  @override
  Future<void> initialize(
    VideoPlayerItem item, {
    Duration resumePosition = Duration.zero,
  }) async {
    if (_disposed) throw StateError('The video player is disposed');
    final result = await _methods.invokeMapMethod<String, Object?>(
      'create',
      {
        'sessionId': _sessionId,
        'path': item.path,
        'width': item.knownInformation?.width,
        'height': item.knownInformation?.height,
        'rotationDegrees': item.knownInformation?.rotationDegrees ?? 0,
        'resumePositionMilliseconds': resumePosition.inMilliseconds,
      },
    );
    final textureId = result?['textureId'];
    if (textureId is! int) {
      throw StateError('The Android video player did not create a texture');
    }
    _emit(_state.copyWith(textureId: textureId));
  }

  @override
  Future<void> setSource(
    VideoPlayerItem item, {
    Duration resumePosition = Duration.zero,
  }) async {
    if (_disposed) throw StateError('The video player is disposed');
    await _methods.invokeMethod<void>('setSource', {
      'sessionId': _sessionId,
      'path': item.path,
      'width': item.knownInformation?.width,
      'height': item.knownInformation?.height,
      'rotationDegrees': item.knownInformation?.rotationDegrees ?? 0,
      'resumePositionMilliseconds': resumePosition.inMilliseconds,
    });
  }

  @override
  Future<void> play() => _invoke('play');

  @override
  Future<void> pause() => _invoke('pause');

  @override
  Future<void> seek(Duration position) =>
      _invoke('seek', {'positionMilliseconds': position.inMilliseconds});

  @override
  Future<void> setSpeed(double speed) =>
      _invoke('setSpeed', {'speed': speed});

  @override
  Future<void> setVolume(double volume) =>
      _invoke('setVolume', {'volume': volume});

  @override
  Future<double> getMediaVolume() async =>
      (await _methods.invokeMethod<num>('getMediaVolume', {
        'sessionId': _sessionId,
      }))?.toDouble() ??
      0.5;

  @override
  Future<void> setMediaVolume(double volume) =>
      _invoke('setMediaVolume', {'volume': volume});

  @override
  Future<double> getWindowBrightness() async =>
      (await _methods.invokeMethod<num>('getWindowBrightness', {
        'sessionId': _sessionId,
      }))?.toDouble() ??
      0.5;

  @override
  Future<void> setWindowBrightness(double brightness) =>
      _invoke('setWindowBrightness', {'brightness': brightness});

  @override
  Future<void> restoreWindowBrightness() => _invoke('restoreWindowBrightness');

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _methods.invokeMethod<void>('dispose', {'sessionId': _sessionId});
    } on PlatformException catch (error) {
      debugPrint('Could not release Android video player: $error');
    } on MissingPluginException {
      // The engine may already be detached while the route is being removed.
    } finally {
      await _eventSubscription.cancel();
      await _states.close();
      await _positions.close();
    }
  }

  Future<void> _invoke(String method, [Map<String, Object?> arguments = const {}]) {
    if (_disposed) return Future<void>.value();
    return _methods.invokeMethod<void>(method, {
      'sessionId': _sessionId,
      ...arguments,
    });
  }

  void _onEvent(Object? event) {
    if (event is! Map) return;
    final payload = Map<Object?, Object?>.from(event);
    if (payload['sessionId'] != _sessionId || _disposed) return;
    final nextState = _state.copyWith(
      isReady: payload['isReady'] as bool?,
      isPlaying: payload['isPlaying'] as bool?,
      isEnded: payload['isEnded'] as bool?,
      position: _duration(payload['positionMilliseconds']),
      duration: _duration(payload['durationMilliseconds']),
      width: payload['width'] as int?,
      height: payload['height'] as int?,
      rotationDegrees: payload['rotationDegrees'] as int?,
      resumedPosition: _duration(payload['resumedPositionMilliseconds']),
      error: payload['error'] as String?,
      clearError: payload['error'] == null,
    );
    _emit(nextState);
  }

  void _onStreamError(Object error, StackTrace stackTrace) {
    if (_disposed) return;
    _emit(_state.copyWith(error: 'The player connection was interrupted'));
    debugPrint('Android video player event stream failed: $error');
  }

  void _emit(VideoPlayerState state) {
    _state = state;
    if (!_states.isClosed) _states.add(state);
    if (!_positions.isClosed) _positions.add(state.position);
  }

  Duration _duration(Object? value) => value is int
      ? Duration(milliseconds: value.clamp(0, 1 << 62))
      : Duration.zero;
}
