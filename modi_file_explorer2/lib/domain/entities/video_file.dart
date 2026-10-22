class VideoFile {
  const VideoFile({
    required this.driveId,
    required this.relativePath,
    required this.name,
    required this.extension,
    required this.size,
    required this.modified,
    required this.isHidden,
    required this.isInsideNomedia,
  });

  final String driveId;
  final String relativePath;
  final String name;
  final String extension;
  final int size;
  final DateTime modified;
  final bool isHidden;
  final bool isInsideNomedia;

  String get parentRelativePath {
    final separator = relativePath.lastIndexOf('/');
    return separator < 0 ? '' : relativePath.substring(0, separator);
  }
}
