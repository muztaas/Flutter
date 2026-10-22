class VideoFolder {
  const VideoFolder({
    required this.driveId,
    required this.relativePath,
    required this.name,
    required this.isHidden,
    required this.isInsideNomedia,
    this.modified,
  });

  final String driveId;
  final String relativePath;
  final String name;
  final bool isHidden;
  final bool isInsideNomedia;
  final DateTime? modified;
}
