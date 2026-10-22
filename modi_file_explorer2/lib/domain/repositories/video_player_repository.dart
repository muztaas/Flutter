import 'dart:async';

import '../entities/video_player_item.dart';
import '../entities/video_player_state.dart';

abstract interface class VideoPlayerController {
  VideoPlayerState get state;
  Stream<VideoPlayerState> get states;
  Stream<Duration> get positions;

  Future<void> initialize(
    VideoPlayerItem item, {
    Duration resumePosition = Duration.zero,
  });
  Future<void> setSource(
    VideoPlayerItem item, {
    Duration resumePosition = Duration.zero,
  });
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setSpeed(double speed);
  Future<void> setVolume(double volume);
  Future<double> getMediaVolume();
  Future<void> setMediaVolume(double volume);
  Future<double> getWindowBrightness();
  Future<void> setWindowBrightness(double brightness);
  Future<void> restoreWindowBrightness();
  Future<void> dispose();
}
