import 'video_file.dart';
import 'video_information.dart';

class VideoPlayerItem {
  const VideoPlayerItem({
    required this.path,
    required this.name,
    this.videoFile,
    this.knownInformation,
  });

  factory VideoPlayerItem.fromVideoFile(
    VideoFile video, {
    String? absolutePath,
    VideoInformation? knownInformation,
  }) => VideoPlayerItem(
    path: absolutePath ?? video.relativePath,
    name: video.name,
    videoFile: video,
    knownInformation: knownInformation,
  );

  final String path;
  final String name;
  final VideoFile? videoFile;
  final VideoInformation? knownInformation;
}
