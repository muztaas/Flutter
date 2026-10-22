class VideoStatusTarget {
  const VideoStatusTarget({
    required this.driveId,
    required this.relativePath,
    this.isFolder = false,
  });

  final String driveId;
  final String relativePath;
  final bool isFolder;
}

class VideoStatusUpdateResult {
  const VideoStatusUpdateResult({this.foldersWithoutPlayedVideos = const []});

  final List<String> foldersWithoutPlayedVideos;
}
