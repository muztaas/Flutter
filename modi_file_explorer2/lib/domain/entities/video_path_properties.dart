class VideoPathProperties {
  const VideoPathProperties({
    required this.fileCount,
    required this.folderCount,
    required this.otherItemCount,
    required this.totalBytes,
    this.modified,
  });

  final int fileCount;
  final int folderCount;
  final int otherItemCount;
  final int totalBytes;
  final DateTime? modified;
}
