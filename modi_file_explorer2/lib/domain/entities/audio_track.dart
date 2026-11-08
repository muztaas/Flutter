class AudioTrack {
  const AudioTrack({
    required this.path,
    required this.title,
    required this.folder,
    this.size = 0,
    this.modifiedMilliseconds = 0,
  });

  final String path;
  final String title;
  final String folder;
  final int size;
  final int modifiedMilliseconds;

  AudioTrack copyWith({
    String? path,
    String? title,
    String? folder,
    int? size,
    int? modifiedMilliseconds,
  }) => AudioTrack(
    path: path ?? this.path,
    title: title ?? this.title,
    folder: folder ?? this.folder,
    size: size ?? this.size,
    modifiedMilliseconds: modifiedMilliseconds ?? this.modifiedMilliseconds,
  );
}
