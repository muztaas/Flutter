class VideoPlayerState {
  const VideoPlayerState({
    this.textureId,
    this.isReady = false,
    this.isPlaying = false,
    this.isEnded = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.width = 0,
    this.height = 0,
    this.rotationDegrees = 0,
    this.resumedPosition = Duration.zero,
    this.error,
  });

  final int? textureId;
  final bool isReady;
  final bool isPlaying;
  final bool isEnded;
  final Duration position;
  final Duration duration;
  final int width;
  final int height;
  final int rotationDegrees;
  final Duration resumedPosition;
  final String? error;

  bool get hasVideoSize => width > 0 && height > 0;

  VideoPlayerState copyWith({
    int? textureId,
    bool? isReady,
    bool? isPlaying,
    bool? isEnded,
    Duration? position,
    Duration? duration,
    int? width,
    int? height,
    int? rotationDegrees,
    Duration? resumedPosition,
    String? error,
    bool clearError = false,
  }) => VideoPlayerState(
    textureId: textureId ?? this.textureId,
    isReady: isReady ?? this.isReady,
    isPlaying: isPlaying ?? this.isPlaying,
    isEnded: isEnded ?? this.isEnded,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    width: width ?? this.width,
    height: height ?? this.height,
    rotationDegrees: rotationDegrees ?? this.rotationDegrees,
    resumedPosition: resumedPosition ?? this.resumedPosition,
    error: clearError ? null : error ?? this.error,
  );
}
