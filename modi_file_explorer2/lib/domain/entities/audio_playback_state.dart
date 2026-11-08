class AudioPlaybackState {
  const AudioPlaybackState({
    this.isPlaying = false,
    this.isLoading = false,
    this.path,
    this.title,
    this.folder,
    this.positionMilliseconds = 0,
    this.durationMilliseconds = 0,
    this.queueIndex = 0,
    this.queueLength = 0,
    this.mode = 'folder',
    this.error,
    this.isStopped = false,
    this.notificationTapped = false,
  });

  final bool isPlaying;
  final bool isLoading;
  final String? path;
  final String? title;
  final String? folder;
  final int positionMilliseconds;
  final int durationMilliseconds;
  final int queueIndex;
  final int queueLength;
  final String mode;
  final String? error;
  final bool isStopped;
  final bool notificationTapped;
}
